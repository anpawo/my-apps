//! Real key and mouse events for a check, handed to the web view of a window that is never shown: the page gets
//! them the way it gets the user's, through AppKit and WebKit, not as events made up in its own script.
// The composer test (`tests/composer.rs`) uses the keys, modifiers and marked text the shell's own check does not.
#![allow(dead_code)]

use objc2::msg_send;
use objc2_app_kit::{NSApplication, NSEvent, NSEventModifierFlags, NSEventType, NSResponder, NSView};
use objc2_foundation::MainThreadMarker;
use objc2_foundation::{NSPoint, NSProcessInfo, NSRange, NSString};
use wry::{WebView, WebViewExtMacOS};

/// Puts the caret in the composer, counts the compositions it will see, and says where the send button is.
pub const AIM: &str = r#"(() => {
  const input = document.getElementById('input');
  input.focus();
  input.addEventListener('compositionend', () => { document.body.dataset.composed = Number(document.body.dataset.composed || 0) + 1; });
  const send = document.getElementById('send').getBoundingClientRect();
  return JSON.stringify({ focused: document.activeElement === input, send: [send.x + send.width / 2, send.y + send.height / 2] });
})()"#;
pub const TYPED: &str = "document.getElementById('input').value";

/// Key codes of the ANSI layout for `a` to `z` and `0` to `9`: WebKit derives the `code` of a page key event from them.
const LETTER_KEYS: [u16; 26] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6];
const DIGIT_KEYS: [u16; 10] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25];
/// The other printable keys of the ANSI layout: the character typed alone, the one typed with Shift, the key code.
const SYMBOL_KEYS: [(char, char, u16); 11] =
    [('-', '_', 27), ('=', '+', 24), ('[', '{', 33), (']', '}', 30), ('\\', '|', 42), (';', ':', 41), ('\'', '"', 39), (',', '<', 43), ('.', '>', 47), ('/', '?', 44), ('`', '~', 50)];
/// What Shift turns the digits into on the ANSI layout, `0` to `9`.
const SHIFTED_DIGITS: [char; 10] = [')', '!', '@', '#', '$', '%', '^', '&', '*', '('];
const SPACE_KEY: u16 = 49;
const FULL_PRESSURE: f32 = 1.0;
/// `NSNotFound`: as a replacement range's place it means "where the caret is".
const NOT_FOUND: usize = isize::MAX as usize;

pub const COMMAND: NSEventModifierFlags = NSEventModifierFlags::Command;
pub const SHIFT: NSEventModifierFlags = NSEventModifierFlags::Shift;
pub const OPTION: NSEventModifierFlags = NSEventModifierFlags::Option;
pub const NONE: NSEventModifierFlags = NSEventModifierFlags::empty();

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Key {
    Char(char),
    Return,
    Tab,
    Escape,
    Delete,
    Up,
    Down,
    Left,
    Right,
}

impl Key {
    /// The key code and the character AppKit gives the key: arrows carry private-use characters.
    fn code_and_character(self) -> Option<(u16, char)> {
        Some(match self {
            Key::Char(key) => (key_code(key)?.0, key),
            Key::Return => (36, '\r'),
            Key::Tab => (48, '\t'),
            Key::Escape => (53, '\u{1b}'),
            Key::Delete => (51, '\u{7f}'),
            Key::Up => (126, '\u{f700}'),
            Key::Down => (125, '\u{f701}'),
            Key::Left => (123, '\u{f702}'),
            Key::Right => (124, '\u{f703}'),
        })
    }
}

/// The key code of a character on the ANSI layout, and whether Shift is held to type it.
fn key_code(key: char) -> Option<(u16, bool)> {
    match key {
        'a'..='z' => Some((LETTER_KEYS[key as usize - 'a' as usize], false)),
        'A'..='Z' => Some((LETTER_KEYS[key as usize - 'A' as usize], true)),
        '0'..='9' => Some((DIGIT_KEYS[key as usize - '0' as usize], false)),
        ' ' => Some((SPACE_KEY, false)),
        _ => {
            if let Some(digit) = SHIFTED_DIGITS.iter().position(|shifted| *shifted == key) {
                return Some((DIGIT_KEYS[digit], true));
            }
            SYMBOL_KEYS.iter().find_map(|&(alone, shifted, code)| (key == alone || key == shifted).then_some((code, key == shifted)))
        }
    }
}

fn now() -> f64 {
    NSProcessInfo::processInfo().systemUptime()
}

/// Hands the keyboard to the web view, as a click in it does.
pub fn focus(webview: &WebView) -> Result<(), String> {
    let view = webview.webview();
    let responder: &NSResponder = &view;
    if webview.ns_window().makeFirstResponder(Some(responder)) { Ok(()) } else { Err("The web view refused the keyboard.".into()) }
}

