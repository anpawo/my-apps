//! The wire protocol between a VCX frontend and a runtime worker, as the Swift app speaks it (`RuntimeTransport`,
//! `RuntimeServer`, `RuntimeClient`): one JSON object per line over a Unix socket owned by this user.

pub mod channel;
pub mod client;
pub mod frame;

pub use client::{AttachRequest, Attachment, Client, Error, Event, Fault, Hello, Lease};
pub use frame::Object;
