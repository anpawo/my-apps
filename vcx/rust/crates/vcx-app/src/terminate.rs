//! Quit from the Dock, at logout, or by a quit Apple event (Swift `applicationShouldTerminate`): AppKit asks the
//! app's delegate first, and tao's delegate has no answer, so AppKit would end the process at once with every session
//! left running. The answer added here is "later": the app asks him while a window is busy, ends every session, then
//! exits on its own, or tells AppKit it stays.

use objc2::runtime::{AnyClass, AnyObject, Imp, Sel};
use objc2::{ffi, sel};
use objc2_app_kit::{NSApplication, NSApplicationTerminateReply};
use objc2_foundation::MainThreadMarker;
use std::cell::RefCell;

/// `applicationShouldTerminate:`'s Objective-C types: an NSUInteger from self, _cmd and the sender.
const TYPES: &std::ffi::CStr = c"Q@:@";

thread_local! {
    static DELIVER: RefCell<Option<Box<dyn Fn()>>> = RefCell::new(None);
}

extern "C-unwind" fn should_terminate(_this: *mut AnyObject, _cmd: Sel, _sender: *mut AnyObject) -> NSApplicationTerminateReply {
    DELIVER.with(|deliver| match deliver.borrow().as_ref() {
        Some(deliver) => {
            deliver();
            NSApplicationTerminateReply::TerminateLater
        }
        None => NSApplicationTerminateReply::TerminateNow,
    })
}

/// Calls `deliver` on each quit asked of the app, once tao's event loop has set the delegate.
pub fn listen(mtm: MainThreadMarker, deliver: impl Fn() + 'static) {
    let Some(delegate) = NSApplication::sharedApplication(mtm).delegate() else { return };
    DELIVER.with(|slot| *slot.borrow_mut() = Some(Box::new(deliver)));
    let object: &AnyObject = (*delegate).as_ref();
    let class: *const AnyClass = object.class();
    // SAFETY: the function matches TYPES, and the delegate's class only gains a method it lacks.
    unsafe {
        let imp: Imp = std::mem::transmute(should_terminate as extern "C-unwind" fn(_, _, _) -> _);
        ffi::class_addMethod(class.cast_mut(), sel!(applicationShouldTerminate:), imp, TYPES.as_ptr());
    }
}

/// AppKit's answer once the sessions ended (`quit`) or he declined: back to normal then, and a logout is cancelled.
pub fn answer(mtm: MainThreadMarker, quit: bool) {
    NSApplication::sharedApplication(mtm).replyToApplicationShouldTerminate(quit);
}
