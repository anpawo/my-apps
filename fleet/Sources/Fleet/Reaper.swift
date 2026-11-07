import AppKit
import Darwin
import IOKit

/// System-wide memory pressure, as the kernel itself judges it.
///
/// Free RAM is not the signal — macOS keeps it near zero on purpose, and a machine with 50 MB
/// free can be perfectly healthy. What hurts is the compressor and the swap file: once pages
/// are being written to the SSD and read straight back, every process on the machine pays disk
/// latency for memory access. The kernel already computes that judgement for its own use and
/// publishes it, so read its answer rather than inventing a worse one out of RSS totals.
enum MemoryPressure {

    /// The values `kern.memorystatus_vm_pressure_level` reports. They are a bitfield, hence
    /// the gap: 1, 2, 4.
    enum Level: Int32 {
        case normal = 1
        case warning = 2
        case critical = 4

        var isTight: Bool { self != .normal }
    }

    static func level() -> Level {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0
        else { return .normal }
        return Level(rawValue: value) ?? .normal
    }

    /// Ticks the CPU has spent at work and idle since boot, summed over every core.
    ///
    /// Their share between two reads says whether every core is busy. Nothing else Fleet
    /// reads says that: memory can be fine, the kernel's pressure normal, Fleet's own tick
    /// perfectly on time — a five-millisecond block still gets placed — while every window on
    /// the machine stutters because no core is free.
    ///
    /// Not the load average, which said it before 26-10: it counts threads waiting as well as
    /// running, read 6 to 7 on these 10 cores with half the CPU idle, and as a one-minute
    /// average it kept sessions held for a minute after the work had stopped.
    static func cpuTicks() -> (busy: UInt32, idle: UInt32)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        // Counters wrap, so every sum and difference wraps with them.
        return (t.0 &+ t.1 &+ t.3, t.2)
    }
    /// The share of the CPU at work between two reads of `cpuTicks`.
    static func busyShare(from a: (busy: UInt32, idle: UInt32), to b: (busy: UInt32, idle: UInt32)) -> Double {
        let work = Double(b.busy &- a.busy), rest = Double(b.idle &- a.idle)
        return work + rest > 0 ? work / (work + rest) : 0
    }
    /// Once: every `mach_host_self()` adds a reference to the port that nothing releases.
    private static let host = mach_host_self()

    /// Bytes of swap in use, and the size of the swap file backing it.
    static func swap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// The kernel zone that leaked 3.9 GB over 11 days and starved the Mac into the watchdog
    /// panic of 2026-11-04.
    static let leakZone = "data.kalloc.1024"

    /// Bytes in use in `leakZone`. Without root the kernel zeroes zone sizes but still counts
    /// elements (zprint's "cur inuse"), so the size is count × element size.
    static func kernelZone() -> UInt64 {
        var names: mach_zone_name_array_t?, info: mach_zone_info_array_t?, mem: mach_memory_info_array_t?
        var nNames: mach_msg_type_number_t = 0, nInfo: mach_msg_type_number_t = 0, nMem: mach_msg_type_number_t = 0
        guard mach_memory_info(host, &names, &nNames, &info, &nInfo, &mem, &nMem) == KERN_SUCCESS else { return 0 }
        func free<T>(_ p: UnsafeMutablePointer<T>?, _ n: mach_msg_type_number_t) {
            guard let p else { return }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: p)), vm_size_t(n) * vm_size_t(MemoryLayout<T>.stride))
        }
        defer { free(names, nNames); free(info, nInfo); free(mem, nMem) }
        guard let names, let info else { return 0 }
        for i in 0..<Int(min(nNames, nInfo)) {
            var raw = names[i].mzn_name
            let name = withUnsafeBytes(of: &raw) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name == leakZone { return info[i].mzi_count * info[i].mzi_elem_size }
        }
        return 0
    }

    /// The GPU's busy share and memory in use, and each process's GPU time so far in ns, read
    /// off the accelerator and its user clients in IOKit: Activity Monitor's GPU column, no root.
    static func gpu() -> (busy: Int, inUse: UInt64, time: [pid_t: UInt64]) {
        var busy = 0, inUse: UInt64 = 0, time: [pid_t: UInt64] = [:]
        func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        var accels: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accels) == KERN_SUCCESS
        else { return (0, 0, [:]) }
        defer { IOObjectRelease(accels) }
        while true {
            let accel = IOIteratorNext(accels)
            guard accel != 0 else { break }
            defer { IOObjectRelease(accel) }
            if let stats = property(accel, "PerformanceStatistics") as? [String: Any] {
                busy = max(busy, (stats["Device Utilization %"] as? NSNumber)?.intValue ?? 0)
                inUse += (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while true {
                let client = IOIteratorNext(clients)
                guard client != 0 else { break }
                defer { IOObjectRelease(client) }
                // "pid 166, WindowServer"
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let pid = pid_t(creator.dropFirst(4).prefix { $0.isNumber }),
                      let usage = property(client, "AppUsage") as? [[String: Any]] else { continue }
                time[pid, default: 0] += usage.reduce(0) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
            }
        }
        return (busy, inUse, time)
    }

    /// What a process is called in the unfolded MEMORY block: an app for all its processes
    /// (every plugin-container is "Firefox"), a script for an interpreter ("python matte.py"),
    /// every Claude Code session "claude", otherwise the executable.
    static func programName(_ pid: pid_t) -> String {
        let path = ProcessScanner.executablePath(pid)
        let base = (path as NSString).lastPathComponent
        // Claude Code runs as its version file ("2.1.318").
        if base == "claude" || base.split(separator: ".").count == 3 && base.allSatisfy({ $0.isNumber || $0 == "." }) {
            return "claude"
        }
        let interpreter = base.lowercased().hasPrefix("python") ? "python" : base
        if interpreter == "python" || ["node", "bun", "deno", "ruby", "perl", "java", "bash", "sh", "zsh", "fish"].contains(base) {
            var rest = ProcessScanner.arguments(pid).dropFirst()
            while let arg = rest.first, arg.hasPrefix("-") {
                if arg == "-m", let module = rest.dropFirst().first { return "\(interpreter) \(module)" }
                if arg == "-c" || arg == "-e" { return "\(interpreter) \(arg)" }
                rest = rest.dropFirst()
            }
            return rest.first.map { "\(interpreter) \(($0 as NSString).lastPathComponent)" } ?? interpreter
        }
        if let app = path.range(of: ".app/") { return (String(path[..<app.lowerBound]) as NSString).lastPathComponent }
        return base.isEmpty ? "pid \(pid)" : base
    }

    /// What the RAM is doing right now, split the way Activity Monitor splits it — which is the
    /// only split worth showing, since it is the one whose numbers you can go and check.
    struct Footprint {
        /// App memory, wired and compressed together: the part that is genuinely spoken for.
        var used: UInt64 = 0
        /// File-backed pages the kernel is keeping around and will drop the moment anything
        /// needs the space. Counted as "used" by every naive reading of free RAM, and the
        /// reason a healthy Mac always looks full.
        var cached: UInt64 = 0
        var compressed: UInt64 = 0
        var wired: UInt64 = 0
        var swap: UInt64 = 0
        /// The swap file macOS has actually made, which is the only ceiling of the four that
        /// exists: cached and compressed are both parts of the RAM total, with no cap of their
        /// own, while swap is a file that is grown on demand — and is absent until it is
        /// needed, hence the zero on a machine that has never had to swap.
        var swapTotal: UInt64 = 0
        var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    }

    static func footprint() -> Footprint {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let paged = swap()
        var out = Footprint(swap: paged.used, swapTotal: paged.total)
        guard ok == KERN_SUCCESS else { return out }

        let page = UInt64(vm_kernel_page_size)
        // `internal` is anonymous memory — an app's own pages. Purgeable is the part of it the
        // app has already said it can lose, so it belongs with the cache, not with the total.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        out.compressed = UInt64(stats.compressor_page_count) * page
        out.wired = UInt64(stats.wire_count) * page
        out.used = (app + UInt64(stats.wire_count)) * page + out.compressed
        out.cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        return out
    }
}