/// Shows `text` at the caret as an input method's marked text, not yet committed.
pub fn mark(webview: &WebView, text: &str) {
    let view = webview.webview();
    let text = NSString::from_str(text);
    let caret = NSRange::new(NOT_FOUND, 0);
    let after_it = NSRange::new(text.length(), 0);
    // SAFETY: a web view is an `NSTextInputClient`; the message takes an object and two ranges, as passed here.
    unsafe {
        let _: () = msg_send![&*view, setMarkedText: &*text, selectedRange: after_it, replacementRange: caret];
    }
}

/// Commits `text` the way an input method ends a composition, in place of the marked text if there is one.
pub fn commit(webview: &WebView, text: &str) {
    let view = webview.webview();
    let text = NSString::from_str(text);
    let caret = NSRange::new(NOT_FOUND, 0);
    // SAFETY: a web view is an `NSTextInputClient`; the message takes an object and a range, as passed here.
    unsafe {
        let _: () = msg_send![&*view, insertText: &*text, replacementRange: caret];
    }
}

/// Presses and releases `key` with `modifiers` held, as AppKit hands the user's keys over: a key with ⌘ goes to the
/// application first, which offers it to the menu bar, and the others go to the window.
pub fn press(webview: &WebView, key: Key, modifiers: NSEventModifierFlags) -> Result<(), String> {
    let (code, character) = key.code_and_character().ok_or_else(|| format!("No key types {key:?} here."))?;
    let window = webview.ns_window();
    // AppKit gives a letter typed with Shift as its capital, ⌘ or not: ⇧⌘Z arrives as "Z", which the menu tells from ⌘Z.
    let character = if modifiers.contains(SHIFT) { character.to_ascii_uppercase() } else { character };
    let characters = NSString::from_str(&character.to_string());
    let application = modifiers.contains(COMMAND).then(|| MainThreadMarker::new().map(NSApplication::sharedApplication)).flatten();
    for kind in [NSEventType::KeyDown, NSEventType::KeyUp] {
        let event = NSEvent::keyEventWithType_location_modifierFlags_timestamp_windowNumber_context_characters_charactersIgnoringModifiers_isARepeat_keyCode(kind, NSPoint::ZERO, modifiers, now(), window.windowNumber(), None, &characters, &characters, false, code);
        let event = event.ok_or("AppKit made no key event.")?;
        match &application {
            Some(application) => application.sendEvent(&event),
            None => window.sendEvent(&event),
        }
    }
    Ok(())
}

/// Enters `text` with the web view as the window's first responder: a key pressed and released for each character
/// that has one here, Shift held where the layout needs it, the input method's path for the others.
pub fn type_text(webview: &WebView, text: &str) -> Result<(), String> {
    focus(webview)?;
    for key in text.chars() {
        match key_code(key) {
            Some((_, shifted)) => press(webview, Key::Char(key), if shifted { SHIFT } else { NONE })?,
            None => {
                mark(webview, &key.to_string());
                commit(webview, &key.to_string());
            }
        }
    }
    Ok(())
}

/// Clicks the page at `(x, y)`, counted from the top left of the page.
pub fn click(webview: &WebView, x: f64, y: f64) -> Result<(), String> {
    let window = webview.ns_window();
    let view = webview.webview();
    let view: &NSView = &view;
    let in_view = NSPoint::new(x, if view.isFlipped() { y } else { view.bounds().size.height - y });
    let location = view.convertPoint_toView(in_view, None);
    let mouse = |kind| NSEvent::mouseEventWithType_location_modifierFlags_timestamp_windowNumber_context_eventNumber_clickCount_pressure(kind, location, NSEventModifierFlags::empty(), now(), window.windowNumber(), None, 0, 1, FULL_PRESSURE).ok_or("AppKit made no mouse event.");
    let (down, up) = (mouse(NSEventType::LeftMouseDown)?, mouse(NSEventType::LeftMouseUp)?);
    view.mouseDown(&down);
    view.mouseUp(&up);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knows_the_key_of_letters_digits_symbols_and_the_space() {
        let alone = ['a', 'z', '0', '5', ' ', '/'].map(key_code);
        let shifted = ['A', '@', '?', '_'].map(key_code);
        let unknown = ['é', '\n', 'か'].map(key_code);

        assert_eq!(alone, [Some((0, false)), Some((6, false)), Some((29, false)), Some((23, false)), Some((49, false)), Some((44, false))]);
        assert_eq!(shifted, [Some((0, true)), Some((19, true)), Some((44, true)), Some((27, true))]);
        assert_eq!(unknown, [None; 3]);
    }

    #[test]
    fn gives_arrows_the_private_use_characters_appkit_gives_them() {
        let arrows = [Key::Up, Key::Down].map(Key::code_and_character);

        assert_eq!(arrows, [Some((126, '\u{f700}')), Some((125, '\u{f701}'))]);
    }
}
