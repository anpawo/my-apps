//! The archive of closed conversations, which the Swift app's `conversation_archive.py` keeps in
//! `<state>/conversations.sqlite`: the worker runs that script as `ConversationArchive.swift` does, a JSON request on
//! its stdin. The script moves and prunes provider history, so a test worker reaches it only inside its own folder.

use crate::records::{NativeSource, Object, canonical_archive_root};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::AsyncWriteExt;

pub const FAILED: &str = "Could not archive or restore the conversation. Existing history has been retained.";
const SCRIPT: &str = "conversation_archive.py";
const PYTHON: &str = "/usr/bin/python3";
const PRUNED_PROVIDERS: [&str; 4] = ["claude", "codex", "agy", "qwen"];
/// A test worker keeps native history only while this file exists in its runtime home.
pub const TEST_FLAG: &str = "native-history";
const TEMPORARY: &str = "/tmp";
const LOCKS: &str = "native-locks";
const LOCK_VARIABLE: &str = "VCX_NATIVE_LOCK_HOME";

/// Where a worker keeps native history. A test worker keeps it only once `flag` exists, and only inside `confined`:
/// every state folder, provider home and lock folder is checked against it before use.
#[derive(Debug, Clone, Default)]
pub struct Native {
    pub locks: PathBuf,
    pub confined: Option<PathBuf>,
    pub flag: Option<PathBuf>,
    /// A test worker whose folder is not a temporary one keeps none.
    pub disabled: bool,
}

impl Native {
    /// A test worker's: confined to the folder holding its runtime home, and only when that folder is temporary.
    pub fn test(runtime: &Path, state: &Path) -> Self {
        let temporary = [Path::new(TEMPORARY), &std::env::temp_dir()].map(|root| canonical_archive_root(root).ok());
        let confined = runtime.parent().and_then(|folder| canonical_archive_root(folder).ok()).filter(|folder| temporary.iter().flatten().any(|root| folder.starts_with(root) && folder != root));
        Self { locks: state.join(LOCKS), disabled: confined.is_none(), confined, flag: Some(runtime.join(TEST_FLAG)) }
    }

    /// His worker's: `VCX_NATIVE_LOCK_HOME` names the lease folder, as for the Swift app.
    pub fn production(state: &Path) -> Self {
        let locks = std::env::var_os(LOCK_VARIABLE).filter(|value| !value.is_empty()).map_or_else(|| state.join(LOCKS), PathBuf::from);
        Self { locks, ..Self::default() }
    }

    pub fn enabled(&self) -> bool {
        !self.disabled && self.flag.as_ref().is_none_or(|flag| flag.exists()) && self.allows(&self.locks).is_ok()
    }

    pub fn allows(&self, path: &Path) -> Result<(), String> {
        let Some(root) = &self.confined else { return Ok(()) };
        match canonical_archive_root(path) {
            Ok(resolved) if resolved.starts_with(root) => Ok(()),
            _ => Err(format!("Native history is kept only inside the test folder, not at {}.", path.display())),
        }
    }
}

/// The bundled script (`<App>.app/Contents/Resources`, beside the worker's `MacOS` folder), else the repository's.
fn script() -> PathBuf {
    let bundled = std::env::current_exe().ok().and_then(|exe| Some(exe.parent()?.join("../Resources").join(SCRIPT))).filter(|path| path.is_file());
    bundled.unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..").join(SCRIPT))
}

/// The archive of one state folder.
pub struct Archive<'a> {
    pub state: &'a Path,
    pub native: &'a Native,
}

