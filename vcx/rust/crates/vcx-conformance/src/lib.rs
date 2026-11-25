//! Protocol v1 as a runtime worker must speak it. Each case takes a freshly started worker whose agent is the fixture
//! (`fixtures/fake_agent.py`) and panics on the first behaviour that differs from the Swift worker's
//! (`Sources/VCX/RuntimeServer.swift`). A worker passes when `suite!` is green against it.

pub mod actions;
pub mod handshake;
pub mod held;
pub mod peer;
pub mod sessions;
pub mod turns;

use std::path::PathBuf;
use vcx_testkit::SwiftWorker;

/// A running worker under test.
pub struct Target {
    pub socket: PathBuf,
    /// An existing folder sessions may use as their working directory.
    pub directory: PathBuf,
    pub pid: i64,
}

impl Target {
    pub fn of(worker: &SwiftWorker) -> Self {
        Self { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
    }
}

/// One test per case. `$start` takes a short unique name and gives a value that keeps the worker alive,
/// `$target` turns a reference to it into a `Target`.
#[macro_export]
macro_rules! suite {
    ($start:path, $target:path) => {
        $crate::suite!(@each $start, $target;
            handshake::hello_names_protocol_one_and_the_worker_process,
            handshake::hello_refuses_another_protocol,
            handshake::session_requests_wait_for_hello,
            handshake::an_unknown_method_is_refused,
            handshake::a_request_without_an_id_closes_the_connection,
            sessions::attach_refuses_an_id_that_is_no_uuid,
            sessions::attach_refuses_a_relative_or_missing_folder,
            sessions::attach_existing_only_refuses_an_unknown_session,
            sessions::attach_gives_a_lease_and_the_state,
            sessions::list_tells_each_session_and_whether_a_frontend_holds_it,
            sessions::a_second_attach_takes_the_lease_from_the_first,
            sessions::detach_gives_up_the_lease,
            sessions::a_session_outlives_its_frontend_connection,
            actions::a_sequence_gap_is_refused_and_spends_nothing,
            actions::a_malformed_action_is_refused,
            actions::a_replayed_sequence_returns_its_receipt_without_running_again,
            actions::a_sequence_reused_for_another_action_is_refused,
            actions::a_failed_action_spends_its_sequence,
            actions::close_ends_the_session_for_good,
            turns::a_turn_streams_one_revision_at_a_time_to_its_answer,
            turns::only_the_lease_holder_receives_updates,
            held::stop_ends_a_turn_the_agent_holds_open,
            held::an_accepted_approval_lets_the_held_turn_finish,
            held::a_declined_approval_ends_the_turn_without_running_it,
            held::a_turn_stays_open_when_its_frontend_leaves,
            held::the_worker_leaves_once_its_last_session_is_closed,
        );
    };
    (@each $start:path, $target:path; $($module:ident :: $case:ident),* $(,)?) => {
        static STARTED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        $(
            #[test]
            fn $case() {
                // Tests share a process, and a socket path is short: a counter names each worker's folder.
                let name = format!("c{}", STARTED.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
                let worker = $start(&name);
                $crate::$module::$case(&$target(&worker));
            }
        )*
    };
}
