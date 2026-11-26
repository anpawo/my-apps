//! Saved conversations, ported from the Swift `Session` (Session.swift `save`, `restore`, `switchThread`,
//! `archiveForClose`): the record saved as Swift saves it, its lock and native leases, the `/resume` list, moving to
//! another record with a rollback, and archiving a record once closed or replaced.

use super::{Object, SessionBackend, text};
use crate::archive::Archive;
use crate::provider;
use crate::records::{self, NativeSource};
use crate::session::Choices;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;
use vcx_agents::Connection;
use vcx_config::Account;

const STOP_POLL: Duration = Duration::from_millis(100);
const STOP_POLLS: usize = 100;
const STILL_STOPPING: &str = "The agent is still stopping; its native history has been kept.";
const CLOSING: &str = "This conversation is closing.";
const CHANGING: &str = "Wait for the current connection change before closing this conversation.";
const AMBIGUOUS: &str = "Choose the exact saved conversation and profile to resume this native ID.";
const GONE: &str = "The saved conversation no longer exists.";
const CLOSED: &str = "This runtime session is closed.";
const REFRESH_FAILED: &str = "Could not refresh conversations or account details: ";
const NATIVE_PREFIX: &str = "native:";
const NAMESPACED: [&str; 3] = ["claude", "agy", "qwen"];
const NO_POINTER: &str = "No saved conversation in this folder.";
const CLAUDE_PROJECTS: &str = ".claude/projects";
/// my-setup's chats.py deletes a closed session's Claude transcript once chats.sqlite holds it; a resume writes it back.
const CHATS: &str = "self/my-setup/macos/dream/chats.py";

/// The saved record as the worker holds it: its lock, the leases on its native threads, and where it stands in
/// being archived. Carried across a live update with its descriptors.
#[derive(Default)]
pub struct Records {
    native: bool,
    lock: Option<(String, File)>,
    leases: HashMap<String, File>,
    /// The running agent's process group, waited for before its history is archived.
    pub(super) group: Option<i32>,
    last_snapshot: Option<PathBuf>,
    archived_for_close: bool,
    archiving: bool,
    switching: bool,
    recovery_needed: bool,
    recovering: bool,
    suppress_save: bool,
    archived_recent: Vec<Value>,
    pending_restore: Option<String>,
    saved: String,
}

fn adopted(descriptor: &Value) -> Option<File> {
    let descriptor = RawFd::try_from(descriptor.as_i64()?).ok()?;
    // SAFETY: the previous image left this descriptor open for this one alone; it is taken over once, here.
    unsafe {
        libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC);
        Some(File::from_raw_fd(descriptor))
    }
}

impl Records {
    pub fn new(native: bool) -> Self {
        Self { native, ..Self::default() }
    }

    /// `None` while a record changes hands: an exec then would lose the change.
    pub fn frozen(&self) -> Option<Value> {
        if self.archiving || self.switching || self.recovering {
            return None;
        }
        let leases: Object = self.leases.iter().map(|(key, file)| (key.clone(), json!(file.as_raw_fd()))).collect();
        let lock = self.lock.as_ref().map(|(id, file)| json!({"id": id, "descriptor": file.as_raw_fd()}));
        Some(json!({
            "native": self.native, "lock": lock, "leases": leases, "lastSnapshot": self.last_snapshot, "archivedForClose": self.archived_for_close,
            "recoveryNeeded": self.recovery_needed, "archivedRecent": self.archived_recent, "pendingRestore": self.pending_restore,
        }))
    }

    /// The records a previous image froze; one from before records were carried keeps `native` as configured.
    pub fn adopt(state: &Value, agent: &Value, native: bool) -> Self {
        let lock = state["lock"]["id"].as_str().and_then(|id| Some((id.to_owned(), adopted(&state["lock"]["descriptor"])?)));
        let leases = state["leases"].as_object().into_iter().flatten().filter_map(|(key, descriptor)| Some((key.clone(), adopted(descriptor)?))).collect();
        Self {
            native: state["native"].as_bool().unwrap_or(native),
            lock,
            leases,
            group: agent["agent"]["pid"].as_i64().and_then(|pid| i32::try_from(pid).ok()),
            last_snapshot: state["lastSnapshot"].as_str().map(PathBuf::from),
            archived_for_close: state["archivedForClose"] == true,
            recovery_needed: state["recoveryNeeded"] == true,
            archived_recent: state["archivedRecent"].as_array().cloned().unwrap_or_default(),
            pending_restore: state["pendingRestore"].as_str().map(str::to_owned),
            ..Self::default()
        }
    }

    pub fn descriptors(state: &Value) -> Vec<RawFd> {
        let leases = state["leases"].as_object().into_iter().flatten().map(|(_, descriptor)| descriptor);
        std::iter::once(&state["lock"]["descriptor"]).chain(leases).filter_map(|descriptor| RawFd::try_from(descriptor.as_i64()?).ok()).collect()
    }
}

/// The process group of an agent this worker started, when it can say.
pub(super) fn agent_group(agent: &Connection) -> Option<i32> {
    agent.freeze()?["agent"]["pid"].as_i64().and_then(|pid| i32::try_from(pid).ok())
}

/// The Swift `stopForArchive`'s wait: the closed agent's group has left, so none of its files is still open.
async fn wait_for_exit(group: Option<i32>) -> Result<(), String> {
    let Some(group) = group else { return Ok(()) };
    for _ in 0..STOP_POLLS {
        // SAFETY: signal 0 only asks whether the group still has a process.
        if unsafe { libc::kill(-group, 0) } != 0 {
            return Ok(());
        }
        tokio::time::sleep(STOP_POLL).await;
    }
    Err(STILL_STOPPING.into())
}

fn provider_of(thread: &str) -> &str {
    thread.split_once(':').map(|(prefix, _)| prefix).filter(|prefix| NAMESPACED.contains(prefix)).unwrap_or("codex")
}

fn draft_is_empty(draft: &[Value]) -> bool {
    draft.iter().all(|piece| piece["type"] == "text" && piece["text"].as_str().is_some_and(str::is_empty))
}

/// A record left behind by a switch, archived once the new one is open.
pub(super) struct Retiring {
    id: String,
    path: PathBuf,
    thread: Option<String>,
    history_path: Option<String>,
    sources: Vec<NativeSource>,
    leases: HashMap<String, File>,
    client_versions: Object,
    lock: Option<(String, File)>,
    group: Option<i32>,
}

/// A record found for a name: its id and the source the name chose.
type Target = (String, Option<NativeSource>);

impl SessionBackend {
    pub(super) fn native_history(&self) -> bool {
        self.records.borrow().native
    }

    fn state_path(&self) -> PathBuf {
        PathBuf::from(&self.session.borrow().state_directory)
    }

    fn archive<'a>(&'a self, state: &'a Path) -> Archive<'a> {
        Archive { state, native: &self.config.native }
    }

    fn snapshot_path(&self) -> PathBuf {
        let session = self.session.borrow();
        records::snapshot(Path::new(&session.state_directory), &session.conversation_directory, &session.record_id)
    }

    fn check_open(&self) -> Result<(), String> {
        if self.closed.get() { Err(CLOSED.into()) } else { Ok(()) }
    }

    fn holds_record(&self, id: &str) -> bool {
        self.records.borrow().lock.as_ref().is_some_and(|(held, _)| held == id)
    }

    fn claim_current_record(&self) -> Result<(), String> {
        let id = self.session.borrow().record_id.clone();
        if self.holds_record(&id) {
            return Ok(());
        }
        let state = self.state_path();
        self.config.native.allows(&state)?;
        let file = records::claim_record(&state, &id)?;
        self.records.borrow_mut().lock = Some((id, file));
        Ok(())
    }

