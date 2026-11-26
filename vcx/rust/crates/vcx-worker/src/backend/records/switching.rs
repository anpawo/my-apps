//! Moving the window to another record, ported from the Swift `switchThread`, `restore`, `beginRecordTransition`,
//! `rollbackRecordTransition` and `archiveRetired`: the record left behind is archived once the next one is open,
//! and put back as it was if the next one fails to open.

use super::{AMBIGUOUS, GONE, Retiring, draft_is_empty, provider_of, wait_for_exit};
use crate::backend::{REQUEST_TIMEOUT, SessionBackend, text};
use crate::fallback;
use crate::records::{self, NativeSource, Object};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs::File;
use std::path::Path;
use std::rc::Rc;
use vcx_config::Account;

const DRAFTED: &str = "Send or clear your draft before switching conversations.";
const UNSAVED: &str = "Could not save the current conversation before switching.";
const NO_ACCOUNT: &str = "No enabled account available.";
const ARCHIVE_UNFINISHED: &str = "The previous conversation remains saved. Its archive could not finish: ";
const FORK_CODEX_ONLY: &str = "Fork is available for Codex conversations.";
const NO_FORK: &str = "Codex did not return a forked conversation.";
const NAMESPACED_HOMES: [&str; 2] = ["claude", "codex"];

/// The source a record resumes, the profile that opens it, and whether it is the record's latest thread.
struct Resumed {
    source: NativeSource,
    account: Account,
    latest: bool,
}

impl SessionBackend {
    fn take_draft(&self) -> (Vec<Value>, i64) {
        let mut session = self.session.borrow_mut();
        let generation = session.draft_generation;
        let previous = std::mem::take(&mut session.draft);
        session.set_draft(Vec::new(), generation);
        (previous, generation)
    }

    /// The Swift `restoreDraft`: a draft typed since `generation` is kept after the restored one.
    fn restore_draft(&self, (mut saved, generation): (Vec<Value>, i64)) {
        let mut session = self.session.borrow_mut();
        if session.draft_generation != generation && !draft_is_empty(&session.draft) {
            if !saved.is_empty() {
                saved.push(json!({"type": "text", "text": "\n"}));
            }
            saved.extend(session.draft.iter().cloned());
        }
        let current = session.draft_generation;
        session.set_draft(saved, current);
    }

    /// The Swift `switchThread`: `None` starts a new record, a name resumes the saved one it resolves to.
    pub(in crate::backend) async fn switch_thread(self: &Rc<Self>, id: Option<&str>, from_command: bool) -> bool {
        let (blocked, drafted) = {
            let session = self.session.borrow();
            (session.busy || session.changing || self.closed.get() || self.records.borrow().switching, !draft_is_empty(&session.draft))
        };
        if blocked || (!from_command && drafted) {
            if drafted {
                self.session.borrow_mut().notice(DRAFTED);
            }
            return false;
        }
        self.records.borrow_mut().switching = true;
        let result = self.switch_record(id, from_command).await;
        self.records.borrow_mut().switching = false;
        if let Err(error) = &result {
            if !self.closed.get() {
                self.session.borrow_mut().notice(error);
            }
        }
        self.schedule();
        result.is_ok()
    }

    async fn switch_record(self: &Rc<Self>, id: Option<&str>, from_command: bool) -> Result<(), String> {
        if from_command {
            self.take_draft();
        }
        let previous_draft = (self.session.borrow().draft.clone(), self.session.borrow().draft_generation);
        self.recover_incomplete_archive().await?;
        let target = match id {
            Some(id) => self.saved_record(id).await?,
            None => None,
        };
        self.check_open()?;
        let current = self.session.borrow().record_id.clone();
        if let Some((target, source)) = target.clone().filter(|(target, _)| *target == current) {
            self.take_draft();
            return self.restore(&target, source, None).await.inspect_err(|_| self.restore_draft(previous_draft));
        }
        let previous = self.begin_record_transition()?;
        self.take_draft();
        let opened = match target {
            Some((target, source)) => self.restore(&target, source, None).await,
            None => self.open_named(id).await,
        };
        match opened {
            Ok(()) => {
                self.archive_retired(previous).await;
                self.refresh_catalog().await;
                Ok(())
            }
            Err(error) if self.closed.get() => {
                self.discard(previous);
                Err(error)
            }
            Err(error) => {
                self.rollback(previous);
                self.restore_draft(previous_draft);
                Err(error)
            }
        }
    }

