//! The app's settings file (`settings.json` in its config folder). The Swift worker's own preferences (accounts,
//! provider, Qwen) live in the worker's config folder, in the shape the worker writes.

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

/// The Swift app's binary serves as the worker of the Rust app's sessions until a Rust worker exists.
const SWIFT_WORKER: &str = "Applications/Vibe Code X.app/Contents/MacOS/VCX";
const WINDOW_SIZE: (f64, f64) = (1100.0, 760.0);

#[derive(Debug, Clone, PartialEq)]
pub struct Settings {
    /// The worker binary, started as `<worker> --runtime-worker <socket> <worker_arguments…>`.
    pub worker: PathBuf,
    pub worker_arguments: Vec<String>,
    /// A template folder edited live; the built-in template otherwise.
    pub template: Option<PathBuf>,
    /// The size of a new window, in points.
    pub window_size: (f64, f64),
}

impl Default for Settings {
    fn default() -> Self {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()));
        Self { worker: home.join(SWIFT_WORKER), worker_arguments: Vec::new(), template: None, window_size: WINDOW_SIZE }
    }
}

/// Reads the settings, keeping the default of each value missing or unreadable; the problem, if any, is said.
pub fn read(file: &Path) -> (Settings, Option<String>) {
    let mut settings = Settings::default();
    let text = match fs::read_to_string(file) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return (settings, None),
        Err(error) => return (settings, Some(format!("Cannot read {}: {error}.", file.display()))),
    };
    let value: Value = match serde_json::from_str(&text) {
        Ok(Value::Object(value)) => Value::Object(value),
        Ok(_) | Err(_) => return (settings, Some(format!("{} is not a JSON object; the defaults apply.", file.display()))),
    };
    if let Some(worker) = value["worker"].as_str() {
        settings.worker = worker.into();
    }
    if let Some(arguments) = value["workerArguments"].as_array() {
        settings.worker_arguments = arguments.iter().filter_map(Value::as_str).map(str::to_owned).collect();
    }
    settings.template = value["template"].as_str().map(PathBuf::from);
    if let (Some(width), Some(height)) = (value["windowSize"][0].as_f64(), value["windowSize"][1].as_f64()) {
        settings.window_size = (width, height);
    }
    (settings, None)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn written(text: &str) -> (Settings, Option<String>) {
        let file = std::env::temp_dir().join(format!("vcx-app-settings-{}-{}.json", std::process::id(), text.len()));
        fs::write(&file, text).unwrap();
        let read = read(&file);
        fs::remove_file(&file).unwrap();
        read
    }

    #[test]
    fn starts_the_swift_worker_in_a_default_window_when_there_is_no_file() {
        let (settings, problem) = read(Path::new("/nonexistent/settings.json"));

        assert!(settings.worker.ends_with(SWIFT_WORKER));
        assert_eq!((settings.template, settings.window_size, problem), (None, WINDOW_SIZE, None));
    }

    #[test]
    fn takes_the_worker_its_arguments_the_template_and_the_window_size_from_the_file() {
        let (settings, problem) = written(r#"{"worker": "/w", "workerArguments": ["--runtime-test"], "template": "/t", "windowSize": [800, 600]}"#);

        assert_eq!(settings, Settings { worker: "/w".into(), worker_arguments: vec!["--runtime-test".into()], template: Some("/t".into()), window_size: (800.0, 600.0) });
        assert_eq!(problem, None);
    }

    #[test]
    fn keeps_the_defaults_and_says_why_when_the_file_is_not_an_object() {
        let (settings, problem) = written("[1, 2]");

        assert_eq!(settings, Settings::default());
        assert!(problem.unwrap().contains("not a JSON object"));
    }
}
