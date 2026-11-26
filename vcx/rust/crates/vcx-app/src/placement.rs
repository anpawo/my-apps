//! Where a window lands and how it looks, as the Swift app sets it (`main.swift` `open`): a new window at 19/20 of the
//! screen's width, centred, whatever size the last one was left at; the light look whatever the system's; and only a
//! window he asked for in front, one opened from outside (spawn, Watcher, an update) behind his current window.

use objc2::AnyThread;
use objc2_app_kit::{NSAppearance, NSAppearanceCustomization, NSAppearanceNameAqua, NSApplication, NSApplicationActivationOptions, NSApplicationActivationPolicy, NSColor, NSImage, NSRunningApplication, NSScreen, NSWindow, NSWindowOrderingMode};
use objc2_foundation::{MainThreadMarker, NSBundle, NSPoint, NSRect, NSSize, NSString};
use tao::platform::macos::WindowExtMacOS;
use tao::window::Window;

/// The new window leaves 1/40 of the screen's width on each side and 1/20 of its height above and below.
const SIDE_MARGIN: f64 = 1.0 / 40.0;
const END_MARGIN: f64 = 1.0 / 20.0;
/// `Contents/Resources/VCX.icns`, which build-rust.sh puts there.
const ICON: &str = "VCX";

/// The frame of a new window on a screen whose visible part is `screen`, rounded out to whole points as Swift's
/// `integral` does.
pub fn new_frame(screen: NSRect) -> NSRect {
    let (dx, dy) = (screen.size.width * SIDE_MARGIN, screen.size.height * END_MARGIN);
    let (x, y) = ((screen.origin.x + dx).floor(), (screen.origin.y + dy).floor());
    let (right, top) = ((screen.origin.x + screen.size.width - dx).ceil(), (screen.origin.y + screen.size.height - dy).ceil());
    NSRect::new(NSPoint::new(x, y), NSSize::new(right - x, top - y))
}

fn ns_window(window: &Window) -> Option<&NSWindow> {
    // SAFETY: tao hands the NSWindow it owns for as long as `window` lives, which outlasts every use here.
    unsafe { (window.ns_window() as *const NSWindow).as_ref() }
}

/// The Swift window's look: a transparent title bar on a white window, in the light appearance.
pub fn dress(window: &Window) {
    let Some(ns_window) = ns_window(window) else { return };
    ns_window.setTitlebarAppearsTransparent(true);
    // SAFETY: an AppKit constant, read on the main thread.
    let aqua = NSAppearance::appearanceNamed(unsafe { NSAppearanceNameAqua });
    ns_window.setAppearance(aqua.as_deref());
    ns_window.setBackgroundColor(Some(&NSColor::whiteColor()));
}

/// Shows a window built hidden, first at its Swift place on the main screen when `place`: in front and active when
/// he asked for it, behind his current window otherwise.
pub fn show(window: &Window, mtm: MainThreadMarker, place: bool, focus: bool) {
    let Some(ns_window) = ns_window(window) else { return };
    if place {
        if let Some(screen) = NSScreen::mainScreen(mtm) {
            ns_window.setFrame_display(new_frame(screen.visibleFrame()), false);
        }
    }
    let app = NSApplication::sharedApplication(mtm);
    match app.keyWindow() {
        Some(key) if !focus => ns_window.orderWindow_relativeTo(NSWindowOrderingMode::Below, key.windowNumber()),
        _ => ns_window.makeKeyAndOrderFront(None),
    }
    if focus {
        #[allow(deprecated)]
        app.activateIgnoringOtherApps(true);
    }
}

/// The Dock tile reads the bundle's icon from the running app: the Dock's own cache outlives rebuilds (Swift
/// `main.swift`: it served an old icon for weeks). Nothing happens outside the bundle.
pub fn show_icon(mtm: MainThreadMarker) {
    let Some(path) = NSBundle::mainBundle().pathForResource_ofType(Some(&NSString::from_str(ICON)), Some(&NSString::from_str("icns"))) else { return };
    let Some(icon) = NSImage::initWithContentsOfFile(NSImage::alloc(), &path) else { return };
    // SAFETY: a loaded image, set on the main thread.
    unsafe { NSApplication::sharedApplication(mtm).setApplicationIconImage(Some(&icon)) };
}

/// A launch he asked to focus, forwarded to the app already running, hands it the focus: the running app cannot take
/// it from the background (Swift `main.swift`: "activation count being 0" with another app in front, 13/11). Nothing
/// happens outside the bundle, as in tests.
pub fn hand_focus_to_running_app() {
    let Some(bundle) = NSBundle::mainBundle().bundleIdentifier() else { return };
    let own = std::process::id() as i32;
    let running = NSRunningApplication::runningApplicationsWithBundleIdentifier(&bundle);
    let Some(app) = running.iter().find(|app| app.processIdentifier() != own && app.activationPolicy() == NSApplicationActivationPolicy::Regular) else { return };
    app.activateFromApplication_options(&NSRunningApplication::currentApplication(), NSApplicationActivationOptions::empty());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_a_new_window_at_nineteen_twentieths_of_the_screen_width_centred() {
        let screen = NSRect::new(NSPoint::new(0.0, 25.0), NSSize::new(1600.0, 1000.0));

        let frame = new_frame(screen);

        assert_eq!((frame.origin.x, frame.origin.y, frame.size.width, frame.size.height), (40.0, 75.0, 1520.0, 900.0));
    }

    #[test]
    fn rounds_a_new_window_out_to_whole_points_on_an_odd_screen() {
        let screen = NSRect::new(NSPoint::new(-1512.0, 0.0), NSSize::new(1512.0, 945.0));

        let frame = new_frame(screen);

        assert_eq!((frame.origin.x, frame.origin.y, frame.size.width, frame.size.height), (-1475.0, 47.0, 1438.0, 851.0));
    }
}