    /// A new record on the first available account, or on the one profile of the provider a bare native ID names.
    async fn open_named(self: &Rc<Self>, id: Option<&str>) -> Result<(), String> {
        let settings = self.settings();
        let next = match id {
            Some(id) => {
                let provider = provider_of(id);
                let profiles: Vec<Account> = settings.candidates(provider).into_iter().filter(|account| account.provider == provider && account.enabled).collect();
                let [profile] = profiles.as_slice() else { return Err(AMBIGUOUS.into()) };
                profile.clone()
            }
            None => self.available(&settings).into_iter().next().ok_or(NO_ACCOUNT)?,
        };
        self.activate_rows(&next, id.map(str::to_owned), None, false).await
    }

    /// The Swift `beginRecordTransition`: the current record is saved and set aside, and a new one takes its place.
    pub(in crate::backend) fn begin_record_transition(&self) -> Result<Retiring, String> {
        self.session.borrow_mut().flush();
        if self.native_history() && self.session.borrow().thread_id.is_some() && !self.save() {
            return Err(UNSAVED.into());
        }
        let path = self.snapshot_path();
        let mut records = self.records.borrow_mut();
        let mut session = self.session.borrow_mut();
        records.archived_for_close = false;
        Ok(Retiring {
            id: std::mem::replace(&mut session.record_id, uuid::Uuid::new_v4().to_string().to_uppercase()),
            path,
            thread: session.thread_id.take(),
            history_path: session.native_history_path.take(),
            sources: std::mem::take(&mut session.native_sources),
            leases: std::mem::take(&mut records.leases),
            client_versions: std::mem::take(&mut session.archive_client_versions),
            lock: records.lock.take(),
            group: records.group,
        })
    }

    /// The Swift `rollbackRecordTransition`: the record set aside is the window's again.
    pub(in crate::backend) fn rollback(&self, previous: Retiring) {
        let mut records = self.records.borrow_mut();
        let mut session = self.session.borrow_mut();
        records.lock = previous.lock;
        records.leases = previous.leases;
        session.record_id = previous.id;
        session.native_sources = previous.sources;
        session.thread_id = previous.thread;
        session.native_history_path = previous.history_path;
        session.archive_client_versions = previous.client_versions;
    }

    /// The Swift `discardRetiringRecord`: a window closed mid-switch lets the record go once its agent has stopped.
    pub(in crate::backend) fn discard(&self, previous: Retiring) {
        tokio::task::spawn_local(async move {
            let _ = wait_for_exit(previous.group).await;
            drop((previous.lock, previous.leases));
        });
    }

    /// The Swift `archiveRetired`: the record left behind goes to the archive once its agent has stopped.
    pub(in crate::backend) async fn archive_retired(&self, previous: Retiring) {
        let Retiring { path, thread, sources, mut leases, group, lock, .. } = previous;
        if !self.native_history() || thread.is_none() {
            return drop(lock);
        }
        let archived = async {
            for source in &sources {
                if !leases.contains_key(&source.key()) {
                    self.config.native.allows(Path::new(&source.home))?;
                    leases.insert(source.key(), records::lease(&self.config.native.locks, source)?);
                }
            }
            wait_for_exit(group).await?;
            let owned: Vec<NativeSource> = sources.iter().filter(|source| leases.contains_key(&source.key())).cloned().collect();
            let state = self.state_path();
            self.archive(&state).archive(&path, &sources, &owned).await
        };
        if let Err(error) = archived.await {
            self.session.borrow_mut().notice(&format!("{ARCHIVE_UNFINISHED}{error}"));
        }
        drop((lock, leases));
    }

    /// The Swift `restore`: the saved record `id` is claimed and opened on its own thread and profile; on any
    /// failure the window keeps the record, lock and leases it had.
    pub(in crate::backend) async fn restore(self: &Rc<Self>, id: &str, requested: Option<NativeSource>, reason: Option<&str>) -> Result<(), String> {
        self.check_open()?;
        if !records::is_uuid(id) {
            return Err("Invalid saved conversation ID.".into());
        }
        let state = self.state_path();
        let claimed = if self.holds_record(id) {
            None
        } else {
            self.config.native.allows(&state)?;
            Some(records::claim_record(&state, id)?)
        };
        let (record, sources) = {
            let session = self.session.borrow();
            (session.record_id.clone(), session.native_sources.clone())
        };
        let leased: HashSet<String> = self.records.borrow().leases.keys().cloned().collect();
        let previous_lock: Option<Option<(String, File)>> = claimed.map(|file| self.records.borrow_mut().lock.replace((id.to_owned(), file)));
        self.records.borrow_mut().suppress_save = true;
        let result = self.restore_record(id, requested, reason).await;
        self.records.borrow_mut().suppress_save = false;
        match result {
            Ok(()) => {
                drop(previous_lock);
                self.save();
                Ok(())
            }
            Err(error) => {
                if !self.closed.get() {
                    let mut records = self.records.borrow_mut();
                    if let Some(previous) = previous_lock {
                        records.lock = previous;
                    }
                    records.leases.retain(|key, _| leased.contains(key));
                    let mut session = self.session.borrow_mut();
                    (session.record_id, session.native_sources) = (record, sources);
                }
                Err(error)
            }
        }
    }

