fn main() {
    std::process::exit(vcx_worker::run(std::env::args().skip(1).collect()));
}
