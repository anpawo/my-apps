//! Closing a window, ported from the Swift `prepareForClose`, `archiveForClose`, `close` and
//! `recoverIncompleteArchive`: the record is saved, its agent stopped, then the record and its native history are
//! sealed into the archive; an archive cut short is put back before the window opens anything else.

use super::{CHANGING, wait_for_exit};
use crate::backend::SessionBackend;
use crate::records::NativeSource;

const UNSAVED: &str = "Could not save the current conversation before archiving. Native history has been kept.";
const RECOVERING: &str = "The previous archive is still being recovered.";

impl SessionBackend {
    /// The Swift `prepareForClose`: a window closes only between changes, its record saved first.
    pub(in crate::backend) fn prepare_for_close(&self) -> Result<(), String> {
        let moving = {
            let records = self.records.borrow();
            records.archiving || records.switching || records.recovering
        };
        if self.closed.get() || moving || self.session.borrow().changing || self.loading.get() || self.transferring.get() {
            return Err(CHANGING.into());
        }
        if self.records.borrow().archived_for_close || !self.native_history() || self.session.borrow().thread_id.is_none() {
            return Ok(());
        }
        self.session.borrow_mut().flush();
        if self.save() { Ok(()) } else { Err(UNSAVED.into()) }
    }

    /// The Swift `archiveForClose`: once its agent has stopped, the record goes to the archive. One cut short is
    /// recovered before this window opens another.
    pub(in crate::backend) async fn archive_for_close(&self) -> Result<(), String> {
        if self.records.borrow().archived_for_close {
            return Ok(());
        }
        self.prepare_for_close()?;
        if !self.native_history() || self.session.borrow().thread_id.is_none() {
            return Ok(());
        }
        self.records.borrow_mut().archiving = true;
        let result = self.archive_current().await;
        let mut records = self.records.borrow_mut();
        records.archiving = false;
        if !records.archived_for_close {
            records.recovery_needed = true;
        }
        result
    }

    async fn archive_current(&self) -> Result<(), String> {
        let sources = self.session.borrow().native_sources.clone();
        for source in &sources {
            self.lease_source(source)?;
        }
        // The agent's exit is this close's doing: its pump must not take it for a crash and restart it.
        self.generation.set(self.generation.get() + 1);
        if let Some(agent) = self.agent.borrow_mut().take() {
            agent.close();
        }
        let group = self.records.borrow().group;
        wait_for_exit(group).await?;
        self.session.borrow_mut().ready = false;
        let owned: Vec<NativeSource> = sources.iter().filter(|source| self.records.borrow().leases.contains_key(&source.key())).cloned().collect();
        let (state, path, versions) = (self.state_path(), self.snapshot_path(), self.session.borrow().archive_client_versions.clone());
        self.archive(&state).archive(&path, &sources, &owned, &versions).await?;
        self.records.borrow_mut().archived_for_close = true;
        let mut session = self.session.borrow_mut();
        session.busy = false;
        session.turn_id = None;
        Ok(())
    }

    /// The Swift `close`'s part: the record is saved and let go, and its leases once its agent has stopped.
    pub(in crate::backend) fn release_records(&self) {
        self.session.borrow_mut().flush();
        self.save();
        let (lock, leases, group) = {
            let mut records = self.records.borrow_mut();
            (records.lock.take(), std::mem::take(&mut records.leases), records.group)
        };
        drop(lock);
        if !leases.is_empty() {
            tokio::task::spawn_local(async move {
                let _ = wait_for_exit(group).await;
                drop(leases);
            });
        }
    }

    /// The Swift `recoverIncompleteArchive`: an archive cut short puts the record and its history back.
    pub(in crate::backend) async fn recover_incomplete_archive(&self) -> Result<(), String> {
        let (needed, recovering) = {
            let records = self.records.borrow();
            (records.recovery_needed, records.recovering)
        };
        if !needed {
            return Ok(());
        }
        if recovering || self.closed.get() {
            return Err(RECOVERING.into());
        }
        self.records.borrow_mut().recovering = true;
        let recovered = async {
            let sources = self.session.borrow().native_sources.clone();
            for source in &sources {
                self.lease_source(source)?;
            }
            let (state, id) = (self.state_path(), self.session.borrow().record_id.clone());
            self.archive(&state).restore(&id, true).await?;
            self.check_open()
        };
        let result = recovered.await;
        let mut records = self.records.borrow_mut();
        records.recovering = false;
        if result.is_ok() {
            records.recovery_needed = false;
        }
        result
    }
}
