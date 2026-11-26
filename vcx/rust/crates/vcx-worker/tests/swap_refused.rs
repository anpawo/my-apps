//! A live update the next image refuses (`src/swap.rs`): the worker asks it first, and goes on in its own image
//! with its agents, its sessions and its frontends. A file of its own: the image to swap to is named by this
//! process's environment, which the workers of other tests must not inherit.

use serde_json::{Value, json};
use std::path::Path;
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, Peer, prompt};
use vcx_model::SessionState;
use vcx_testkit::RustWorker;

const NUMBERS: u32 = 150;
const ANSWER: &str = "swap-answer";
const UNDER_WAY: &str = " 10 ";
/// An image that answers no to anything.
const REFUSING_IMAGE: &str = "/usr/bin/false";

fn answer(state: &SessionState) -> &str {
    state.items.get(ANSWER).and_then(|item| item.get("text")).and_then(Value::as_str).unwrap_or_default()
}

#[test]
fn an_update_the_next_image_refuses_leaves_the_worker_as_it_was() {
    // SAFETY: the only test of this binary, so no other thread reads the environment meanwhile.
    unsafe { std::env::set_var("VCX_RUNTIME_SWAP_EXECUTABLE", REFUSING_IMAGE) };
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/swap_agent.py");
    let command = ["/usr/bin/python3".to_owned(), "-I".to_owned(), agent.to_string_lossy().into_owned()];
    let worker = RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), "refused", "codex", &command, &json!({}));
    let target = Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() };
    let before = Peer::connect(&target).client.hello().unwrap();
    let mut held = Held::open(&target);
    held.lease.perform(&held.peer.client, "send", prompt("count")).unwrap();
    held.follow(|state| answer(state).contains(UNDER_WAY));
    let agent = answer(held.replica.state().unwrap()).split(':').next().unwrap().to_owned();

    unsafe { libc::kill(before.pid as libc::pid_t, libc::SIGUSR1) };
    // The same connection all along: a refused update does not even close it.
    held.follow(|state| state.meta.get("busy") == Some(&Value::Bool(false)));

    let whole = (1..=NUMBERS).fold(format!("{agent}:"), |text, number| format!("{text}{number} "));
    assert_eq!(answer(held.replica.state().unwrap()), whole);
    assert_eq!(Peer::connect(&target).client.hello().unwrap(), before, "the worker is still its first image");
    assert!(!worker.socket.with_extension("sock.swap.json").exists(), "the manifest of the refused update is removed");
    held.lease.perform(&held.peer.client, "stop", json!({})).expect("the session goes on taking actions");
}
