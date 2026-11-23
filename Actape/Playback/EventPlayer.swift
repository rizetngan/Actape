import Foundation
import AppKit
import CoreGraphics

@MainActor
final class EventPlayer {
    private var task: Task<Void, Never>?
    private(set) var isPlaying: Bool = false

    /// How long a `.click` step holds the button down before releasing, in
    /// microseconds. Deliberately a small fixed value that is **not** scaled by
    /// `playbackSpeed`: a click should always release promptly, even when the
    /// macro is played back slowly. Long enough for any target to register the press.
    nonisolated private static let clickHoldMicros: useconds_t = 30_000

    func play(macro: Macro,
              onProgress: @escaping (Int, Int) -> Void,
              onFinish: @escaping (_ cancelled: Bool) -> Void) {
        cancel()

        let events = macro.events
        let speed = max(0.05, macro.playbackSpeed)
        let totalReps = macro.repeatCount <= 0 ? Int.max : macro.repeatCount

        guard !events.isEmpty else {
            onFinish(false)
            return
        }

        isPlaying = true

        task = Task.detached(priority: .userInitiated) { [weak self] in
            let totalEvents = events.count
            // Per-step counter for programmable `typeText` steps: how many times each
            // step has fired so far this playback. Advances once per macro repetition.
            var iterations: [UUID: Int] = [:]
            // Last point a mouse event left the cursor at, so a `.mouseDrag` can
            // synthesize intermediate movement when it jumps a long distance.
            var lastMousePoint: CGPoint?

            outer: for repIdx in 0..<totalReps {
                if Task.isCancelled { break }
                for (i, event) in events.enumerated() {
                    if Task.isCancelled { break outer }
                    let scaledMs = Double(max(0, event.delayMs)) / speed
                    if scaledMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(scaledMs * 1_000_000))
                    }
                    if Task.isCancelled { break outer }
                    let iteration = iterations[event.id, default: 0]
                    iterations[event.id] = iteration + 1
                    let decision = event.sequenceStopDecision(iteration: iteration)
                    if decision.type {
                        if let landed = Self.post(event: event, iteration: iteration,
                                                  previousPoint: lastMousePoint) {
                            lastMousePoint = landed
                        }
                    }

                    let displayedIndex = i + 1
                    let displayedRep = repIdx + 1
                    await MainActor.run { onProgress(displayedRep, displayedIndex) }
                    _ = totalEvents

                    // A typeText step can halt the whole run when its sequence
                    // reaches the configured stop timestamp.
                    if decision.halt { break outer }
                }
            }

            let cancelled = Task.isCancelled
            await MainActor.run {
                self?.isPlaying = false
                self?.task = nil
                onFinish(cancelled)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isPlaying = false
    }

