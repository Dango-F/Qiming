import AppKit
import Carbon

extension Notification.Name { static let qimingShortcutsChanged = Notification.Name("QimingShortcutsChanged") }

@MainActor final class Shortcuts {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var action: ((UInt32) -> Void)?

    func update() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        guard UserDefaults.standard.bool(forKey: "shortcuts") else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            let shortcut = Unmanaged<Shortcuts>.fromOpaque(context).takeUnretainedValue()
            let id = key.id
            MainActor.assumeIsolated { shortcut.action?(id) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for (code, id) in [(UInt32(kVK_ANSI_A), UInt32(1)), (UInt32(kVK_ANSI_S), UInt32(2))] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(controlKey | optionKey | cmdKey),
                                            EventHotKeyID(signature: 0x51494D47, id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) }
        }
    }
}
