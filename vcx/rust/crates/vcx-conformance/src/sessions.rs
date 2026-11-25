//! Sessions and the lease: who may write to a session, and what survives a frontend.

use crate::Target;
use crate::peer::{Held, Peer, QUIET, WAIT, fault, prompt, request_for};
use serde_json::Value;
use std::time::Instant;
use vcx_proto::{AttachRequest, Event};
use vcx_testkit::session_id;

pub fn attach_refuses_an_id_that_is_no_uuid(target: &Target) {
    let peer = Peer::greeted(target);

    let refused = peer.client.attach(&request_for(target, "not-a-uuid"));

    assert_eq!(fault(refused), "invalidAttach");
    assert!(peer.client.list().unwrap().is_empty(), "a refused attach creates no session");
}

pub fn attach_refuses_a_relative_or_missing_folder(target: &Target) {
    let peer = Peer::greeted(target);
    let missing = target.directory.join("no-such-folder");
    let in_folder = |cwd: &str| AttachRequest { session_id: session_id(), cwd: cwd.to_owned(), ..AttachRequest::default() };

    let relative = peer.client.attach(&in_folder("relative/folder"));
    let absent = peer.client.attach(&in_folder(missing.to_str().unwrap()));

    assert_eq!(fault(relative), "invalidAttach");
    assert_eq!(fault(absent), "invalidAttach");
}

pub fn attach_existing_only_refuses_an_unknown_session(target: &Target) {
    let peer = Peer::greeted(target);
    let request = AttachRequest { existing_only: true, ..request_for(target, &session_id()) };

    let refused = peer.client.attach(&request);

    assert_eq!(fault(refused), "unknownSession");
    assert!(peer.client.list().unwrap().is_empty(), "a refused attach creates no session");
}

pub fn attach_gives_a_lease_and_the_state(target: &Target) {
    let id = session_id();

    let held = Held::attach(Peer::greeted(target), &request_for(target, &id.to_lowercase()));

    assert_eq!(held.id(), id, "the session id comes back in upper case, whatever case asked for it");
    assert!(!held.attachment.lease.is_empty());
    assert_eq!(held.attachment.last_sequence, 0);
    assert!(held.attachment.state.get("rows").is_some_and(Value::is_array), "{:?}", held.attachment.state.keys().collect::<Vec<_>>());
}

pub fn list_tells_each_session_and_whether_a_frontend_holds_it(target: &Target) {
    let mut held = Held::open(target);
    held.turn("listed");
    let id = held.id().to_owned();

    let attached = held.peer.listed(&id).unwrap();
    held.lease.clone().detach(&held.peer.client).unwrap();
    let detached = held.peer.listed(&id).unwrap();

    assert_eq!((&attached["attached"], &attached["ended"], &attached["lastSequence"]), (&Value::Bool(true), &Value::Bool(false), &Value::from(1)));
    assert_eq!(attached["revision"], held.replica.revision(), "list tells the revision of the last update");
    assert_eq!((&detached["attached"], &detached["ended"]), (&Value::Bool(false), &Value::Bool(false)));
    assert_eq!(held.peer.client.list().unwrap().len(), 1);
}

pub fn a_second_attach_takes_the_lease_from_the_first(target: &Target) {
    let first = Held::open(target);
    let request = AttachRequest { existing_only: true, ..request_for(target, first.id()) };

    let mut second = Held::attach(Peer::greeted(target), &request);
    let told = first.peer.drain();
    let refused = first.peer.perform(&first.lease, 1, "send", prompt("from the first"));
    second.turn("from the second");

    assert!(told.contains(&Event::LeaseLost { session_id: first.id().to_owned() }), "the first frontend is told: {told:?}");
    assert_ne!(first.attachment.lease, second.attachment.lease);
    assert_eq!(fault(refused), "staleLease");
    assert_eq!(second.kinds(), ["user", "activity", "assistant"]);
}

pub fn detach_gives_up_the_lease(target: &Target) {
    let held = Held::open(target);

    held.lease.clone().detach(&held.peer.client).unwrap();
    let refused = held.peer.perform(&held.lease, 1, "send", prompt("after detach"));
    let again = held.lease.clone().detach(&held.peer.client);

    assert_eq!(fault(refused), "staleLease");
    assert_eq!(fault(again), "staleLease");
}

pub fn a_session_outlives_its_frontend_connection(target: &Target) {
    let mut first = Held::open(target);
    first.turn("before the frontend left");
    let (id, revision) = (first.id().to_owned(), first.replica.revision());
    drop(first);
    let peer = Peer::greeted(target);
    let deadline = Instant::now() + WAIT;
    while peer.listed(&id).unwrap()["attached"] == true {
        assert!(Instant::now() < deadline, "the worker never noticed the closed connection");
        std::thread::sleep(QUIET);
    }

    let second = Held::attach(peer, &AttachRequest { existing_only: true, ..request_for(target, &id) });

    assert_eq!(second.kinds(), ["user", "activity", "assistant"]);
    assert_eq!((second.attachment.revision, second.attachment.last_sequence), (revision, 1));
}
