//! Real key and mouse events for a check, handed to the web view of a window that is never shown: the page gets
//! them the way it gets the user's, through AppKit and WebKit, not as events made up in its own script.

use objc2::msg_send;
use objc2_app_kit::{NSEvent, NSEventModifierFlags, NSEventType, NSResponder, NSView};
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
const SPACE_KEY: u16 = 49;
const FULL_PRESSURE: f32 = 1.0;
/// `NSNotFound`: as a replacement range's place it means "where the caret is".
const NOT_FOUND: usize = isize::MAX as usize;

fn key_code(key: char) -> Option<u16> {
    match key {
        'a'..='z' => Some(LETTER_KEYS[key as usize - 'a' as usize]),
        '0'..='9' => Some(DIGIT_KEYS[key as usize - '0' as usize]),
        ' ' => Some(SPACE_KEY),
        _ => None,
    }
}

fn now() -> f64 {
    NSProcessInfo::processInfo().systemUptime()
}

/// Enters `key` the way an input method does: first as marked text, then committed in its place.
fn compose(view: &NSView, key: char) {
    let text = NSString::from_str(&key.to_string());
    let caret = NSRange::new(NOT_FOUND, 0);
    let after_it = NSRange::new(text.length(), 0);
    // SAFETY: a web view is an `NSTextInputClient`; both messages take an object and ranges, as passed here.
    unsafe {
        let _: () = msg_send![view, setMarkedText: &*text, selectedRange: after_it, replacementRange: caret];
        let _: () = msg_send![view, insertText: &*text, replacementRange: caret];
    }
}

/// Enters `text` with the web view as the window's first responder: a key pressed and released for each character
/// that has one here, the input method's path for the others.
pub fn type_text(webview: &WebView, text: &str) -> Result<(), String> {
    let window = webview.ns_window();
    let view = webview.webview();
    let responder: &NSResponder = &view;
    if !window.makeFirstResponder(Some(responder)) {
        return Err("The web view refused the keyboard.".into());
    }
    for key in text.chars() {
        let Some(code) = key_code(key) else {
            compose(&view, key);
            continue;
        };
        let characters = NSString::from_str(&key.to_string());
        for kind in [NSEventType::KeyDown, NSEventType::KeyUp] {
            let event = NSEvent::keyEventWithType_location_modifierFlags_timestamp_windowNumber_context_characters_charactersIgnoringModifiers_isARepeat_keyCode(kind, NSPoint::ZERO, NSEventModifierFlags::empty(), now(), window.windowNumber(), None, &characters, &characters, false, code);
            let event = event.ok_or("AppKit made no key event.")?;
            window.sendEvent(&event);
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
    fn knows_the_key_of_letters_digits_and_the_space_only() {
        let known = ['a', 'z', '0', '5', ' '].map(key_code);
        let unknown = ['A', 'é', '\n'].map(key_code);

        assert_eq!(known, [Some(0), Some(6), Some(29), Some(23), Some(49)]);
        assert_eq!(unknown, [None; 3]);
    }
}