/// What the MEMORY block shows unfolded. Read only while it is open; CPU and GPU are shares of
/// the time between two samples.
struct MemoryDetails {
    struct Row: Identifiable {
        var id: String { name }
        var name: String
        var value: String
    }
    var kernelZone: UInt64 = 0
    var wired: UInt64 = 0
    var gpuBusy = 0
    var gpuMemory: UInt64 = 0
    var diskFree: UInt64 = 0, diskTotal: UInt64 = 0
    var ram: [Row] = [], cpu: [Row] = [], gpu: [Row] = []
}

/// Bytes, rounded to whatever unit reads as a size rather than a number.
func byteLabel(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb)) MB"
}

/// A process big enough to be worth naming when memory is tight.
struct Hog: Identifiable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var rss: UInt64
    /// Set when this one is on the reap list — the panel says so rather than offering a ✕ for
    /// something that is about to go on its own.
    var reapable: Bool = false

    /// Where the process works. This is what lets a Claude session recognise its OWN load:
    /// a container mounting ~/self/finance belongs to the finance session, and no amount of
    /// broadcasting "java 2.7 GB" to every session ever conveys that.
    var cwd: String?

    /// How long it has been running. Sixty hours at full tilt is almost always a leftover,
    /// and the number says so where a size never can.
    var age: TimeInterval = 0

    var sizeLabel: String { byteLabel(rss) }

    var ageLabel: String {
        if age < 3600 { return "\(Int(age / 60)) min" }
        if age < 172_800 { return "\(Int(age / 3600)) h" }
        return "\(Int(age / 86_400)) d"
    }
}

/// Frees memory before the machine grinds, by killing daemons that nothing is using.
///
/// The premise: by the time a Mac feels slow it has been swapping for days, and what is holding
/// the memory is usually not what you are working in — a Gradle daemon left over from a build
/// that finished this morning, an emulator nobody has looked at since Tuesday, Docker's VM
/// running no containers. macOS does eventually intervene on its own, but its rule is roughly
/// "biggest first", which is as likely to take the build you are waiting on as the daemon you
/// forgot about.
///
/// So the rule here is deliberately *not* "biggest". It is: **nothing is using this, and it
/// comes back by itself.** Both halves are required, and each candidate has a test for the
/// first half that looks at what the process is actually doing rather than at how fat it is.
/// Anything that fails either half is never touched — it is only named, in the panel, for you
/// to decide about.
@MainActor
final class Reaper: ObservableObject {

    /// What the panel draws: the pressure right now, and who is holding the memory.
    @Published private(set) var pressure: MemoryPressure.Level = .normal
    @Published private(set) var hogs: [Hog] = []
    /// Drawn whenever the panel is open and nothing is wrong — the quiet half of the strip.
    /// Read once here as well as on every tick, so the first panel of a session shows the
    /// machine rather than a row of zeroes.
    @Published private(set) var footprint = MemoryPressure.footprint()
    @Published private(set) var details = MemoryDetails()
    /// Set by the MEMORY block while it is unfolded.
    var detailsOpen = false {
        didSet {
            guard detailsOpen, !oldValue else { return }
            lastDetails = nil
            sampleDetails()
            // The second sample, which yields the CPU and GPU shares, half a second after the
            // block opens rather than at the next tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.sampleDetails() }
            }
        }
    }
    private var lastDetails: (at: Date, cpu: [pid_t: UInt64], gpu: [pid_t: UInt64])?
    private var programNames: [pid_t: (started: UInt64, name: String)] = [:]

    /// Whether the machine has stopped keeping up — see `sampleFluidity`.
    @Published private(set) var struggling = false
    /// One line saying which signal said so, for the strip and for the agents.
    @Published private(set) var struggleReason = ""

    /// Fired when the machine crosses either way, with that line. On the crossing only: an
    /// alert that repeats every tick is an alert you learn to close without reading.
    var onFluidity: ((Bool, String) -> Void)?

    /// Consecutive ticks that arrived late. See `Config.stallStreak`.
    private var lateStreak = 0
    /// The CPU's ticks at the last sample, and how long every sample since has found it full.
    /// See `Config.strainedCPU`.
    private var lastTicks: (ticks: (busy: UInt32, idle: UInt32), at: Date)?
    private var busyFor: TimeInterval = 0
    /// When the expensive half of a tick last ran.
    private var lastScan = Date.distantPast

    /// Called with a one-line summary after something was actually killed.
    var onReaped: ((String) -> Void)?

    /// Per-candidate CPU history, which is how "nothing is using this" is measured: a daemon
    /// doing work burns CPU, an abandoned one does not. Keyed by pid and pruned as pids go.
    private var lastCPU: [pid_t: (nanos: UInt64, at: Date)] = [:]
    /// Since when each candidate has been continuously below the idle floor. Continuity is the
    /// point — a single quiet sample is meaningless, two unbroken minutes are not.
    private var idleSince: [pid_t: Date] = [:]
    /// One reap at a time: the structural tests shell out, so a second tick can arrive while
    /// the first is still deciding.
    private var reaping = false
    /// Do not re-kill something that is taking its time shutting down.
    private var recentlyKilled: [pid_t: Date] = [:]

    /// Called from `AppController.tick`. Deliberately reuses the timer that is already running
    /// rather than adding a source of its own — the pressure read is one `sysctl`, and a
    /// problem that took two weeks to build up does not need sub-second reflexes.
    /// Called from `AppController.tick`, with how late this tick was against the interval it
    /// was scheduled at and how much slack that interval allowed.
    ///
    /// Two halves. The cheap one — two syscalls and a scheduling verdict — runs every tick, so
    /// the strip and the menu bar dot are never stale. The expensive one walks the process
    /// table and runs every few seconds, because it is 24 ms of main thread and it is looking
    /// for a problem that takes days to build up.
    func tick(lateness: TimeInterval = 0, allowed: TimeInterval = 0) {
        pressure = MemoryPressure.level()
        footprint = MemoryPressure.footprint()
        sampleFluidity(lateness: lateness, allowed: allowed)
        if detailsOpen, Date().timeIntervalSince(lastDetails?.at ?? .distantPast) >= 2 { sampleDetails() }

        guard Date().timeIntervalSince(lastScan) >= Config.reapInterval else { return }
        lastScan = Date()

        let candidates = Reaper.candidates()
        sampleIdleness(candidates)

        // Everything below only matters when memory is actually tight; when it is not, the
        // samples above are all we keep doing, so that the idle streaks are already there when
        // pressure arrives instead of starting from zero at the worst moment.
        guard struggling else {
            if !hogs.isEmpty { hogs = [] }
            return
        }

        let ripe = candidates.filter { $0.kind == .ghost ? Reaper.ownerGone($0.pid) : isIdle($0.pid) }
        hogs = Reaper.topHogs(reapable: Set(ripe.map(\.pid)))
        // Only the kernel's own verdict licenses killing anything in use by someone. A machine
        // that is merely late might be late for a reason that has nothing to do with memory — a
        // build, a backup, a video export — and none of those are Fleet's to end. A ghost is the
        // exception: whoever started it is gone, so there is no one left to be using it.
        reap(pressure.isTight ? ripe : ripe.filter { $0.kind == .ghost })
    }

    // MARK: - Fluidity

    /// Whether the machine is still keeping up, from the two things Fleet can see for free.
    ///
    /// The first is the kernel's own memory pressure. The second is Fleet's own punctuality:
    /// its tick is a few milliseconds of work on a timer, so a tick that arrives a second past
    /// its due time means the scheduler could not place a few milliseconds — and by then it is
    /// not placing anything else on time either. That is the measure this exists for: by the
    /// time you notice the machine is slow, this has been true for a while.
    ///
    /// A streak rather than a sample, because one late tick is a Spotlight index or an app
    /// launching, and because the alert this feeds opens a window in front of you.
    private func sampleFluidity(lateness: TimeInterval, allowed: TimeInterval) {
        if lateness > allowed + Config.stallLateness, lateness < Config.stallImplausible {
            lateStreak += 1
        } else {
            lateStreak = 0
        }
        let stalling = lateStreak >= Config.stallStreak

        // Back to zero at the first sample with a core to spare: that is when a held session
        // can go again, not a minute later.
        var busy = 0.0
        if let ticks = MemoryPressure.cpuTicks() {
            let at = Date()
            if let last = lastTicks {
                busy = MemoryPressure.busyShare(from: last.ticks, to: ticks)
                busyFor = busy >= Config.strainedCPU ? busyFor + at.timeIntervalSince(last.at) : 0
            }
            lastTicks = (ticks, at)
        }
        let saturated = busyFor >= Config.strainedCPUFor

        let full = footprint.total > 0
            && Double(footprint.used) / Double(footprint.total) >= Config.strainedRAM
        let now = stalling || saturated || full
        guard now != struggling else { return }

        struggling = now
        guard now else {
            struggleReason = ""
            onFluidity?(false, "")
            return
        }
        // Named in the order they arrive, so the line says the earliest true thing rather
        // than the worst one: a full run queue precedes a late tick, which precedes the RAM.
        if saturated {
            struggleReason = String(format: "every core is busy (%.0f%% of the CPU)", busy * 100)
        } else if stalling {
            struggleReason = String(format: "Fleet's own tick is %.1fs late", lateness)
        } else {
            let percent = Int((Double(footprint.used) / Double(footprint.total) * 100).rounded())
            struggleReason = "\(percent)% of the RAM is spoken for"
        }
        // The hogs are what the alert is for, and the last scan may be seconds old.
        hogs = Reaper.topHogs(reapable: [])
        onFluidity?(true, struggleReason)
    }

    /// For `--render --strain`: the amber state, over whatever is really holding the memory.
    func simulateStrain() {
        struggling = true
        struggleReason = "every core is busy (98% of the CPU)"
        hogs = Reaper.topHogs(reapable: [])
    }

    // MARK: - Idleness

    private func sampleIdleness(_ candidates: [Reapable]) {
        let now = Date()
        let live = Set(candidates.map(\.pid))
        lastCPU = lastCPU.filter { live.contains($0.key) }
        idleSince = idleSince.filter { live.contains($0.key) }
        recentlyKilled = recentlyKilled.filter { now.timeIntervalSince($0.value) < 60 }

        for candidate in candidates {
            guard let previous = lastCPU[candidate.pid] else {
                // First sight of this pid. No delta yet, so no verdict yet — and no idle
                // streak either, which is what stops a freshly launched Fleet from killing
                // anything before it has watched it for a while.
                lastCPU[candidate.pid] = (candidate.cpuNanos, now)
                continue
            }
            let seconds = now.timeIntervalSince(previous.at)
            guard seconds >= 1 else { continue }
            let percent = Double(candidate.cpuNanos &- previous.nanos) / 1e9 / seconds * 100
            lastCPU[candidate.pid] = (candidate.cpuNanos, now)

            if percent > Config.reapIdleCPUPercent {
                idleSince[candidate.pid] = nil          // busy: the streak breaks
            } else if idleSince[candidate.pid] == nil {
                idleSince[candidate.pid] = now
            }
        }
    }

    /// Whether this candidate has been below the CPU floor without a break for `window`.
    ///
    /// The window is a parameter because `--reap` sets it to zero: there, a person is asking
    /// for the clean-up now, so the streak only has to exist — it does not have to be old. The
    /// long window is what makes the *automatic* path safe, and nothing about it protects a
    /// decision somebody made deliberately.
    func isIdle(_ pid: pid_t, window: TimeInterval = Config.reapIdleWindow) -> Bool {
        guard recentlyKilled[pid] == nil, let since = idleSince[pid] else { return false }
        return Date().timeIntervalSince(since) >= window
    }

    // MARK: - Reaping

    private func reap(_ candidates: [Reapable]) {
        guard !reaping, !candidates.isEmpty else { return }
        reaping = true

        Task.detached {
            // The second gate, and the expensive one: ask each candidate's own subsystem
            // whether it is in use. Off the main actor because some of these fork.
            let cleared = candidates.filter { Reaper.isUnused($0) }
            await MainActor.run { [weak self] in
                self?.finishReap(cleared)
            }
        }
    }

    private func finishReap(_ cleared: [Reapable]) {
        reaping = false
        guard !cleared.isEmpty else { return }

        var killed: [String] = []
        var freed: UInt64 = 0
        for candidate in cleared {
            guard candidate.terminate() else { continue }
            recentlyKilled[candidate.pid] = Date()
            idleSince[candidate.pid] = nil
            killed.append("\(candidate.name) (\(byteLabel(candidate.rss)))")
            freed += candidate.rss
            NSLog("Fleet: reaped \(candidate.name) pid \(candidate.pid) — \(candidate.reason)")
        }
        guard !killed.isEmpty else { return }

        onReaped?("Freed \(byteLabel(freed)): " + killed.joined(separator: ", "))
    }

    // MARK: - Candidates

    /// One pass over the process table, classifying the four things Fleet is willing to kill.
    ///
    /// Cheap enough to run on every tick: `proc_listpids` plus a `proc_pidinfo` per pid is a
    /// couple of hundred microseconds, and nothing here forks. See `ProcessScanner` for why
    /// shelling out to `ps` on a polling path is not an option.
    static func candidates() -> [Reapable] {
        var out: [Reapable] = []
        for pid in ProcessScanner.allPIDs() where pid > 0 {
            guard let kind = classify(pid) else { continue }
            guard let task = ProcessScanner.taskInfo(pid) else { continue }
            out.append(Reapable(
                pid: pid,
                kind: kind,
                rss: task.pti_resident_size + (kind == .dockerDesktop ? virtualMachineRSS() : 0),
                cpuNanos: task.pti_total_user &+ task.pti_total_system
            ))
        }
        return out
    }

    /// Docker's own helper is a rounding error; the memory is in the Virtualization.framework
    /// host process running the Linux VM, which is a system XPC service reparented to launchd
    /// with nothing in its path or arguments tying it back to Docker.
    ///
    /// So it is attributed by type, which is only right while Docker is the one VM on the
    /// machine. With Parallels or UTM also running, the figure reported for Docker would be too
    /// big. It stays a *reported* figure and never a decision — what gets killed is Docker.app,
    /// chosen by bundle id — so the worst case is a banner that overstates what it freed.
    private static func virtualMachineRSS() -> UInt64 {
        var total: UInt64 = 0
        for pid in ProcessScanner.allPIDs() where pid > 0 {
            let path = ProcessScanner.executablePath(pid)
            guard path.hasSuffix("com.apple.Virtualization.VirtualMachine"),
                  let task = ProcessScanner.taskInfo(pid) else { continue }
            total += task.pti_resident_size
        }
        return total
    }

    /// What each pid turned out to be, against the moment it started.
    ///
    /// Same reasoning as `ProcessScanner.isClaudeSession`: an executable path and a command
    /// line are fixed at exec, and looking them up for every process on the machine once a
    /// second was the single most expensive thing Fleet did — 80 ms of `proc_pidpath` on the
    /// main thread, which is ten dropped frames of whatever you were scrolling.
    ///
    /// The one thing re-checked on a hit is a session that was *not* an orphan: it becomes one
    /// when its shell dies, without the process itself changing. The reverse never happens —
    /// nothing gets its parent back — so an orphan verdict, once taken, holds.
    private nonisolated(unsafe) static var kinds: [pid_t: (started: UInt64, kind: Reapable.Kind?)] = [:]
    /// For each `.ghost` candidate, the pid of the Claude Code session that started it.
    private nonisolated(unsafe) static var owners: [pid_t: pid_t] = [:]

    private static func classify(_ pid: pid_t) -> Reapable.Kind? {
        guard let bsd = ProcessScanner.bsdInfo(pid) else { return nil }
        let started = UInt64(bsd.pbi_start_tvsec)
        if let known = kinds[pid], known.started == started {
            // A live session that has since lost its shell still has to be caught, so the one
            // verdict that depends on something other than the process itself is re-taken.
            guard known.kind == nil, ProcessScanner.isClaudeSession(pid) else { return known.kind }
            return bsd.pbi_ppid == 1 ? .orphanSession : nil
        }
        let kind = classifyUncached(pid, ppid: pid_t(bsd.pbi_ppid))
        kinds[pid] = (started, kind)
        if kinds.count > 2048 {
            let live = Set(ProcessScanner.allPIDs())
            kinds = kinds.filter { live.contains($0.key) }
            owners = owners.filter { live.contains($0.key) }
        }
        return kind
    }

    private static func classifyUncached(_ pid: pid_t, ppid: pid_t) -> Reapable.Kind? {
        let path = ProcessScanner.executablePath(pid)
        guard !path.isEmpty else { return nil }

        // Docker Desktop's Linux VM. Identified by the helper that boots it rather than by the
        // shared Virtualization.framework host process, which any VM app would also be using.
        if path.contains("/Docker.app/") && path.hasSuffix("com.docker.virtualization") {
            return .dockerDesktop
        }

        // The Android emulator runs as a qemu binary out of the SDK, so the SDK path is what
        // separates it from any other qemu on the machine.
        if path.contains("/emulator/qemu/")
            && (path as NSString).lastPathComponent.hasPrefix("qemu-system-") {
            return .androidEmulator
        }

        if (path as NSString).lastPathComponent == "java" {
            // Every JVM on the machine looks alike from the outside; the main class is the only
            // thing that says which one this is.
            let argv = ProcessScanner.arguments(pid)
            if argv.contains("org.gradle.launcher.daemon.bootstrap.GradleDaemon") {
                return .gradleDaemon
            }
            return nil
        }

        // A Claude Code session whose shell died — a terminal window closed on it, a crash —
        // gets reparented to launchd. A live session always has its shell in between, so this
        // is a session that is talking to nobody and can never be answered.
        if ProcessScanner.isClaudeSession(pid) {
            return ppid == 1 ? .orphanSession : nil
        }

        // An installed app is one somebody meant to keep, even when a session is what started it:
        // `open -a` from an install script passes CLAUDE_PID on, and mr. screenshot was reaped
        // with its session (27-09).
        if path.contains("/Applications/") { return nil }

        // Everything a session runs from its tools carries the session's pid in its environment.
        // Only a candidate here: whether that session is still there is the half that changes,
        // and it is asked at reap time — see `ownerGone`.
        if let owner = ProcessScanner.environment(pid).lazy
            .compactMap({ $0.hasPrefix("CLAUDE_PID=") ? pid_t($0.dropFirst(11)) : nil }).first {
            owners[pid] = owner
            return .ghost
        }
        return nil
    }

    /// Whether the session that started this process has ended: its pid is free, or it now
    /// belongs to something that started after this process did. Not "is it a Claude session":
    /// a headless `claude -p` run by launchd is not one Fleet lists, and its children are not
    /// ghosts while it runs.
    nonisolated static func ownerGone(_ pid: pid_t) -> Bool {
        guard let owner = owners[pid], let me = ProcessScanner.bsdInfo(pid) else { return false }
        guard kill(owner, 0) == 0, let them = ProcessScanner.bsdInfo(owner) else { return true }
        return them.pbi_start_tvsec > me.pbi_start_tvsec
    }

    /// The second gate: is anything actually using this? Runs off the main actor; may fork.
    ///
    /// Never optimistic. Anything this cannot establish for certain reads as "in use", so an
    /// unavailable `docker` or an unreadable log leaves the process alone.
    nonisolated static func isUnused(_ candidate: Reapable) -> Bool {
        switch candidate.kind {
        case .gradleDaemon:
            // The daemon records every build it runs as a command execution, started and then
            // completed. A build that is merely waiting on the network sits between the two
            // burning no CPU at all — which is exactly the case the idle streak alone would
            // misread as abandoned — so the open execution is what protects it.
            //
            // The log's mtime cannot stand in for this: an idle daemon writes a periodic health
            // check to the same file every few seconds, so mtime is always fresh and always
            // meaningless.
            guard let log = gradleDaemonLog(pid: candidate.pid),
                  let tail = tail(of: log, bytes: Config.reapLogTailBytes) else { return false }
            guard let last = tail.range(of: "Command execution: ", options: .backwards) else {
                return true             // a daemon that has never run a build
            }
            return tail[last.upperBound...].hasPrefix("completed")

        case .dockerDesktop:
            // Containers run inside the VM and are invisible from the host, so the only
            // honest answer comes from Docker itself.
            guard let docker = dockerBinary(),
                  let listing = shell(docker, ["ps", "-q"]) else { return false }
            return listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        case .androidEmulator:
            // An emulator with a debugger, a running app or an install in flight is burning
            // CPU, so the idle streak already covers it. Nothing cheaper to add here.
            return true

        case .orphanSession:
            // Being orphaned is the whole test, and it was established in `classify`.
            return true

        case .ghost:
            return ownerGone(candidate.pid)
        }
    }

    /// Where the `docker` client actually is.
    ///
    /// Not `/usr/bin/env`: Fleet is started by launchd, whose PATH is the bare
    /// `/usr/bin:/bin:/usr/sbin:/sbin` — the Homebrew and `/usr/local` directories a shell
    /// would have are simply not there, so `env` would never find it and the gate would fail
    /// closed forever. Failing closed is safe, but it is also silently useless.
    private nonisolated static func dockerBinary() -> String? {
        [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The log Gradle keeps per daemon, under `~/.gradle/daemon/<version>/daemon-<pid>.out.log`.
    private nonisolated static func gradleDaemonLog(pid: pid_t) -> String? {
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".gradle/daemon")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return nil
        }
        for version in versions {
            let path = "\(root)/\(version)/daemon-\(pid).out.log"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// The last chunk of a file. Gradle daemon logs run to megabytes and only the end of one
    /// says anything about what it is doing now.
    private nonisolated static func tail(of path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A short command, with a deadline. Nil when it failed or took too long — callers read
    /// that as "could not establish", never as "unused".
    private nonisolated static func shell(_ launch: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launch)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }

        // `docker` talks to a daemon that may itself be wedged, and a background app must not
        // hang on it. Deadline, then kill the client.
        let deadline = Date().addingTimeInterval(Config.reapCommandTimeout)
        while task.isRunning && Date() < deadline { usleep(50_000) }
        guard !task.isRunning else {
            task.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return task.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    // MARK: - Panel

    /// Reads `details`: RAM and CPU over his own processes (macOS's are not readable without
    /// root), GPU over every process, each summed by `programName`, top three of each.
    func sampleDetails() {
        let now = Date(), me = getuid()
        let since = lastDetails.map { now.timeIntervalSince($0.at) * 1e9 } ?? 0
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var ram: [String: Double] = [:], cpuShare: [String: Double] = [:], gpuShare: [String: Double] = [:]
        var cpu: [pid_t: UInt64] = [:]
        func name(_ pid: pid_t) -> String {
            let started = ProcessScanner.bsdInfo(pid).map { UInt64($0.pbi_start_tvsec) } ?? 0
            if let known = programNames[pid], known.started == started { return known.name }
            let fresh = MemoryPressure.programName(pid)
            programNames[pid] = (started, fresh)
            return fresh
        }
        for pid in ProcessScanner.allPIDs() where pid > 0 {
            guard ProcessScanner.bsdInfo(pid)?.pbi_uid == me else { continue }
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0 }
            }
            guard ok else { continue }
            let label = name(pid)
            ram[label, default: 0] += Double(info.ri_phys_footprint)
            // Mach ticks on Apple silicon, not nanoseconds.
            let ns = (info.ri_user_time &+ info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
            cpu[pid] = ns
            if since > 0, let before = lastDetails?.cpu[pid], ns >= before {
                cpuShare[label, default: 0] += Double(ns - before) / since * 100
            }
        }
        let gpu = MemoryPressure.gpu()
        if since > 0 {
            for (pid, ns) in gpu.time {
                guard let before = lastDetails?.gpu[pid], ns >= before else { continue }
                gpuShare[name(pid), default: 0] += Double(ns - before) / since * 100
            }
        }
        func top(_ values: [String: Double], floor: Double, _ format: (Double) -> String) -> [MemoryDetails.Row] {
            values.filter { $0.value >= floor }.sorted { $0.value > $1.value }.prefix(3)
                .map { MemoryDetails.Row(name: $0.key, value: format($0.value)) }
        }
        var out = MemoryDetails(kernelZone: MemoryPressure.kernelZone(), wired: footprint.wired,
                                gpuBusy: gpu.busy, gpuMemory: gpu.inUse)
        // The figure Finder shows: purgeable space counts as free.
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            out.diskFree = UInt64(max(v.volumeAvailableCapacityForImportantUsage ?? 0, 0))
            out.diskTotal = UInt64(max(v.volumeTotalCapacity ?? 0, 0))
        }
        out.ram = top(ram, floor: 0) { byteLabel(UInt64($0)) }
        // No share before the second sample: the last ones stay rather than blank lines.
        out.cpu = since > 0 ? top(cpuShare, floor: 1) { "\(Int($0.rounded()))%" } : details.cpu
        out.gpu = since > 0 ? top(gpuShare, floor: 1) { "\(Int($0.rounded()))%" } : details.gpu
        details = out
        lastDetails = (now, cpu, gpu.time)
        if programNames.count > 2048 {
            let live = Set(ProcessScanner.allPIDs())
            programNames = programNames.filter { live.contains($0.key) }
        }
    }

    /// The biggest processes on the machine, for the panel to name. Purely informational —
    /// nothing here is killed automatically; size alone is never a reason.
    static func topHogs(reapable: Set<pid_t>) -> [Hog] {
        var found: [Hog] = []
        let mine = getpid()
        for pid in ProcessScanner.allPIDs() where pid > 0 && pid != mine {
            guard let task = ProcessScanner.taskInfo(pid),
                  task.pti_resident_size > Config.hogFloorBytes else { continue }
            let bsd = ProcessScanner.bsdInfo(pid)
            let debut = bsd.map { TimeInterval($0.pbi_start_tvsec) } ?? 0
            found.append(Hog(pid: pid,
                             name: ProcessScanner.displayName(pid),
                             rss: task.pti_resident_size,
                             reapable: reapable.contains(pid),
                             cwd: ProcessScanner.workingDirectory(pid),
                             age: debut > 0 ? Date().timeIntervalSince1970 - debut : 0))
        }
        return Array(found.sorted { $0.rss > $1.rss }.prefix(Config.hogCount))
    }

    /// The panel's ✕. Asks a GUI app to quit so it can save what it has; anything else gets a
    /// polite signal. Never `SIGKILL` — that is the one macOS uses, and losing work is the
    /// thing this whole feature exists to avoid.
    static func dismiss(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        } else {
            kill(pid, SIGTERM)
        }
    }
}

