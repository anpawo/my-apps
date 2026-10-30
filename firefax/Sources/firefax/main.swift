import Foundation

// Live wiring and the command line. --selftest, --help and --version never touch AX. scan/fill build
// a LivePage against his Firefox; store/refs use the real keychain (com.mr.firefax). The engine does
// the rest. This file is never run against his Firefox in the build; only --selftest/--help/--version.

let help = """
firefax: fill one web-form page in your logged-in Firefox, in one call, through macOS Accessibility.

  firefax scan [host/path]        list the page's controls as ready locators (never their values)
  firefax fill <file|->           fill the page from a JSON spec on that file or stdin
  firefax store <name>            read a value from stdin into keychain com.mr.firefax (prints name + length)
  firefax refs                    list the stored ref names and their lengths
  firefax --selftest              run the checks against the in-memory FakeAX (no window, no keychain)
  firefax --help | --version

fill flags:
  --dry-run                       resolve every locator live, write nothing
  --human                         type literal values as keys at a human cadence (slower, off by default)
  --final '<label>'               allow one committing button or attestation box (repeatable)
  --timing                        per-step ms to stderr

spec:
  {"page":"host/path", "steps":[ <step>, ... ]}
  a step is one locator and one action.
  locator:  "id" | "label" | "placeholder" | "after"   (+ "nth" for a tie)
  action:   "set" <value> | "split" <value> (+ "prefix") | "pick" <option> (+ "type") |
            "select" <option> | "check" true|false | "press" true
  value:    "literal" | {"ref":"name"} | {"file":"/path"}   (a shaped identity number must be a ref or file)

exit: 0 ok  1 step failed  2 bad spec  3 page or AX absent  4 refused  5 challenge or rate limit
"""

// Per-host navigation count, last hour, under ~/Library/Application Support/firefax. Host names and
// timestamps only, no paths and no values.
struct FileNavCounter: NavCounter {
    private var stateURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/firefax")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nav.json")
    }
    private func load() -> [String: [Double]] {
        guard let d = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let j = obj as? [String: [Double]] else { return [:] }
        return j
    }
    private func save(_ s: [String: [Double]]) {
        if let d = try? JSONSerialization.data(withJSONObject: s) { try? d.write(to: stateURL) }
    }
    func recentCount(_ host: String) -> Int {
        let now = Date().timeIntervalSince1970
        return (load()[host] ?? []).filter { now - $0 < 3600 }.count
    }
    func record(_ host: String) {
        let now = Date().timeIntervalSince1970
        var s = load()
        s[host] = (s[host] ?? []).filter { now - $0 < 3600 } + [now]
        save(s)
    }
}

func liveEngine(human: Bool, dry: Bool, timing: Bool, finals: [String]) -> Engine {
    var e = Engine(clock: RealClock(), store: Keychain(), files: Files(), nav: FileNavCounter())
    e.human = human; e.dryRun = dry; e.showTiming = timing; e.finals = finals
    return e
}

func out(_ lines: [String]) { print(lines.joined(separator: "\n")) }

let args = Array(CommandLine.arguments.dropFirst())

if args.contains("--selftest") { exit(SelfCheck.run() == 0 ? 0 : 1) }
if args.contains("--help") || args.contains("-h") || args.isEmpty { print(help); exit(0) }
if args.contains("--version") { print("firefax 0.1"); exit(0) }

let human = args.contains("--human")
let dry = args.contains("--dry-run")
let timing = args.contains("--timing")
var finals: [String] = []
for (i, a) in args.enumerated() where a == "--final" && i + 1 < args.count { finals.append(args[i + 1]) }
let positional = args.enumerated().filter { i, a in
    !a.hasPrefix("--") && !(i > 0 && args[i - 1] == "--final")
}.map(\.element)

switch positional.first {
case "scan":
    let scope = positional.count > 1 ? positional[1] : nil
    let page: LivePage?
    if let scope, let slash = scope.firstIndex(of: "/") {
        page = LivePage(wantHost: String(scope[..<slash]), wantPath: String(scope[slash...]), clock: RealClock())
    } else if let scope {
        page = LivePage(wantHost: scope, wantPath: "", clock: RealClock())
    } else {
        page = LivePage(clock: RealClock())
    }
    guard let page else { print("firefax scan: no matching Firefox web area"); exit(3) }
    let (code, lines) = liveEngine(human: human, dry: dry, timing: timing, finals: finals).scan(page)
    out(lines); exit(code)

case "fill":
    guard positional.count > 1 else { print("firefax fill: give a spec file or - for stdin"); exit(2) }
    let source = positional[1]
    let data: Data
    if source == "-" { data = FileHandle.standardInput.readDataToEndOfFile() }
    else if let d = FileManager.default.contents(atPath: source) { data = d }
    else { print("firefax fill: cannot read \(source)"); exit(2) }
    let spec: Spec
    do { spec = try SpecParser.parse(data) }
    catch let e as SpecError { print("firefax fill: \(e.message)"); exit(2) }
    catch { print("firefax fill: bad spec"); exit(2) }
    let (wantHost, wantPath) = { () -> (String, String) in
        guard let slash = spec.page.firstIndex(of: "/") else { return (spec.page, "") }
        return (String(spec.page[..<slash]), String(spec.page[slash...]))
    }()
    guard let page = LivePage(wantHost: wantHost, wantPath: wantPath, clock: RealClock()) else {
        print("firefax fill: \(spec.page) is not open in Firefox"); exit(3)
    }
    let (code, lines) = liveEngine(human: human, dry: dry, timing: timing, finals: finals).fill(spec, page)
    out(lines); exit(code)

case "store":
    guard positional.count > 1 else { print("firefax store: give a name"); exit(2) }
    let name = positional[1]
    var data = FileHandle.standardInput.readDataToEndOfFile()
    if data.last == 0x0a { data.removeLast() }  // a trailing newline from the pipe
    guard Keychain().store(name, data) else { print("firefax store: keychain write failed"); exit(1) }
    print("\(name) \(data.count)")  // name and length only, never the value

case "refs":
    let names = Keychain().names()
    if names.isEmpty { print("no refs in \(keychainService)") }
    for r in names { print("\(r.name) \(r.length)") }

default:
    print(help); exit(2)
}