    /// The account the session runs, its home as the session holds it (a restored profile's).
    fn session_account(&self) -> Account {
        let account = self.session.borrow().account.clone();
        let mut current = self.current_account();
        if account["id"].as_str() == Some(current.id.as_str()) {
            current.home = account["home"].as_str().map(str::to_owned).or(current.home);
        }
        current
    }

    /// The Swift `nativeSource`: where `account`'s provider keeps `thread`.
    fn native_source(&self, thread: &str, account: &Account, path: Option<String>, pending: bool) -> NativeSource {
        let home = vcx_config::homes::home_directory();
        let joined = |name: &str| home.join(name).to_string_lossy().into_owned();
        let folder = match account.provider.as_str() {
            "claude" => account.home.clone().unwrap_or_else(|| joined(".claude")),
            "codex" => provider::environment(account, &home, "").into_iter().rev().find(|(key, _)| key == "CODEX_HOME").map_or_else(|| joined(".codex"), |(_, value)| value),
            _ => joined(".gemini/antigravity-cli"),
        };
        let mut source = NativeSource::new(&account.provider, &folder, thread, path, pending);
        source.account_id = Some(account.id.clone());
        source
    }

    fn lease_source(&self, source: &NativeSource) -> Result<(), String> {
        let key = source.key();
        if !self.native_history() || self.records.borrow().leases.contains_key(&key) {
            return Ok(());
        }
        self.config.native.allows(Path::new(&source.home))?;
        let file = records::lease(&self.config.native.locks, source)?;
        self.records.borrow_mut().leases.insert(key, file);
        Ok(())
    }

    /// The Swift `rememberNativeSource`.
    fn remember_source(&self, thread: &str, path: Option<String>, pending: bool, managed: bool) -> Result<(), String> {
        if !self.native_history() {
            return Ok(());
        }
        let mut source = self.native_source(thread, &self.session_account(), path.clone(), pending);
        source.managed = managed;
        source.client_version = self.session.borrow().client_version.clone();
        self.lease_source(&source)?;
        let key = source.key();
        let mut session = self.session.borrow_mut();
        match session.native_sources.iter().position(|known| known.key() == key) {
            Some(index) => {
                let known = &session.native_sources[index];
                source.path = path.or_else(|| known.path.clone());
                source.pending_creation = known.pending_creation && pending;
                source.managed = known.managed || managed;
                session.native_sources[index] = source;
            }
            None => session.native_sources.push(source),
        }
        Ok(())
    }

    fn restorable_accounts(&self) -> Vec<Account> {
        let settings = self.settings();
        let mut accounts = settings.accounts();
        accounts.extend(settings.candidates("auto").into_iter().filter(|account| account.provider == "agy" || account.provider == "qwen"));
        accounts
    }

    fn stored_account(&self, record: &Object, provider: &str) -> Account {
        let id = text(record, "accountId");
        let saved = || Account { id: uuid::Uuid::new_v4().to_string().to_uppercase(), name: "Saved profile".into(), provider: provider.to_owned(), home: None, enabled: true };
        self.restorable_accounts().into_iter().find(|account| Some(account.id.as_str()) == id).unwrap_or_else(saved)
    }

    /// Records saved before the archive carry no provider; their thread's prefix or account names it.
    fn saved_provider(&self, record: &Object) -> Option<String> {
        if let Some(provider) = text(record, "provider") {
            return Some(provider.to_owned());
        }
        let thread = text(record, "threadId")?;
        if let Some((prefix, _)) = thread.split_once(':').filter(|(prefix, _)| NAMESPACED.contains(prefix)) {
            return Some(prefix.to_owned());
        }
        let id = text(record, "accountId");
        Some(self.restorable_accounts().into_iter().find(|account| Some(account.id.as_str()) == id).map_or_else(|| "codex".to_owned(), |account| account.provider))
    }