/// A process Fleet is willing to kill, once both gates agree.
struct Reapable {
    enum Kind {
        case gradleDaemon
        case androidEmulator
        case dockerDesktop
        case orphanSession
        /// Left running by a Claude Code session that has since ended — a background command,
        /// a dev server, a headless browser nobody closed.
        case ghost
    }

    var pid: pid_t
    var kind: Kind
    var rss: UInt64
    var cpuNanos: UInt64

    var name: String {
        switch kind {
        case .gradleDaemon: return "Gradle daemon"
        case .androidEmulator: return "Android emulator"
        case .dockerDesktop: return "Docker"
        case .orphanSession: return "orphaned Claude session"
        case .ghost: return ProcessScanner.displayName(pid)
        }
    }

    var reason: String {
        switch kind {
        case .gradleDaemon: return "no build running; restarts on the next one"
        case .androidEmulator: return "idle; the AVD keeps its state"
        case .dockerDesktop: return "no containers running"
        case .orphanSession: return "its terminal is gone"
        case .ghost: return "the session that started it is gone"
        }
    }

    /// Returns whether the request went out.
    @MainActor func terminate() -> Bool {
        switch kind {
        case .dockerDesktop:
            // Killing the VM process behind Docker Desktop's back leaves the app sitting there
            // believing it still has one. Quitting the app takes the whole stack down cleanly.
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.docker.docker").first else {
                return false
            }
            return app.terminate()
        default:
            return kill(pid, SIGTERM) == 0
        }
    }
}
