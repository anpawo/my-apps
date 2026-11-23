import AppKit
import Carbon.HIToolbox

// A plain global: the Carbon callback is a C function pointer and cannot capture anything.
private nonisolated(unsafe) var hotKeyActions: [UInt32: () -> Void] = [:]

/// Carbon `RegisterEventHotKey`: works while another app is in front, with no Accessibility prompt.
@MainActor
enum HotKey {
    private static let signature = OSType(0x5649_4557) // "VIEW"
    private static var handler: EventHandlerRef?

    static func register(key: Int, modifiers: Int, action: @escaping () -> Void) {
        guard installHandler() else { return }
        let id = UInt32(hotKeyActions.count + 1)
        hotKeyActions[id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: signature, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        if status != noErr { NSLog("viewer: hotkey \(key)/\(modifiers) refused (\(status)), taken by another app?") }
    }

    private static func installHandler() -> Bool {
        guard handler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let fired = id.id
            DispatchQueue.main.async { hotKeyActions[fired]?() }
            return noErr
        }, 1, &spec, nil, &handler) == noErr
    }
}