    async fn restore_record(self: &Rc<Self>, id: &str, requested: Option<NativeSource>, reason: Option<&str>) -> Result<(), String> {
        let state = self.state_path();
        let archived = self.archive(&state).record(id).await?;
        self.check_open()?;
        let saved = records::newest_record_file(&state, id).and_then(|path| records::read_object(&path)).or_else(|| archived.clone()).ok_or(GONE)?;
        let mut sources = NativeSource::list(saved.get("nativeSources"));
        if let (Some(thread), Some(provider)) = (text(&saved, "threadId"), self.saved_provider(&saved)) {
            let latest = self.native_source(thread, &self.stored_account(&saved, &provider), text(&saved, "nativeHistoryPath").map(str::to_owned), false);
            if !sources.iter().any(|source| source.provider == latest.provider && source.thread_id == latest.thread_id) {
                sources.push(latest);
            }
        }
        let archived_sources = NativeSource::list(archived.as_ref().and_then(|record| record.get("nativeSources")));
        self.session.borrow_mut().native_sources = sources.clone();
        for source in sources.iter().chain(&archived_sources) {
            self.lease_source(source)?;
        }
        self.session.borrow_mut().record_id = id.to_owned();
        self.archive(&state).restore(id, false).await?;
        self.check_open()?;
        let path = records::newest_record_file(&state, id).ok_or(GONE)?;
        let record = records::read_object(&path).filter(|record| text(record, "accountId").is_some() && text(record, "threadId").is_some()).ok_or("The saved conversation is invalid.")?;
        self.adopt_choices(&record);
        let resumed = self.resumed(&record, requested)?;
        if self.native_history() && !resumed.source.pending_creation && resumed.source.provider != "qwen" {
            // Watcher reopens closed sessions, whose Claude transcripts chats.py deletes once chats.sqlite holds them.
            if resumed.source.provider == "claude" {
                self.restore_claude_transcript(&resumed.source.thread_id).await;
            }
            if self.archive(&state).source_files(std::slice::from_ref(&resumed.source)).await?.is_empty() {
                return Err("The exact saved native history is unavailable.".into());
            }
            self.check_open()?;
        }
        self.reopen(id, &path, &record, resumed, reason).await
    }

    fn adopt_choices(&self, record: &Object) {
        for (key, choice) in [("providerChoice", &self.provider_choice), ("accountChoice", &self.account_choice), ("modeChoice", &self.mode_choice)] {
            if let Some(value) = text(record, key) {
                *choice.borrow_mut() = Some(value.to_owned());
            }
        }
    }

    /// The source the record resumes and the one enabled profile that holds it.
    fn resumed(&self, record: &Object, requested: Option<NativeSource>) -> Result<Resumed, String> {
        let provider = self.saved_provider(record);
        let raw = text(record, "threadId").and_then(|thread| thread.rsplit(':').next()).map(str::to_lowercase);
        let is_latest = |source: &NativeSource| Some(&source.provider) == provider.as_ref() && Some(source.thread_id.to_lowercase()) == raw;
        let source = requested.or_else(|| self.session.borrow().native_sources.iter().rev().find(|source| is_latest(source)).cloned()).ok_or("The saved native source is unavailable.")?;
        let latest = is_latest(&source);
        let saved = source.account_id.clone().or_else(|| latest.then(|| text(record, "accountId").map(str::to_owned)).flatten());
        let profiles: Vec<Account> = self.restorable_accounts().into_iter().filter(|account| account.provider == source.provider && account.enabled).collect();
        let selected = match saved {
            Some(saved) => profiles.into_iter().find(|account| account.id == saved),
            None => {
                let exact: Vec<Account> = profiles.into_iter().filter(|account| self.native_source(&source.thread_id, account, None, false).home == source.home).collect();
                if let [only] = exact.as_slice() { Some(only.clone()) } else { None }
            }
        };
        let mut account = selected.ok_or("The saved account is unavailable. Enable its exact profile before resuming this conversation.")?;
        if NAMESPACED_HOMES.contains(&account.provider.as_str()) {
            account.home = Some(source.home.clone());
        }
        Ok(Resumed { source, account, latest })
    }