    /// Posts one macro event. Returns the cursor position it left the pointer at
    /// (for mouse events), or `nil` if the event doesn't move the cursor — the
    /// caller threads this back in as `previousPoint` so a long drag jump can be
    /// broken into intermediate movement.
    @discardableResult
    nonisolated private static func post(event me: MacroEvent, iteration: Int = 0,
                                         previousPoint: CGPoint? = nil) -> CGPoint? {
        let source = CGEventSource(stateID: .hidSystemState)
        let pt = CGPoint(x: me.x, y: me.y)

        switch me.kind {
        case .click:
            // Press + release at the same point. The hold is a small fixed delay
            // (NOT scaled by playbackSpeed) so a click never gets "stuck down"
            // when the macro is slowed down.
            let downType: CGEventType
            let upType: CGEventType
            switch me.button {
            case .left:  downType = .leftMouseDown;  upType = .leftMouseUp
            case .right: downType = .rightMouseDown; upType = .rightMouseUp
            case .other: downType = .otherMouseDown; upType = .otherMouseUp
            }
            let clickState = Int64(max(1, me.clickCount))
            if let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                  mouseCursorPosition: pt, mouseButton: me.button.cgButton) {
                down.setIntegerValueField(.mouseEventClickState, value: clickState)
                down.post(tap: .cghidEventTap)
            }
            usleep(clickHoldMicros)
            if let up = CGEvent(mouseEventSource: source, mouseType: upType,
                                mouseCursorPosition: pt, mouseButton: me.button.cgButton) {
                up.setIntegerValueField(.mouseEventClickState, value: clickState)
                up.post(tap: .cghidEventTap)
            }

        case .mouseDown:
            let cgType: CGEventType = {
                switch me.button {
                case .left: return .leftMouseDown
                case .right: return .rightMouseDown
                case .other: return .otherMouseDown
                }
            }()
            if let evt = CGEvent(mouseEventSource: source,
                                  mouseType: cgType,
                                  mouseCursorPosition: pt,
                                  mouseButton: me.button.cgButton) {
                evt.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, me.clickCount)))
                evt.post(tap: .cghidEventTap)
            }

        case .mouseUp:
            let cgType: CGEventType = {
                switch me.button {
                case .left: return .leftMouseUp
                case .right: return .rightMouseUp
                case .other: return .otherMouseUp
                }
            }()
            if let evt = CGEvent(mouseEventSource: source,
                                  mouseType: cgType,
                                  mouseCursorPosition: pt,
                                  mouseButton: me.button.cgButton) {
                evt.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, me.clickCount)))
                evt.post(tap: .cghidEventTap)
            }

        case .mouseDrag:
            // Recorded drags arrive as dense samples (each only a few px apart),
            // so this is a single post. A synthesized/authored drag that jumps a
            // long way is broken into intermediate moves so apps that need
            // movement to recognize a drag (sliders, reordering, drawing) work.
            postDrag(to: pt, from: previousPoint, button: me.button, source: source)

        case .mouseMove:
            if let evt = CGEvent(mouseEventSource: source,
                                  mouseType: .mouseMoved,
                                  mouseCursorPosition: pt,
                                  mouseButton: .left) {
                evt.post(tap: .cghidEventTap)
            }

        case .keyDown:
            if let evt = CGEvent(keyboardEventSource: source,
                                  virtualKey: me.keyCode,
                                  keyDown: true) {
                evt.flags = CGEventFlags(rawValue: me.modifierFlags)
                evt.post(tap: .cghidEventTap)
            }

        case .keyUp:
            if let evt = CGEvent(keyboardEventSource: source,
                                  virtualKey: me.keyCode,
                                  keyDown: false) {
                evt.flags = CGEventFlags(rawValue: me.modifierFlags)
                evt.post(tap: .cghidEventTap)
            }

        case .keyCombo:
            // Single, balanced keypress with modifier flags.  Coordinates remain
            // stored for later switching back to a mouse click, but are not clicked.
            if let down = CGEvent(keyboardEventSource: source,
                                  virtualKey: me.keyCode, keyDown: true),
               let up = CGEvent(keyboardEventSource: source,
                                virtualKey: me.keyCode, keyDown: false) {
                let flags = CGEventFlags(rawValue: me.modifierFlags)
                down.flags = flags
                up.flags = flags
                down.post(tap: .cghidEventTap)
                usleep(40_000)
                up.post(tap: .cghidEventTap)
            }

        case .flagsChanged:
            if let evt = CGEvent(keyboardEventSource: source,
                                  virtualKey: me.keyCode,
                                  keyDown: true) {
                evt.type = .flagsChanged
                evt.flags = CGEventFlags(rawValue: me.modifierFlags)
                evt.post(tap: .cghidEventTap)
            }

        case .scroll:
            if let evt = CGEvent(scrollWheelEvent2Source: source,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(me.scrollDeltaY),
                                  wheel2: Int32(me.scrollDeltaX),
                                  wheel3: 0) {
                evt.post(tap: .cghidEventTap)
            }

        case .typeText:
            let string = me.renderedText(iteration: iteration)
            for ch in string {
                Self.postCharacter(ch, source: source)
                // Tiny gap so fast targets don't drop characters.
                usleep(2_000)
            }
        }

        // Mouse events leave the cursor at `pt`; everything else leaves it put.
        return me.kind.isMouse ? pt : nil
    }

    /// Largest straight-line gap (in points) a single drag step covers before it
    /// is broken into intermediate `mouseDragged` events.
    nonisolated private static let dragStepPx: Double = 24
    nonisolated private static let dragStepMicros: useconds_t = 6_000

    /// Posts a drag to `target`. If `previous` is known and far away, walks there
    /// in `dragStepPx`-sized steps so the motion actually registers; otherwise a
    /// single dragged event (the normal case for dense recorded samples).
    nonisolated private static func postDrag(to target: CGPoint, from previous: CGPoint?,
                                             button: MouseButton, source: CGEventSource?) {
        let dragType: CGEventType
        switch button {
        case .left:  dragType = .leftMouseDragged
        case .right: dragType = .rightMouseDragged
        case .other: dragType = .otherMouseDragged
        }
        func emit(_ p: CGPoint) {
            if let evt = CGEvent(mouseEventSource: source, mouseType: dragType,
                                 mouseCursorPosition: p, mouseButton: button.cgButton) {
                evt.post(tap: .cghidEventTap)
            }
        }
        guard let prev = previous else { emit(target); return }
        let dx = target.x - prev.x, dy = target.y - prev.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let steps = max(1, Int((distance / dragStepPx).rounded(.up)))
        if steps == 1 { emit(target); return }
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            emit(CGPoint(x: prev.x + dx * t, y: prev.y + dy * t))
            if i < steps { usleep(dragStepMicros) }
        }
    }

    /// Types a single character by attaching its unicode value to a synthetic key
    /// event. Layout-independent — works for digits, ":", letters, etc. without
    /// needing to map to a virtual keycode.
    nonisolated private static func postCharacter(_ ch: Character, source: CGEventSource?) {
        var utf16 = Array(String(ch).utf16)
        guard !utf16.isEmpty else { return }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.post(tap: .cghidEventTap)
        }
    }
}
