//! The protocol v1 suite, the one the Swift worker passes, run against this worker.

use std::path::Path;
use vcx_conformance::Target;
use vcx_testkit::RustWorker;

fn start(name: &str) -> RustWorker {
    RustWorker::start(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name)
}

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

vcx_conformance::suite!(start, target);
