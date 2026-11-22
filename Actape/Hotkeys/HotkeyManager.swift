import Foundation
import Carbon.HIToolbox
import AppKit

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    struct Binding {
        var keyCode: UInt32
        var modifiers: UInt32
        var handler: () -> Void
    }

    private var registrations: [UInt32: (ref: EventHotKeyRef?, binding: Binding)] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         { _, eventRef, _ in
            guard let eventRef = eventRef else { return noErr }
            var hkID = EventHotKeyID()
            let s = GetEventParameter(eventRef,
                                      EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID),
                                      nil,
                                      MemoryLayout<EventHotKeyID>.size,
                                      nil,
                                      &hkID)
            if s == noErr {
                let id = hkID.id
                DispatchQueue.main.async {
                    HotkeyManager.shared.fire(id: id)
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        if status == noErr { handlerInstalled = true }
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32 = 0, handler: @escaping () -> Void) -> UInt32 {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        let signature: OSType = 0x4D43_524F  // 'MCRO'
        let hkID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        registrations[id] = (ref, Binding(keyCode: keyCode, modifiers: modifiers, handler: handler))
        return id
    }

    /// Replaces all current registrations with the given set. Used to apply
    /// configurable shortcuts (call again whenever the user changes them).
    func setBindings(_ bindings: [(keyCode: UInt32, modifiers: UInt32, handler: () -> Void)]) {
        for id in Array(registrations.keys) { unregister(id: id) }
        for b in bindings {
            register(keyCode: b.keyCode, modifiers: b.modifiers, handler: b.handler)
        }
    }

    func unregister(id: UInt32) {
        if let entry = registrations[id], let ref = entry.ref {
            UnregisterEventHotKey(ref)
        }
        registrations.removeValue(forKey: id)
    }

    fileprivate func fire(id: UInt32) {
        registrations[id]?.binding.handler()
    }
}
