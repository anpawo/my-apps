//! The VCX window in Rust: tao for the window, wry for the system web view that draws the page template.
//! `vcx-shell` runs one window; `vcx-app` runs many over the same panes.

pub mod app;
pub mod bridge;
pub mod chart;
pub mod check;
pub mod composer;
pub mod input;
pub mod link;
pub mod menu;
pub mod pane;
pub mod progress;
pub mod run;
pub mod session;
pub mod snapshot;
pub mod summary;
pub mod template;
