import AppKit
import MachO

// A window's desktop, kept across a frontend replacement: a new window opens on the desktop in front.
// Moving one needs the bridged operation the Dock is handed (SLSMoveWindowsToManagedSpace moves nothing since macOS 14.5), as Fleet's Spaces.swift does.
@MainActor
enum Desktops {
    // Left to right, screen after screen; fullscreen spaces left out, no window can join one.
    private static func all() -> [UInt64] {
        (CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []).flatMap { screen in
            (screen["Spaces"] as? [[String: Any]] ?? []).filter { $0["type"] as? Int == 0 }.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        }
    }

    private static func spaces(of window: Int) -> [UInt64] {
        guard window > 0 else { return [] }
        return (CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [window] as CFArray) as? [NSNumber] ?? []).map(\.uint64Value)
    }

    static func index(of window: NSWindow) -> Int? {
        spaces(of: window.windowNumber).first.flatMap { all().firstIndex(of: $0) }
    }

    static func move(_ window: NSWindow, to index: Int) {
        let desktops = all()
        guard desktops.indices.contains(index), spaces(of: window.windowNumber) != [desktops[index]] else { return }
        guard let perform = performBridged, let type = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") as? NSObject.Type,
              let initialize = class_getMethodImplementation(type, initWithWindows) else { NSLog("VCX: this macOS has no bridged window move"); return }
        let operation = unsafeBitCast(initialize, to: Initializer.self)(type.perform(NSSelectorFromString("alloc")).takeRetainedValue(), initWithWindows, [window.windowNumber] as CFArray, desktops[index])
        _ = perform(Unmanaged.passUnretained(operation).toOpaque())
    }

    private typealias Initializer = @convention(c) (AnyObject, Selector, CFArray, UInt64) -> AnyObject
    private typealias Perform = @convention(c) (UnsafeMutableRawPointer) -> Int64
    private static let initWithWindows = NSSelectorFromString("initWithWindows:spaceID:")
    private static let performBridged: Perform? = symbol("__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation",
                                                         in: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight").map { unsafeBitCast($0, to: Perform.self) }

    // A local symbol, which dlsym cannot reach: read from the loaded image's symbol table.
    private static func symbol(_ name: String, in image: String) -> UnsafeMutableRawPointer? {
        for i in 0..<_dyld_image_count() where _dyld_get_image_name(i).map({ String(cString: $0) }) == image {
            guard let header = _dyld_get_image_header(i) else { return nil }
            let slide = _dyld_get_image_vmaddr_slide(i)
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            var linkedit: segment_command_64?, symtab: symtab_command?
            for _ in 0..<header.pointee.ncmds {
                let kind = command.load(as: load_command.self)
                if kind.cmd == LC_SYMTAB { symtab = command.load(as: symtab_command.self) }
                if kind.cmd == LC_SEGMENT_64 {
                    let segment = command.load(as: segment_command_64.self)
                    if withUnsafeBytes(of: segment.segname, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == "__LINKEDIT" { linkedit = segment }
                }
                command = command.advanced(by: Int(kind.cmdsize))
            }
            guard let linkedit, let symtab else { return nil }
            let base = Int(linkedit.vmaddr) - Int(linkedit.fileoff) + slide
            guard let names = UnsafePointer<CChar>(bitPattern: base + Int(symtab.stroff)),
                  let entries = UnsafePointer<nlist_64>(bitPattern: base + Int(symtab.symoff)) else { return nil }
            for entry in UnsafeBufferPointer(start: entries, count: Int(symtab.nsyms)) where strcmp(names + Int(entry.n_un.n_strx), name) == 0 {
                return UnsafeMutableRawPointer(bitPattern: Int(entry.n_value) + slide)
            }
        }
        return nil
    }
}

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray
