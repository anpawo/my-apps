//! The `/resume` list and the saved record a name resolves to, ported from the Swift `refreshCatalog`,
//! `nativeRecent` and `savedRecord`.

use super::{NATIVE_PREFIX, REFRESH_FAILED, Target};
use crate::backend::{REQUEST_TIMEOUT, SessionBackend, text};
use crate::records::{self, NativeSource};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const UNTITLED: &str = "Untitled conversation";
const AMBIGUOUS_SOURCE: &str = "More than one saved source uses this native ID. Choose its saved conversation and profile instead.";

/// A record `/resume` may list: a snapshot on disk, or an archived one with its summary.
struct Candidate {
    id: String,
    date: SystemTime,
    path: Option<std::path::PathBuf>,
    summary: Option<Value>,
}

impl SessionBackend {
    fn is_open(&self, id: &str) -> bool {
        self.holds_record(id) || records::is_open(&self.state_path(), id)
    }

    /// The Swift `refreshCatalog`'s list: saved records not open in a window, then the agent's threads not saved.
    pub(in crate::backend) async fn refresh_recent(&self) {
        let cwd = self.session.borrow().cwd.clone();
        let page = match self.request("thread/list", json!({"cwd": cwd, "limit": records::RECENT_LIMIT, "sortKey": "updated_at"}), REQUEST_TIMEOUT).await {
            Ok(page) => page,
            Err(error) => return self.session.borrow_mut().notice(&format!("{REFRESH_FAILED}{error}")),
        };
        let external: Vec<Value> = page["data"].as_array().into_iter().flatten().filter_map(|thread| {
            let title = thread["name"].as_str().or(thread["preview"].as_str()).unwrap_or(UNTITLED);
            Some(json!({"id": thread["id"].as_str()?, "title": title, "backendID": null}))
        }).collect();
        let local = if self.native_history() {
            let state = self.state_path();
            match self.archive(&state).records().await {
                Ok(entries) => self.records.borrow_mut().archived_recent = entries,
                Err(error) => return self.session.borrow_mut().notice(&format!("{REFRESH_FAILED}{error}")),
            }
            self.native_recent()
        } else {
            Vec::new()
        };
        if self.closed.get() {
            return;
        }
        let saved: HashSet<&str> = local.iter().filter_map(|recent| recent["backendID"].as_str()).collect();
        let listed = local.iter().filter(|recent| !self.is_open(recent["id"].as_str().unwrap_or_default().trim_start_matches(NATIVE_PREFIX)));
        let recent = listed.cloned().chain(external.iter().filter(|thread| !thread["id"].as_str().is_some_and(|id| saved.contains(id))).cloned()).collect();
        self.session.borrow_mut().recent = recent;
    }

    fn candidates(&self) -> Vec<Candidate> {
        let mut candidates: Vec<Candidate> = records::snapshot_files(&self.state_path()).into_iter().map(|(id, date, path)| Candidate { id, date, path: Some(path), summary: None }).collect();
        for entry in &self.records.borrow().archived_recent {
            let Some(id) = entry["id"].as_str() else { continue };
            let millis = entry["updated_at"].as_f64().unwrap_or(0.0).max(0.0);
            candidates.push(Candidate { id: id.to_owned(), date: UNIX_EPOCH + Duration::from_secs_f64(millis / 1000.0), path: None, summary: entry.get("summary").cloned() });
        }
        candidates.sort_by(|left, right| right.date.cmp(&left.date));
        candidates
    }

    /// The Swift `nativeRecent`: the newest saved records with rows, titled by their Fleet label and last answer.
    fn native_recent(&self) -> Vec<Value> {
        let mut result = Vec::new();
        let mut seen = HashSet::new();
        for candidate in self.candidates() {
            if seen.contains(&candidate.id) {
                continue;
            }
            let record = candidate.path.as_deref().and_then(records::read_object).unwrap_or_default();
            let summary = candidate.summary.or_else(|| record.get("recentSummary").cloned()).unwrap_or(Value::Null);
            let rows = record.get("rows").and_then(Value::as_array).cloned().unwrap_or_default();
            if !summary["hasRows"].as_bool().unwrap_or(!rows.is_empty()) {
                continue;
            }
            let answer = summary["title"].as_str().map(str::to_owned).or_else(|| records::last_answer(&rows)).or_else(|| text(&record, "title").map(str::to_owned)).unwrap_or_else(|| records::NEW_CONVERSATION.to_owned());
            let label = summary["fleetContext"].as_str().or_else(|| text(&record, "fleetContext")).unwrap_or_default().trim().to_owned();
            let title = if label.is_empty() { answer } else { format!("{label}: {answer}") };
            let thread = summary["threadId"].as_str().or_else(|| text(&record, "threadId"));
            result.push(json!({"id": format!("{NATIVE_PREFIX}{}", candidate.id), "title": title, "backendID": thread}));
            seen.insert(candidate.id);
            if result.len() == records::RECENT_LIMIT {
                break;
            }
        }
        result
    }

    /// The Swift `savedRecord`: `native:<id>`, `last`, an archived alias, a snapshot's id, or a native thread a
    /// single snapshot owns. A worker without native history keeps none.
    pub(in crate::backend) async fn saved_record(&self, value: &str) -> Result<Option<Target>, String> {
        if !self.native_history() {
            return Ok(None);
        }
        let raw = value.strip_prefix(NATIVE_PREFIX).unwrap_or(value);
        let state = self.state_path();
        let archive = self.archive(&state);
        let named = |id: &str| records::is_uuid(id).then(|| (id.to_uppercase(), None));
        if raw == "last" {
            let directory = self.session.borrow().conversation_directory.clone();
            let pointer = records::read_object(&records::native_pointer(&state, &directory));
            if let Some(id) = pointer.as_ref().and_then(|pointer| text(pointer, "recordId")) {
                return Ok(archive.resolve(id).await?.or_else(|| named(id)));
            }
        }
        if let Some(target) = archive.resolve(raw).await? {
            return Ok(Some(target));
        }
        if value.starts_with(NATIVE_PREFIX) {
            return Ok(named(raw));
        }
        if let Some(target) = named(raw).filter(|(id, _)| records::newest_record_file(&state, id).is_some()) {
            return Ok(Some(target));
        }
        self.snapshot_owning(raw)
    }

    /// The snapshot whose sources hold the native thread `raw` (`<provider>:<thread>` or a bare thread).
    fn snapshot_owning(&self, raw: &str) -> Result<Option<Target>, String> {
        let parts: Vec<&str> = raw.split(':').collect();
        let native = parts.last().map(|part| part.to_lowercase());
        let provider = (parts.len() > 1).then(|| parts[0]);
        let mut matches: Vec<(String, NativeSource)> = Vec::new();
        for (id, _, path) in records::snapshot_files(&self.state_path()) {
            let Some(record) = records::read_object(&path) else { continue };
            for source in self.record_sources(&record) {
                let owned = Some(source.thread_id.to_lowercase()) == native && provider.is_none_or(|provider| provider == source.provider);
                if owned && !matches.iter().any(|(known, kept)| *known == id && kept.key() == source.key()) {
                    matches.push((id.clone(), source));
                }
            }
        }
        if matches.len() > 1 {
            return Err(AMBIGUOUS_SOURCE.into());
        }
        Ok(matches.pop().map(|(id, source)| (id, Some(source))))
    }
}
