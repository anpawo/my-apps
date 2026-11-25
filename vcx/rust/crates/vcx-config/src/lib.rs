//! What the VCX app, its worker and its command line stand on: the folders, his settings and the processes they
//! name.

pub mod homes;
pub mod json;
pub mod process;
pub mod settings;
pub mod ticket;

pub use homes::{Homes, WorkerHomes, private_folder, write_private};
pub use json::{Document, Json, Style};
pub use settings::{Account, Qwen, Settings, SettingsFile};
