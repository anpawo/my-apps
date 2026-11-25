//! Before any session: `hello`, and what a worker does with requests it cannot take.

use crate::Target;
use crate::peer::{Peer, fault, request_for};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::time::Duration;
use vcx_proto::channel;
use vcx_testkit::session_id;

const CLOSE_WAIT: Duration = Duration::from_secs(5);

pub fn hello_names_protocol_one_and_the_worker_process(target: &Target) {
    let peer = Peer::connect(target);

    let reply = peer.request("hello", json!({"protocol": 1})).unwrap();

    assert_eq!(reply["protocol"], 1);
    assert_eq!(reply["pid"], target.pid);
    for key in ["build", "instanceID"] {
        assert!(reply[key].as_str().is_some_and(|text| !text.is_empty()), "{key} is a non-empty text: {reply:?}");
    }
    for key in ["maximumFrameBytes", "maximumBufferedBytes", "maximumQueuedFrames"] {
        assert!(reply[key].as_u64().is_some_and(|limit| limit > 0), "{key} is a positive limit: {reply:?}");
    }
}

pub fn hello_refuses_another_protocol(target: &Target) {
    let peer = Peer::connect(target);

    let refused = peer.request("hello", json!({"protocol": 2}));
    let after = peer.request("list", json!({}));

    assert_eq!(fault(refused), "protocolMismatch");
    assert_eq!(fault(after), "handshakeRequired", "a refused hello opens nothing");
}

pub fn session_requests_wait_for_hello(target: &Target) {
    let peer = Peer::connect(target);

    let list = peer.request("list", json!({}));
    let attach = peer.client.attach(&request_for(target, &session_id()));

    assert_eq!(fault(list), "handshakeRequired");
    assert_eq!(fault(attach), "handshakeRequired");
}

pub fn an_unknown_method_is_refused(target: &Target) {
    let peer = Peer::greeted(target);

    let refused = peer.request("session/rename", json!({}));
    let after = peer.request("list", json!({}));

    assert_eq!(fault(refused), "unknownMethod");
    assert!(after.is_ok(), "the connection stays usable: {after:?}");
}

pub fn a_request_without_an_id_closes_the_connection(target: &Target) {
    let mut stream = channel::connect(&target.socket).unwrap();
    stream.set_read_timeout(Some(CLOSE_WAIT)).unwrap();
    let request: Value = json!({"method": "hello", "params": {"protocol": 1}});

    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    let read = stream.read(&mut [0; 64]);

    assert!(matches!(read, Ok(0)), "the worker closes without a reply: {read:?}");
}
