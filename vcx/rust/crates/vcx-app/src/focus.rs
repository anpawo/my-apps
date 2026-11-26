//! Fleet's tile and Watcher's inbox raise a VCX window by posting `com.mr.vcx.focus` with its `sessionId`, which the
//! Swift app observes (`main.swift`); VCX Rust hears it too, and a session it does not show is left to the other app.

use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_foundation::{NSDistributedNotificationCenter, NSNotification, NSOperationQueue, NSString};
use std::ptr::NonNull;

pub const NAME: &str = "com.mr.vcx.focus";
const SESSION_KEY: &str = "sessionId";

/// Hands `deliver` each session id asked for, on the main thread, for as long as the app runs.
pub fn listen(deliver: impl Fn(String) + 'static) {
    let block = RcBlock::new(move |notification: NonNull<NSNotification>| {
        // SAFETY: the center hands a live notification for the length of the call.
        let notification = unsafe { notification.as_ref() };
        let id = notification.userInfo().and_then(|info| info.objectForKey(&NSString::from_str(SESSION_KEY))).and_then(|value: Retained<AnyObject>| value.downcast::<NSString>().ok());
        if let Some(id) = id {
            deliver(id.to_string());
        }
    });
    let center = NSDistributedNotificationCenter::defaultCenter();
    // SAFETY: no object filter, the main queue, and a block that only reads the notification it is given.
    let observer = unsafe { center.addObserverForName_object_queue_usingBlock(Some(&NSString::from_str(NAME)), None, Some(&NSOperationQueue::mainQueue()), &block) };
    // Observed for the app's whole life: the center keeps the block, the token is never handed back.
    std::mem::forget(observer);
}
