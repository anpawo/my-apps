//! The File menu of the Swift app (`configureMenu` in `vcx/Sources/VCX/main.swift`), added beside the application
//! and Edit menus that `vcx_shell::menu::install` puts in the menu bar. Its items call back into the app.

use std::cell::RefCell;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject, Sel};
use objc2::{DefinedClass, MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::{NSApplication, NSEventModifierFlags, NSMenu, NSMenuItem};
use objc2_foundation::{MainThreadMarker, NSString};

pub const FILE: &str = "File";
/// The application menu holds index 0; the File menu follows it, as in the Swift app.
const FILE_MENU_INDEX: isize = 1;
const COMMAND: NSEventModifierFlags = NSEventModifierFlags::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    NewWindow,
    OpenProject,
    CloseWindow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub title: &'static str,
    pub key: &'static str,
    pub modifiers: NSEventModifierFlags,
    pub action: MenuAction,
}

/// A capital key implies Shift, as in AppKit: "N" with Command is ⇧⌘N.
pub fn file_entries() -> [Entry; 3] {
    [
        Entry { title: "New Window", key: "N", modifiers: COMMAND, action: MenuAction::NewWindow },
        Entry { title: "Open Project…", key: "o", modifiers: COMMAND, action: MenuAction::OpenProject },
        Entry { title: "Close Window", key: "w", modifiers: COMMAND, action: MenuAction::CloseWindow },
    ]
}

fn selector(action: MenuAction) -> Sel {
    match action {
        MenuAction::NewWindow => sel!(newWindow:),
        MenuAction::OpenProject => sel!(openProject:),
        MenuAction::CloseWindow => sel!(closeWindow:),
    }
}

struct TargetIvars {
    act: Box<dyn Fn(MenuAction)>,
}

define_class!(
    // SAFETY: NSObject has no subclassing requirements, and `FileMenuTarget` does not implement `Drop`.
    #[unsafe(super = NSObject)]
    #[thread_kind = MainThreadOnly]
    #[name = "VCXFileMenuTarget"]
    #[ivars = TargetIvars]
    struct FileMenuTarget;

    impl FileMenuTarget {
        // SAFETY: an action message takes the sender and returns nothing.
        #[unsafe(method(newWindow:))]
        fn new_window(&self, _sender: Option<&AnyObject>) {
            (self.ivars().act)(MenuAction::NewWindow);
        }

        // SAFETY: as above.
        #[unsafe(method(openProject:))]
        fn open_project(&self, _sender: Option<&AnyObject>) {
            (self.ivars().act)(MenuAction::OpenProject);
        }

        // SAFETY: as above.
        #[unsafe(method(closeWindow:))]
        fn close_window(&self, _sender: Option<&AnyObject>) {
            (self.ivars().act)(MenuAction::CloseWindow);
        }

        // SAFETY: `validateMenuItem:` takes the item and returns a BOOL.
        #[unsafe(method(validateMenuItem:))]
        fn validate_menu_item(&self, _item: &NSMenuItem) -> bool {
            true
        }
    }
);

impl FileMenuTarget {
    fn new(mtm: MainThreadMarker, act: Box<dyn Fn(MenuAction)>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(TargetIvars { act });
        // SAFETY: NSObject's `init` takes nothing and returns the initialised object.
        unsafe { msg_send![super(this), init] }
    }
}

thread_local! {
    // A menu item holds its target weakly, so the target lives here for the app's life.
    static TARGET: RefCell<Option<Retained<FileMenuTarget>>> = const { RefCell::new(None) };
}

/// Inserts the File menu after the application menu; each item calls `act` with its action.
pub fn install(mtm: MainThreadMarker, act: impl Fn(MenuAction) + 'static) {
    let target = FileMenuTarget::new(mtm, Box::new(act));
    let menu = NSMenu::initWithTitle(NSMenu::alloc(mtm), &NSString::from_str(FILE));
    for entry in file_entries() {
        // SAFETY: each selector is a method of `FileMenuTarget` taking the sender, and the item targets it.
        let item = unsafe { NSMenuItem::initWithTitle_action_keyEquivalent(NSMenuItem::alloc(mtm), &NSString::from_str(entry.title), Some(selector(entry.action)), &NSString::from_str(entry.key)) };
        item.setKeyEquivalentModifierMask(entry.modifiers);
        // SAFETY: the target is a `FileMenuTarget`, which answers every selector these items send.
        unsafe { item.setTarget(Some(&target)) };
        menu.addItem(&item);
    }
    let holder = NSMenuItem::new(mtm);
    holder.setTitle(&NSString::from_str(FILE));
    holder.setSubmenu(Some(&menu));

    let application = NSApplication::sharedApplication(mtm);
    let bar = application.mainMenu().unwrap_or_else(|| {
        let bar = NSMenu::new(mtm);
        application.setMainMenu(Some(&bar));
        bar
    });
    if let Some(previous) = bar.itemWithTitle(&NSString::from_str(FILE)) {
        bar.removeItem(&previous);
    }
    bar.insertItem_atIndex(&holder, FILE_MENU_INDEX.min(bar.numberOfItems()));
    TARGET.with(|slot| *slot.borrow_mut() = Some(target));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offers_the_swift_file_menu_titles_keys_and_modifiers() {
        let expected = [("New Window", "N", COMMAND), ("Open Project…", "o", COMMAND), ("Close Window", "w", COMMAND)];

        let offered: Vec<(&str, &str, NSEventModifierFlags)> = file_entries().iter().map(|entry| (entry.title, entry.key, entry.modifiers)).collect();

        assert_eq!(offered, expected);
    }

    #[test]
    fn sends_each_entry_to_its_own_action_selector() {
        let entries = file_entries();

        let routed: Vec<(MenuAction, Sel)> = entries.iter().map(|entry| (entry.action, selector(entry.action))).collect();

        let expected = [(MenuAction::NewWindow, sel!(newWindow:)), (MenuAction::OpenProject, sel!(openProject:)), (MenuAction::CloseWindow, sel!(closeWindow:))];
        assert_eq!(routed, expected);
    }
}
