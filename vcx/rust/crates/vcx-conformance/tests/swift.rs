//! The suite against the Swift worker (`VCX --runtime-worker`), the reference. It fails without a Swift binary: a
//! reference run that skipped proves nothing.

use vcx_conformance::Target;
use vcx_testkit::SwiftWorker;

fn start(name: &str) -> SwiftWorker {
    SwiftWorker::start(name).expect("no Swift VCX binary: install the app or set VCX_SWIFT_BINARY")
}

vcx_conformance::suite!(start, Target::of);
