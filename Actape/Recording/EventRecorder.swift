import Foundation
import AppKit
import CoreGraphics
import QuartzCore
import Carbon.HIToolbox

@MainActor
final class EventRecorder {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastTimestamp: TimeInterval = 0
    private var onEvent: ((MacroEvent) -> Void)?

    /// A mouse-down whose matching up hasn't arrived yet. Held back so a
    /// down+up pair with no intervening drag can be coalesced into a single
    /// `.click` step. Flushed as a literal `.mouseDown` if anything else
    /// (a drag, key, scroll, or recording stop) happens first.
    private var pendingDown: MacroEvent?

    /// Keycodes that should never be recorded (typically the global hotkeys).
    var blockedKeyCodes: Set<UInt16> = [UInt16(kVK_F6), UInt16(kVK_F7)]

    /// A down→up pair with no movement is coalesced into one `.click` only if the
    /// button was held for less than this. A longer hold is kept as a literal
    /// `Mouse Down` + `Mouse Up` so the hold duration survives (press-and-hold).
    /// Movement always wins: any drag between down and up makes it a drag,
    /// regardless of duration.
    var clickMaxHoldMs: Int = 150

    var isRunning: Bool { eventTap != nil }

    func start(onEvent: @escaping (MacroEvent) -> Void) -> Bool {
        guard !isRunning else { return true }
        self.onEvent = onEvent
        self.lastTimestamp = 0
        self.pendingDown = nil

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)     |
            (1 << CGEventType.leftMouseUp.rawValue)       |
            (1 << CGEventType.rightMouseDown.rawValue)    |
            (1 << CGEventType.rightMouseUp.rawValue)      |
            (1 << CGEventType.otherMouseDown.rawValue)    |
            (1 << CGEventType.otherMouseUp.rawValue)      |
            (1 << CGEventType.leftMouseDragged.rawValue)  |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)           |
            (1 << CGEventType.keyUp.rawValue)             |
            (1 << CGEventType.flagsChanged.rawValue)      |
            (1 << CGEventType.scrollWheel.rawValue)

        let info = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<EventRecorder>.fromOpaque(refcon).takeUnretainedValue()
                // Tap callback runs on the runloop thread the source is attached to (main).
                MainActor.assumeIsolated {
                    recorder.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: info
        ) else {
            self.onEvent = nil
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        // Emit any held-back mouse-down as a literal down so it isn't lost.
        flushPendingDown()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        onEvent = nil
        lastTimestamp = 0
        pendingDown = nil
    }

    private func flushPendingDown() {
        if let down = pendingDown {
            pendingDown = nil
            onEvent?(down)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system can disable a tap (timeout / user input). Re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let location = event.location

        var me = MacroEvent()
        me.x = location.x
        me.y = location.y

        switch type {
        case .leftMouseDown:
            me.kind = .mouseDown
            me.button = .left
            me.clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        case .leftMouseUp:
            me.kind = .mouseUp
            me.button = .left
            me.clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        case .rightMouseDown:
            me.kind = .mouseDown
            me.button = .right
            me.clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        case .rightMouseUp:
            me.kind = .mouseUp
            me.button = .right
            me.clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        case .otherMouseDown:
            me.kind = .mouseDown
            me.button = .other
        case .otherMouseUp:
            me.kind = .mouseUp
            me.button = .other
        case .leftMouseDragged:
            me.kind = .mouseDrag
            me.button = .left
        case .rightMouseDragged:
            me.kind = .mouseDrag
            me.button = .right
        case .otherMouseDragged:
            me.kind = .mouseDrag
            me.button = .other
        case .keyDown:
            me.kind = .keyDown
            me.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            me.modifierFlags = UInt64(event.flags.rawValue)
            if blockedKeyCodes.contains(me.keyCode) { return }
        case .keyUp:
            me.kind = .keyUp
            me.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            me.modifierFlags = UInt64(event.flags.rawValue)
            if blockedKeyCodes.contains(me.keyCode) { return }
        case .flagsChanged:
            me.kind = .flagsChanged
            me.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            me.modifierFlags = UInt64(event.flags.rawValue)
        case .scrollWheel:
            me.kind = .scroll
            me.scrollDeltaY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            me.scrollDeltaX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        default:
            return
        }

        let now = CACurrentMediaTime()
        let delayMs: Int
        if lastTimestamp == 0 {
            delayMs = 0
        } else {
            delayMs = max(0, Int(((now - lastTimestamp) * 1000).rounded()))
        }
        lastTimestamp = now
        me.delayMs = delayMs

        emit(me)
    }

    /// Coalesces a down+up pair into a single `.click`. A `.mouseDown` is held
    /// back; if the very next mouse event is its matching `.mouseUp` *and* it
    /// arrived within `clickMaxHoldMs`, the pair becomes one `.click` (carrying
    /// the down's pre-delay and the up's click count). A longer gap keeps the
    /// literal down + up so a press-and-hold survives. Any other event flushes
    /// the held down first, preserving drags and manual sequences exactly.
    ///
    /// Reaching the `.mouseUp` branch with a matching `pendingDown` already
    /// implies *no movement* happened (a drag would have flushed the down via
    /// the `default` branch), so `me.delayMs` here is exactly the hold time.
    private func emit(_ me: MacroEvent) {
        switch me.kind {
        case .mouseDown:
            flushPendingDown()          // two downs in a row: keep the first literal
            pendingDown = me            // hold; wait for the matching up

        case .mouseUp:
            if let down = pendingDown, down.button == me.button {
                pendingDown = nil
                if me.delayMs < clickMaxHoldMs {
                    var click = down
                    click.kind = .click
                    click.clickCount = max(down.clickCount, me.clickCount)
                    onEvent?(click)
                } else {
                    // Held too long to be a tap — preserve it as a literal
                    // press, keeping the hold as the up's delay.
                    onEvent?(down)
                    onEvent?(me)
                }
            } else {
                onEvent?(me)            // unpaired up (e.g. after a drag)
            }

        default:
            // Drag, move, key, scroll, modifier: the held down was a real press,
            // not a click — emit it literally, in order, before this event.
            flushPendingDown()
            onEvent?(me)
        }
    }
}