    /// A record's sources; one saved before sources were kept names its thread and account only.
    fn record_sources(&self, record: &Object) -> Vec<NativeSource> {
        let sources = NativeSource::list(record.get("nativeSources"));
        if !sources.is_empty() {
            return sources;
        }
        let (Some(thread), Some(provider)) = (text(record, "threadId"), self.saved_provider(record)) else { return sources };
        vec![self.native_source(thread, &self.stored_account(record, &provider), text(record, "nativeHistoryPath").map(str::to_owned), false)]
    }

    fn merge_snapshot_sources(&self, paths: &[PathBuf]) -> Result<(), String> {
        for path in paths {
            let record = records::read_object(path).ok_or("Could not read an earlier conversation snapshot.")?;
            for source in self.record_sources(&record) {
                if !self.session.borrow().native_sources.iter().any(|known| known.key() == source.key()) {
                    self.lease_source(&source)?;
                    self.session.borrow_mut().native_sources.push(source);
                }
            }
        }
        Ok(())
    }

    /// The Swift `save`: the record, its folder's pointer, and earlier snapshots of it in other folders merged away.
    pub(super) fn save(&self) -> bool {
        let skipped = {
            let records = self.records.borrow();
            !records.native || records.suppress_save || records.archiving || records.archived_for_close || self.closed.get()
        };
        if skipped || self.session.borrow().thread_id.is_none() {
            return false;
        }
        match self.write_record() {
            Ok(()) => true,
            Err(error) => {
                self.session.borrow_mut().status = format!("Could not save conversation: {error}");
                false
            }
        }
    }

    fn write_record(&self) -> Result<(), String> {
        self.claim_current_record()?;
        let state = self.state_path();
        let snapshot = self.snapshot_path();
        let (id, directory) = {
            let session = self.session.borrow();
            (session.record_id.clone(), session.conversation_directory.clone())
        };
        let resolved = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
        let earlier: Vec<PathBuf> = if self.records.borrow().last_snapshot.as_ref() == Some(&snapshot) { Vec::new() } else { records::record_files(&state, &id).into_iter().filter(|path| resolved(path) != resolved(&snapshot)).collect() };
        self.merge_snapshot_sources(&earlier)?;
        let choices = Choices { provider: self.provider_choice.borrow().clone(), account: self.account_choice.borrow().clone(), mode: self.mode_choice.borrow().clone() };
        let record = self.session.borrow().record(choices);
        records::write_private(&snapshot, &serde_json::to_vec(&record).map_err(|error| error.to_string())?)?;
        for path in &earlier {
            std::fs::remove_file(path).map_err(|error| error.to_string())?;
        }
        self.records.borrow_mut().last_snapshot = Some(snapshot);
        records::write_private(&records::native_pointer(&state, &directory), json!({"recordId": id}).to_string().as_bytes())
    }

    /// Saves once something worth keeping changed since the last save: a publish asks after every change.
    pub(super) fn save_if_changed(&self) {
        if !self.native_history() {
            return;
        }
        let signature = self.session.borrow().save_signature();
        if self.records.borrow().saved != signature && self.save() {
            self.records.borrow_mut().saved = signature;
        }
    }

    /// The Swift `open`'s bookkeeping once a thread is open: its source, Codex's resume pointer, the record saved.
    pub(super) fn thread_opened(&self, resume: Option<&str>) -> Result<(), String> {
        let (thread, path, codex, state, directory) = {
            let session = self.session.borrow();
            (session.thread_id.clone().unwrap_or_default(), session.native_history_path.clone(), session.provider == "codex", PathBuf::from(&session.state_directory), session.conversation_directory.clone())
        };
        self.remember_source(&thread, path, resume.is_none(), resume.is_none())?;
        if codex {
            if let Err(error) = records::write_private(&records::resume_pointer(&state, &directory), json!({"threadId": thread}).to_string().as_bytes()) {
                self.session.borrow_mut().notice(&format!("Could not save the resume pointer: {error}"));
            }
        }
        self.save();
        Ok(())
    }

