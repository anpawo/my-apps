import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Network

/// Keeps the Mac awake with the lid closed while a task is working, asked 2026-11-22: a session
/// mid-turn, or any other process claiming a task with a system-sleep assertion. Only on Wi-Fi
/// or Ethernet and above `minBattery`: past those, the default sleep freezes the task instead.
/// A lid-close sleep ignores every assertion, so this sets `pmset disablesleep`, through the
/// sudo rule in Resources/fleet-sleep.sudoers.
@MainActor
final class SleepGuard {
    nonisolated static let minBattery = 10
    private static let retryAfterFailure: TimeInterval = 600
    /// Hold system sleep for reasons that are not a task: the display being on, audio playing.
    private static let notTasks: Set<String> = ["powerd", "coreaudiod"]
    private nonisolated static let pmset = "/usr/bin/pmset"

    private let monitor = NWPathMonitor()
    private var networkUp = true
    private var applied: Bool?
    private var failedAt: Date?
    private let queue = DispatchQueue(label: "fleet.sleepguard")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkUp = up } }
        }
        monitor.start(queue: queue)
    }

    var conditionsMet: Bool {
        let power = Self.power()
        return Self.allowed(networkUp: networkUp, onAC: power.onAC, battery: power.percent)
    }

    nonisolated static func allowed(networkUp: Bool, onAC: Bool, battery: Int?) -> Bool {
        networkUp && (onAC || (battery ?? 100) > minBattery)
    }

    nonisolated static func working(_ state: SessionState) -> Bool {
        [.running, .delegated, .apiError, .paused].contains(state)
    }

    func update(busy: Bool) {
        let wanted = busy && conditionsMet
        guard wanted != applied else { return }
        if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryAfterFailure { return }
        let lidClosed = Self.lidClosed()
        applied = wanted
        NSLog("Fleet: lid-close sleep \(wanted ? "held, a task is working" : "released")")
        queue.async { [weak self] in
            let ok = Self.sudo(["-a", "disablesleep", wanted ? "1" : "0"])
            // Clearing it with the lid already shut does not by itself put the Mac to sleep.
            if ok, !wanted, lidClosed { _ = Self.sudo(["sleepnow"]) }
            guard !ok else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSLog("Fleet: sudo pmset refused, install Resources/fleet-sleep.sudoers")
                    self?.applied = nil
                    self?.failedAt = Date()
                }
            }
        }
    }

    /// Another process saying a task of its own must not be cut by sleep: caffeinate, a
    /// download, a backup, a build.
    static func foreignTask() -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let types: Set<String> = [kIOPMAssertionTypePreventUserIdleSystemSleep as String,
                                  kIOPMAssertionTypePreventSystemSleep as String]
        for (pid, assertions) in dict where pid.int32Value != getpid() {
            guard assertions.contains(where: { types.contains($0[kIOPMAssertionTypeKey as String] as? String ?? "") })
            else { continue }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid.int32Value, &name, UInt32(name.count))
            if !notTasks.contains(String(cString: name)) { return true }
        }
        return false
    }

    private nonisolated static func sudo(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", pmset] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func power() -> (onAC: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (true, nil) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return (d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue, now * 100 / max)
        }
        return (true, nil)
    }

    private static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return state?.takeRetainedValue() as? Bool ?? false
    }
}
