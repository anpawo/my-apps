//! A picture of the page taken by WebKit itself, which needs no window on screen.

use block2::RcBlock;
use objc2_app_kit::{NSBitmapImageFileType, NSBitmapImageRep, NSImage};
use objc2_foundation::{NSDictionary, NSError};
use wry::{WebView, WebViewExtMacOS};

/// Asks WebKit for a picture of the page and hands `done` its PNG bytes. Called on the main thread; so is `done`.
pub fn take(webview: &WebView, done: impl Fn(Result<Vec<u8>, String>) + 'static) {
    let handler = RcBlock::new(move |image: *mut NSImage, _error: *mut NSError| {
        // SAFETY: WebKit passes a valid image or null, and keeps it alive for the length of this call.
        let image = unsafe { image.as_ref() };
        done(image.ok_or_else(|| "WebKit returned no picture.".to_owned()).and_then(png));
    });
    // SAFETY: the web view lives on the main thread, where this runs; WebKit copies the block it keeps.
    unsafe { webview.webview().takeSnapshotWithConfiguration_completionHandler(None, &handler) };
}

fn png(image: &NSImage) -> Result<Vec<u8>, String> {
    let tiff = image.TIFFRepresentation().ok_or("The picture has no bitmap.")?;
    let bitmap = NSBitmapImageRep::imageRepWithData(&tiff).ok_or("The picture's bitmap is unreadable.")?;
    // SAFETY: an empty dictionary holds no property of a wrong type.
    let data = unsafe { bitmap.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new()) };
    Ok(data.ok_or("The picture could not be encoded as PNG.")?.to_vec())
}
