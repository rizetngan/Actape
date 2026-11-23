import Foundation
import CoreGraphics
import CoreFoundation
import Carbon.HIToolbox

/// A single physical trigger can be a side button or a key with modifiers.
enum TriggerInput: Hashable {
    case mouse(Int)
    case key(UInt16, UInt64)
}

/// Global physical-input tap used for binding, starting and releasing macros.
/// Generated playback events are filtered to avoid recursively triggering a macro.
@MainActor
final class MouseTriggerMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var consumedMouseButtons: Set<Int> = []
    private var consumedKeyCodes: Set<UInt16> = []
    private var capturePrimaryKey: UInt16?
    private var captureModifiers: UInt64 = 0
    private var activeInput: TriggerInput?
    private var activeMacroID: UUID?
    private var hasReleasedActiveTrigger = false

    var resolveMacro: ((TriggerInput) -> UUID?)?
    var onCapture: ((UUID, TriggerInput) -> Void)?
    /// true on initial physical key/button down; false when released.
    var onTrigger: ((UUID, Bool) -> Void)?

    var isSuspended = false
    private(set) var captureMacroID: UUID?
    var isRunning: Bool { eventTap != nil }

    static let modifierMask: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn
    ]

    static func normalizedFlags(_ flags: CGEventFlags) -> UInt64 {
        flags.intersection(modifierMask).rawValue
    }

    func start() -> Bool {
        guard !isRunning else { return true }
        let kinds: [CGEventType] = [
            .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .flagsChanged
        ]
        let mask = kinds.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MouseTriggerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                let consume = MainActor.assumeIsolated {
                    monitor.handle(type: type, event: event)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: info
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func captureNextButton(for macroID: UUID) {
        captureMacroID = macroID
        capturePrimaryKey = nil
        captureModifiers = 0
    }

    func cancelCapture() {
        captureMacroID = nil
        capturePrimaryKey = nil
        captureModifiers = 0
    }

    func stop() {
        cancelCapture()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        consumedMouseButtons.removeAll()
        consumedKeyCodes.removeAll()
        activeInput = nil
        activeMacroID = nil
    }

    private func releaseActive(_ input: TriggerInput? = nil) {
        guard let macroID = activeMacroID, !hasReleasedActiveTrigger else { return }
        if let input, activeInput != input { return }
        hasReleasedActiveTrigger = true
        onTrigger?(macroID, false)
    }

    private func beginActive(_ input: TriggerInput) -> Bool {
        guard let macroID = resolveMacro?(input) else { return false }
        activeInput = input
        activeMacroID = macroID
        hasReleasedActiveTrigger = false
        onTrigger?(macroID, true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }

        // Do not replay our own playback into the global trigger listener.
        if event.getIntegerValueField(.eventSourceUnixProcessID) ==
            Int64(ProcessInfo.processInfo.processIdentifier) { return false }

        if type == .flagsChanged {
            if case .key(_, let needed)? = activeInput, needed != 0 {
                let now = Self.normalizedFlags(event.flags)
                if now & needed != needed { releaseActive() }
            }
            return false
        }

        if type == .otherMouseUp || type == .otherMouseDown {
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard button >= 2 else { return false }
            if type == .otherMouseUp {
                let consumed = consumedMouseButtons.remove(button) != nil
                if consumed {
                    releaseActive(.mouse(button))
                    if activeInput == .mouse(button) { activeInput = nil; activeMacroID = nil }
                }
                return consumed
            }
            if isSuspended { return false }
            if let macroID = captureMacroID {
                consumedMouseButtons.insert(button)
                captureMacroID = nil
                onCapture?(macroID, .mouse(button))
                return true
            }
            let input = TriggerInput.mouse(button)
            if consumedMouseButtons.contains(button) { return true }
            if beginActive(input) {
                consumedMouseButtons.insert(button)
                return true
            }
            return false
        }

        guard type == .keyDown || type == .keyUp else { return false }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            if capturePrimaryKey == key {
                let modifiers = captureModifiers
                capturePrimaryKey = nil
                let macroID = captureMacroID
                captureMacroID = nil
                if let macroID {
                    onCapture?(macroID, .key(key, modifiers))
                }
                return true
            }
            let consumed = consumedKeyCodes.remove(key) != nil
            if consumed {
                if case .key(let activeKey, _)? = activeInput, activeKey == key {
                    releaseActive()
                    activeInput = nil
                    activeMacroID = nil
                }
            }
            return consumed
        }

        if isSuspended { return false }
        if let macroID = captureMacroID {
            if key == UInt16(kVK_Escape) {
                cancelCapture()
                onCapture?(macroID, .key(key, 0)) // Store treats Escape as cancellation.
                consumedKeyCodes.insert(key)
                return true
            }
            if capturePrimaryKey == nil {
                capturePrimaryKey = key
                captureModifiers = Self.normalizedFlags(event.flags)
            }
            return true
        }
        if consumedKeyCodes.contains(key) { return true }
        if key == UInt16(kVK_F6) || key == UInt16(kVK_F7) || key == UInt16(kVK_Escape) {
            return false
        }
        let input = TriggerInput.key(key, Self.normalizedFlags(event.flags))
        if beginActive(input) {
            consumedKeyCodes.insert(key)
            return true
        }
        return false
    }
}