    /// A prompt reached the thread: its history now exists.
    pub(super) fn prompt_delivered(&self) {
        let (thread, path) = {
            let session = self.session.borrow();
            (session.thread_id.clone(), session.native_history_path.clone())
        };
        if let Some(thread) = thread {
            let _ = self.remember_source(&thread, path, false, false);
            self.save();
        }
    }

    /// The start of the Swift `activate`: a closing conversation opens nothing, and a resumed thread is claimed first.
    pub(super) fn before_activation(&self, account: &Account, resume: Option<&str>) -> Result<(), String> {
        let closing = {
            let records = self.records.borrow();
            records.archiving || records.archived_for_close
        };
        if self.closed.get() || closing {
            return Err(CLOSING.into());
        }
        if let Some(resume) = resume.filter(|_| self.native_history()) {
            self.claim_current_record()?;
            self.lease_source(&self.native_source(resume, account, None, false))?;
        }
        Ok(())
    }

    pub(super) fn activated(&self) {
        self.records.borrow_mut().pending_restore = None;
    }

    pub(super) fn pending_restore(&self) -> Option<String> {
        self.records.borrow().pending_restore.clone()
    }

    /// A conversation the frontend named to resume, when the checkpoint names no thread to reopen.
    pub(super) fn named_resume(&self, params: &Object) -> Option<String> {
        let checkpointed = self.recovery.borrow().as_ref().and_then(|state| text(state, "threadID")).is_some();
        text(params, "resume").filter(|resume| !resume.is_empty() && !checkpointed && self.native_history()).map(str::to_owned)
    }

    /// The Swift `connect(resume:)`: a saved record is restored; a native thread opens on the one profile of its
    /// provider, `last` being the folder's Codex thread and a bare Claude session ID found among his projects.
    pub(super) async fn resume_named(self: &Rc<Self>, resume: &str) -> Result<(), String> {
        let settings = self.settings();
        *self.provider_choice.borrow_mut() = Some(self.config.provider.clone().unwrap_or_else(|| settings.default_provider()));
        if let Some((id, source)) = self.saved_record(resume).await? {
            return self.restore(&id, source, None).await;
        }
        let mut id = resume.to_owned();
        if resume == "last" {
            let directory = self.session.borrow().conversation_directory.clone();
            let pointer = records::read_object(&records::resume_pointer(&self.state_path(), &directory));
            id = pointer.as_ref().and_then(|pointer| text(pointer, "threadId")).ok_or(NO_POINTER)?.to_owned();
        }
        // A bare Claude session ID (vcx --resume <id>) went to Codex, which answered "no rollout found".
        if !id.contains(':') {
            self.restore_claude_transcript(&id).await;
        }
        let projects = vcx_config::homes::home_directory().join(CLAUDE_PROJECTS);
        let claude = std::fs::read_dir(&projects).into_iter().flatten().flatten().any(|project| project.path().join(format!("{id}.jsonl")).is_file());
        if !id.contains(':') && claude {
            id = format!("claude:{id}");
        }
        let provider = if id.starts_with("claude:") { "claude" } else if id.starts_with("agy:") { "agy" } else { "codex" };
        let profiles: Vec<Account> = settings.candidates(provider).into_iter().filter(|account| account.provider == provider && account.enabled).collect();
        let [profile] = profiles.as_slice() else { return Err(AMBIGUOUS.into()) };
        self.activate_rows(profile, Some(id), None, false).await
    }

    /// The Swift `restoreClaudeTranscript`, default Claude home only; a test worker never runs his chats.py.
    pub(super) async fn restore_claude_transcript(&self, id: &str) {
        if self.config.native.flag.is_some() {
            return;
        }
        let script = vcx_config::homes::home_directory().join(CHATS);
        let quiet = std::process::Stdio::null;
        let _ = tokio::process::Command::new("/usr/bin/python3").arg("-I").arg(script).args(["restore", id]).stdin(quiet()).stdout(quiet()).stderr(quiet()).kill_on_drop(true).status().await;
    }
}

mod archiving;
mod listing;
mod switching;