impl Archive<'_> {
    fn confine(&self, sources: &[NativeSource]) -> Result<(), String> {
        self.native.allows(self.state)?;
        sources.iter().try_for_each(|source| self.native.allows(Path::new(&source.home)))
    }

    async fn call(&self, action: &str, values: Value, sources: &[NativeSource]) -> Result<Object, String> {
        self.confine(sources)?;
        let mut request = match values {
            Value::Object(object) => object,
            _ => Object::new(),
        };
        request.insert("action".into(), json!(action));
        request.insert("state".into(), json!(self.state));
        let mut child = tokio::process::Command::new(PYTHON).arg(script()).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true).spawn().map_err(|_| FAILED.to_owned())?;
        let mut input = child.stdin.take().ok_or(FAILED)?;
        input.write_all(&serde_json::to_vec(&request).unwrap_or_default()).await.map_err(|_| FAILED.to_owned())?;
        drop(input);
        let output = child.wait_with_output().await.map_err(|_| FAILED.to_owned())?;
        let result: Option<Object> = serde_json::from_slice(&output.stdout).ok();
        result.filter(|result| output.status.success() && result.get("ok") == Some(&Value::Bool(true))).ok_or_else(|| FAILED.to_owned())
    }

    /// The archived conversations, newest first: `{id, summary, updated_at}`.
    pub async fn records(&self) -> Result<Vec<Value>, String> {
        Ok(self.call("list", json!({}), &[]).await?.get("records").and_then(Value::as_array).cloned().unwrap_or_default())
    }

    pub async fn record(&self, id: &str) -> Result<Option<Object>, String> {
        Ok(self.call("read", json!({"id": id}), &[]).await?.get("record").and_then(Value::as_object).cloned())
    }

    /// The archived record `id` names (its own id, a native thread or `last`), with the source it named.
    pub async fn resolve(&self, id: &str) -> Result<Option<(String, Option<NativeSource>)>, String> {
        let result = self.call("resolve", json!({"id": id}), &[]).await?;
        let Some(canonical) = result.get("id").and_then(Value::as_str) else { return Ok(None) };
        Ok(Some((canonical.to_owned(), result.get("source").and_then(NativeSource::from_json))))
    }

    /// Puts an archived record and its history back where they were, never over newer files.
    pub async fn restore(&self, id: &str, preserve_draft: bool) -> Result<(), String> {
        self.call("restore", json!({"id": id, "preserveDraft": preserve_draft}), &[]).await.map(drop)
    }

    pub async fn source_files(&self, sources: &[NativeSource]) -> Result<Vec<String>, String> {
        let paths = self.call("sourceFiles", json!({"sources": sources.iter().map(NativeSource::json).collect::<Vec<_>>()}), sources).await?;
        Ok(paths.get("paths").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect())
    }

    /// Seals the record at `path` and its native history into the archive. No client versions are sent, so no
    /// provider counts as verified and the script deletes no provider file: only the record and its agent log go.
    pub async fn archive(&self, path: &Path, sources: &[NativeSource], owned: &[NativeSource]) -> Result<(), String> {
        let listed = |sources: &[NativeSource]| sources.iter().map(NativeSource::json).collect::<Vec<_>>();
        let values = json!({"recordPath": path, "nativeSources": listed(sources), "ownedSources": listed(owned), "pruneProviders": PRUNED_PROVIDERS, "clientVersions": {}, "childExited": true});
        self.call("archive", values, sources).await.map(drop)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_confined_policy_refuses_a_path_outside_its_folder() {
        let root = canonical_archive_root(&std::env::temp_dir().join(format!("vcx-archive-{}", std::process::id()))).unwrap();
        let native = Native { locks: root.join("state/native-locks"), confined: Some(root.clone()), ..Native::default() };

        let inside = native.allows(&root.join("home/.codex"));
        let outside = native.allows(&vcx_config::homes::home_directory().join(".codex"));

        assert_eq!(inside, Ok(()));
        assert!(outside.is_err());
        assert!(native.enabled());
    }

    #[test]
    fn a_test_worker_keeps_no_native_history_without_its_flag() {
        let root = std::env::temp_dir().join(format!("vcx-archive-flag-{}", std::process::id()));
        let native = Native { locks: root.join("locks"), confined: canonical_archive_root(&root).ok(), flag: Some(root.join(TEST_FLAG)), ..Native::default() };

        assert!(!native.enabled());
    }

    #[test]
    fn a_test_worker_outside_a_temporary_folder_keeps_no_native_history() {
        let home = vcx_config::homes::home_directory();
        let temporary = std::env::temp_dir().join(format!("vcx-archive-test-{}", std::process::id()));

        let outside = Native::test(&home.join(".local/state/vcx/runtime"), &home.join(".local/state/vcx/runtime/test-state"));
        let inside = Native::test(&temporary.join("runtime"), &temporary.join("runtime/test-state"));

        assert!(outside.disabled && outside.confined.is_none());
        assert!(!inside.disabled && inside.confined == canonical_archive_root(&temporary).ok());
    }

    #[test]
    fn finds_the_repository_script_outside_an_app_bundle() {
        assert!(script().is_file(), "{}", script().display());
    }
}
