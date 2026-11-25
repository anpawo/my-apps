//! The menu bar: tao installs none, and without it ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z never reach the web view (claim C1 of the
//! rebuild report, checked by `tests/composer.rs`). Each Edit item sends its action to the first responder.

use objc2::rc::Retained;
use objc2::runtime::Sel;
use objc2::{MainThreadOnly, sel};
use objc2_app_kit::{NSApplication, NSEventModifierFlags, NSMenu, NSMenuItem};
use objc2_foundation::{MainThreadMarker, NSString};

pub const EDIT: &str = "Edit";

struct Entry {
    title: &'static str,
    action: Sel,
    key: &'static str,
    modifiers: NSEventModifierFlags,
}

const COMMAND: NSEventModifierFlags = NSEventModifierFlags::Command;

fn entry(title: &'static str, action: Sel, key: &'static str, modifiers: NSEventModifierFlags) -> Option<Entry> {
    Some(Entry { title, action, key, modifiers })
}

/// `None` is a separator.
fn application_entries() -> [Option<Entry>; 5] {
    [
        entry("Hide VCX", sel!(hide:), "h", COMMAND),
        entry("Hide Others", sel!(hideOtherApplications:), "h", COMMAND.union(NSEventModifierFlags::Option)),
        entry("Show All", sel!(unhideAllApplications:), "", COMMAND),
        None,
        entry("Quit VCX", sel!(terminate:), "q", COMMAND),
    ]
}

/// A capital key implies Shift, as in Apple's own menus: a ⇧⌘Z event carries "Z", which a "z" never matches.
fn edit_entries() -> [Option<Entry>; 10] {
    [
        entry("Undo", sel!(undo:), "z", COMMAND),
        entry("Redo", sel!(redo:), "Z", COMMAND),
        None,
        entry("Cut", sel!(cut:), "x", COMMAND),
        entry("Copy", sel!(copy:), "c", COMMAND),
        entry("Paste", sel!(paste:), "v", COMMAND),
        entry("Paste and Match Style", sel!(pasteAsPlainText:), "V", COMMAND.union(NSEventModifierFlags::Option)),
        entry("Delete", sel!(delete:), "", COMMAND),
        None,
        entry("Select All", sel!(selectAll:), "a", COMMAND),
    ]
}

fn submenu(mtm: MainThreadMarker, title: &str, entries: impl IntoIterator<Item = Option<Entry>>) -> Retained<NSMenuItem> {
    let menu = NSMenu::initWithTitle(NSMenu::alloc(mtm), &NSString::from_str(title));
    for entry in entries {
        let item = match entry {
            None => NSMenuItem::separatorItem(mtm),
            Some(entry) => {
                // SAFETY: each action is a standard responder message taking the sender, sent to the first responder.
                let item = unsafe { NSMenuItem::initWithTitle_action_keyEquivalent(NSMenuItem::alloc(mtm), &NSString::from_str(entry.title), Some(entry.action), &NSString::from_str(entry.key)) };
                item.setKeyEquivalentModifierMask(entry.modifiers);
                item
            }
        };
        menu.addItem(&item);
    }
    let holder = NSMenuItem::new(mtm);
    holder.setTitle(&NSString::from_str(title));
    holder.setSubmenu(Some(&menu));
    holder
}

/// Puts the application menu and the Edit menu in the menu bar.
pub fn install(mtm: MainThreadMarker) {
    let bar = NSMenu::new(mtm);
    bar.addItem(&submenu(mtm, "VCX", application_entries()));
    bar.addItem(&submenu(mtm, EDIT, edit_entries()));
    NSApplication::sharedApplication(mtm).setMainMenu(Some(&bar));
}

/// The Edit menu's item titled `title`, if the menu bar holds it.
pub fn edit_item(mtm: MainThreadMarker, title: &str) -> Option<Retained<NSMenuItem>> {
    let bar = NSApplication::sharedApplication(mtm).mainMenu()?;
    bar.itemWithTitle(&NSString::from_str(EDIT))?.submenu()?.itemWithTitle(&NSString::from_str(title))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binds_the_edit_shortcuts_to_the_standard_responder_actions() {
        let bound: Vec<(&str, Sel, &str)> = edit_entries().into_iter().flatten().filter(|entry| !entry.key.is_empty()).map(|entry| (entry.title, entry.action, entry.key)).collect();

        let expected = [("Undo", sel!(undo:), "z"), ("Redo", sel!(redo:), "Z"), ("Cut", sel!(cut:), "x"), ("Copy", sel!(copy:), "c"), ("Paste", sel!(paste:), "v"), ("Paste and Match Style", sel!(pasteAsPlainText:), "V"), ("Select All", sel!(selectAll:), "a")];
        assert_eq!(bound, expected);
    }
}
