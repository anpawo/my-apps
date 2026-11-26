//! The files a session's agent writes for VCX, in a folder of the session's own as the Swift `Session` keeps them:
//! the Fleet label (`FLEET_CONTEXT_FILE`), the progress line the status bar draws (`VCX_PROGRESS_FILE`) and the
//! goal the task bar lists (`VCX_TASK_FILE`).

use std::os::unix::fs::DirBuilderExt;
use std::path::Path;

pub const CONTEXT_VARIABLE: &str = "FLEET_CONTEXT_FILE";
pub const PROGRESS_VARIABLE: &str = "VCX_PROGRESS_FILE";
pub const TASK_VARIABLE: &str = "VCX_TASK_FILE";
pub const VARIABLES: [&str; 3] = [CONTEXT_VARIABLE, PROGRESS_VARIABLE, TASK_VARIABLE];
const FOLDER_PREFIX: &str = "vcx-fleet-";
const CONTEXT: &str = "task.context";
const PROGRESS: &str = "task.progress";
const TASK: &str = "task.goal";
const PRIVATE_FOLDER: u32 = 0o700;

/// A new session's Fleet file, in a private folder of its own under the temporary folder.
pub fn create() -> String {
    let folder = std::env::temp_dir().join(format!("{FOLDER_PREFIX}{}", uuid::Uuid::new_v4().to_string().to_uppercase()));
    if let Err(error) = std::fs::DirBuilder::new().recursive(true).mode(PRIVATE_FOLDER).create(&folder) {
        eprintln!("VCX: could not create Fleet context directory: {error}");
    }
    folder.join(CONTEXT).to_string_lossy().into_owned()
}

fn beside(fleet: &str, name: &str) -> String {
    match Path::new(fleet).parent() {
        Some(folder) if !fleet.is_empty() => folder.join(name).to_string_lossy().into_owned(),
        _ => String::new(),
    }
}

pub fn progress_path(fleet: &str) -> String {
    beside(fleet, PROGRESS)
}

pub fn task_path(fleet: &str) -> String {
    beside(fleet, TASK)
}

/// What the agent's environment names, never an inherited session's: none when the session has no Fleet file.
pub fn variables(fleet: &str) -> Vec<(String, String)> {
    if fleet.is_empty() {
        return Vec::new();
    }
    [(CONTEXT_VARIABLE, fleet.to_owned()), (PROGRESS_VARIABLE, progress_path(fleet)), (TASK_VARIABLE, task_path(fleet))].map(|(key, value)| (key.to_owned(), value)).into()
}

/// The label the agent wrote, trimmed.
pub fn context(fleet: &str) -> String {
    std::fs::read_to_string(fleet).map(|text| text.trim().to_owned()).unwrap_or_default()
}

/// A new conversation starts without the previous one's label.
pub fn clear(fleet: &str) {
    let _ = std::fs::remove_file(fleet);
}

/// Removes the session's folder, only ever one `create` made: the path comes back from a saved session.
pub fn remove(fleet: &str) {
    let folder = Path::new(fleet).parent().filter(|folder| folder.file_name().is_some_and(|name| name.to_string_lossy().starts_with(FOLDER_PREFIX)));
    if let Some(folder) = folder {
        let _ = std::fs::remove_dir_all(folder);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn progress_and_task_files_sit_beside_the_fleet_file() {
        let fleet = "/tmp/fleet-a/task.context";

        let variables = variables(fleet);

        assert_eq!(variables, [("FLEET_CONTEXT_FILE", fleet), ("VCX_PROGRESS_FILE", "/tmp/fleet-a/task.progress"), ("VCX_TASK_FILE", "/tmp/fleet-a/task.goal")].map(|(key, value)| (key.to_owned(), value.to_owned())));
    }

    #[test]
    fn a_session_without_a_fleet_file_names_none() {
        assert!(variables("").is_empty());
        assert_eq!((progress_path(""), task_path("")), (String::new(), String::new()));
    }

    #[test]
    fn each_session_gets_a_private_folder_of_its_own() {
        let (first, second) = (create(), create());

        let mode = std::fs::metadata(Path::new(&first).parent().unwrap()).unwrap().permissions().mode() & 0o777;
        remove(&first);
        remove(&second);

        assert_ne!(Path::new(&first).parent(), Path::new(&second).parent());
        assert_eq!(mode, PRIVATE_FOLDER);
        assert!(!Path::new(&first).parent().unwrap().exists());
    }

    #[test]
    fn reads_the_label_trimmed_and_clears_it_for_a_new_conversation() {
        let fleet = create();
        std::fs::write(&fleet, "Fix Fleet names\n").unwrap();

        let label = context(&fleet);
        clear(&fleet);
        let cleared = context(&fleet);
        remove(&fleet);

        assert_eq!((label.as_str(), cleared.as_str()), ("Fix Fleet names", ""));
    }

    #[test]
    fn never_removes_a_folder_it_did_not_make() {
        let folder = std::env::temp_dir().join(format!("vcx-not-fleet-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();

        remove(&folder.join(CONTEXT).to_string_lossy());
        let kept = folder.exists();
        std::fs::remove_dir_all(&folder).unwrap();

        assert!(kept);
    }
}