    /// The end of the Swift `restore`: the profile opens the thread in the record's folder, then the record's
    /// transcript, settings and draft come back.
    async fn reopen(self: &Rc<Self>, id: &str, path: &Path, record: &Object, resumed: Resumed, reason: Option<&str>) -> Result<(), String> {
        let resume = (!resumed.source.pending_creation).then(|| resumed.source.native_thread());
        *self.provider_choice.borrow_mut() = Some(resumed.account.provider.clone());
        *self.account_choice.borrow_mut() = Some(resumed.account.id.clone());
        let generation = self.session.borrow().draft_generation;
        let previous = {
            let mut session = self.session.borrow_mut();
            let previous = (session.cwd.clone(), session.conversation_directory.clone());
            let own = records::native_directory(Path::new(&session.state_directory), &session.conversation_directory);
            if path.parent() != Some(own.as_path()) {
                if let Some(home) = text(record, "cwd") {
                    session.conversation_directory = home.to_owned();
                }
            }
            let restored = text(record, "workingDirectory").or_else(|| text(record, "cwd")).unwrap_or(&session.conversation_directory).to_owned();
            session.cwd = working_directory(&restored, &session.conversation_directory).unwrap_or_else(|| session.conversation_directory.clone());
            previous
        };
        if let Err(error) = self.activate_rows(&resumed.account, resume.clone(), None, true).await {
            let mut session = self.session.borrow_mut();
            (session.cwd, session.conversation_directory) = previous;
            self.records.borrow_mut().pending_restore = Some(id.to_owned());
            return Err(error);
        }
        self.records.borrow_mut().pending_restore = None;
        self.restored(id, record, &resumed, resume, generation, reason);
        Ok(())
    }

    /// The record's transcript, settings, draft and context, once its thread is open again.
    fn restored(&self, id: &str, record: &Object, resumed: &Resumed, resume: Option<String>, generation: i64, reason: Option<&str>) {
        let Resumed { source, account, latest } = resumed;
        let latest = *latest;
        let _ = std::fs::write(&self.session.borrow().fleet_context_file, text(record, "fleetContext").unwrap_or_default());
        self.records.borrow_mut().archived_for_close = false;
        let mut session = self.session.borrow_mut();
        session.effort = if latest { text(record, "effort").map(str::to_owned) } else { None };
        session.planning = latest && account.provider == "codex" && record.get("planning") == Some(&Value::Bool(true));
        session.conversation_name = text(record, "conversationName").map(str::to_owned);
        session.needs_attention = record.get("needsAttention").and_then(Value::as_bool).unwrap_or(false);
        if session.needs_attention {
            session.status = "Needs attention".into();
        }
        session.record_id = id.to_owned();
        session.load_rows(record.get("rows").and_then(Value::as_array).map_or(&[][..], Vec::as_slice));
        drop(session);
        self.restore_draft((record.get("draft").and_then(Value::as_array).cloned().unwrap_or_default(), generation));
        let mut session = self.session.borrow_mut();
        let saved_context = text(record, "injectedContext").unwrap_or_default();
        session.injected_context = if source.pending_creation && !saved_context.is_empty() {
            saved_context.to_owned()
        } else if account.provider == "qwen" || resume.is_none() {
            fallback::handoff_context(&session)
        } else {
            String::new()
        };
        if let Some(reason) = reason {
            let switched = text(record, "accountId") != Some(account.id.as_str());
            let kept = if !session.injected_context.is_empty() { " Recent messages are passed to it as context." } else if resume.is_some() { " Context kept." } else { "" };
            let message = format!("{} {}: {reason}.{kept}", if switched { "Connected to" } else { "Reconnected to" }, session.provider_label);
            session.notice(&message);
        }
    }

    /// `/fork`: Codex copies the thread, and the window moves to the copy under a new record.
    pub(in crate::backend) async fn fork(self: &Rc<Self>) -> Result<(), String> {
        self.idle()?;
        let (ready, codex, thread, planning, name) = {
            let session = self.session.borrow();
            (session.ready, session.provider == "codex", session.thread_id.clone().unwrap_or_default(), session.planning, session.conversation_name.clone())
        };
        if !ready || !codex {
            return Err(FORK_CODEX_ONLY.into());
        }
        let result = self.request("thread/fork", json!({"threadId": thread, "excludeTurns": true}), REQUEST_TIMEOUT).await?;
        let id = result["thread"]["id"].as_str().ok_or(NO_FORK)?.to_owned();
        if self.switch_thread(Some(&id), true).await {
            let mut session = self.session.borrow_mut();
            (session.planning, session.conversation_name) = (planning, name);
            drop(session);
            self.save();
        }
        Ok(())
    }
}

/// The Swift `workingDirectory(_:within:)`: `target` when it is an existing folder inside `initial`.
fn working_directory(target: &str, initial: &str) -> Option<String> {
    if !target.starts_with('/') {
        return None;
    }
    let path = records::standardized(Path::new(target)).to_string_lossy().into_owned();
    let inside = initial == "/" || path == initial || path.starts_with(&format!("{initial}/"));
    (inside && Path::new(&path).is_dir()).then_some(path)
}
