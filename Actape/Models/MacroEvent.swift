import Foundation
import CoreGraphics

enum MouseButton: Int, Codable, Hashable, CaseIterable {
    case left = 0
    case right = 1
    case other = 2

    nonisolated var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .other: return .center
        }
    }

    var displayName: String {
        switch self {
        case .left: return "左键"
        case .right: return "右键"
        case .other: return "中键"
        }
    }
}

enum MacroEventKind: String, Codable, CaseIterable, Hashable {
    case click          // full press + release at a point (the default recorded mouse action)
    case mouseDown
    case mouseUp
    case mouseDrag
    case mouseMove
    case keyDown
    case keyUp
    case keyCombo
    case flagsChanged
    case scroll
    case typeText

    var displayName: String {
        switch self {
        case .click: return "点击"
        case .mouseDown: return "鼠标按下"
        case .mouseUp: return "鼠标松开"
        case .mouseDrag: return "鼠标拖动"
        case .mouseMove: return "鼠标移动"
        case .keyDown: return "按键按下"
        case .keyUp: return "按键松开"
        case .keyCombo: return "键盘按键"
        case .flagsChanged: return "修饰键"
        case .scroll: return "滚动"
        case .typeText: return "输入文本"
        }
    }

    var sfSymbol: String {
        switch self {
        case .click: return "cursorarrow.click.badge.clock"
        case .mouseDown, .mouseUp: return "cursorarrow.click"
        case .mouseDrag: return "cursorarrow.motionlines"
        case .mouseMove: return "arrow.up.and.down.and.arrow.left.and.right"
        case .keyDown, .keyUp, .keyCombo: return "keyboard"
        case .flagsChanged: return "command"
        case .scroll: return "arrow.up.and.down.circle"
        case .typeText: return "character.cursor.ibeam"
        }
    }

    nonisolated var isMouse: Bool {
        switch self {
        case .click, .mouseDown, .mouseUp, .mouseDrag, .mouseMove: return true
        default: return false
        }
    }

    var isKeyboard: Bool {
        switch self {
        case .keyDown, .keyUp, .keyCombo, .flagsChanged: return true
        default: return false
        }
    }
}

/// How a programmable `typeText` step turns its per-iteration counter into text.
/// The counter is `start + step * iteration`, where `iteration` is how many times
/// the step has already fired this playback (so it advances once per macro repeat).
enum SequenceFormat: String, Codable, CaseIterable, Hashable {
    case none       // no counter — type the template literally
    case number     // integer, zero-padded to `seqPad` digits
    case timeHHMM   // counter is minutes-since-midnight → "HHMM" (e.g. 0,15,30 → 0000,0015,0030)
    case timeColon  // same, but "HH:MM"

    var displayName: String {
        switch self {
        case .none: return "固定文本"
        case .number: return "数字递增"
        case .timeHHMM: return "24 小时（HHMM）"
        case .timeColon: return "24 小时（HH:MM）"
        }
    }

    nonisolated var isTime: Bool { self == .timeHHMM || self == .timeColon }
}

struct MacroEvent: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var delayMs: Int = 0
    var kind: MacroEventKind = .mouseDown

    // Mouse fields
    var x: Double = 0
    var y: Double = 0
    var button: MouseButton = .left
    var clickCount: Int = 1

    // Keyboard fields
    var keyCode: UInt16 = 0
    var modifierFlags: UInt64 = 0

    // Scroll fields
    var scrollDeltaX: Double = 0
    var scrollDeltaY: Double = 0

    // Programmable "type text" fields
    /// Template typed each iteration. `{n}` is replaced by the formatted counter.
    /// If empty, the formatted counter alone is typed.
    var text: String = ""
    var seqFormat: SequenceFormat = .none
    var seqStart: Int = 0
    var seqStep: Int = 1
    var seqPad: Int = 4
    /// When set on a time sequence, the whole run halts once the counter reaches
    /// this time-of-day (minutes since midnight). Wraps correctly past 23:59.
    var seqStopEnabled: Bool = false
    var seqStop: Int = 0

    init() {}

    // MARK: Codable (hand-rolled so adding fields never breaks older saved macros)

    private enum CodingKeys: String, CodingKey {
        case id, delayMs, kind, x, y, button, clickCount, keyCode, modifierFlags
        case scrollDeltaX, scrollDeltaY, text, seqFormat, seqStart, seqStep, seqPad
        case seqStopEnabled, seqStop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        delayMs       = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
        kind          = try c.decodeIfPresent(MacroEventKind.self, forKey: .kind) ?? .mouseDown
        x             = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y             = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        button        = try c.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left
        clickCount    = try c.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1
        keyCode       = try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? 0
        modifierFlags = try c.decodeIfPresent(UInt64.self, forKey: .modifierFlags) ?? 0
        scrollDeltaX  = try c.decodeIfPresent(Double.self, forKey: .scrollDeltaX) ?? 0
        scrollDeltaY  = try c.decodeIfPresent(Double.self, forKey: .scrollDeltaY) ?? 0
        text          = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        seqFormat     = try c.decodeIfPresent(SequenceFormat.self, forKey: .seqFormat) ?? .none
        seqStart      = try c.decodeIfPresent(Int.self, forKey: .seqStart) ?? 0
        seqStep       = try c.decodeIfPresent(Int.self, forKey: .seqStep) ?? 1
        seqPad        = try c.decodeIfPresent(Int.self, forKey: .seqPad) ?? 4
        seqStopEnabled = try c.decodeIfPresent(Bool.self, forKey: .seqStopEnabled) ?? false
        seqStop       = try c.decodeIfPresent(Int.self, forKey: .seqStop) ?? 0
    }

    // MARK: Programmable text

    /// The text this step types on a given 0-based iteration.
    nonisolated func renderedText(iteration: Int) -> String {
        let token = seqFormat == .none ? "" : sequenceToken(iteration: iteration)
        let template: String
        if text.isEmpty {
            template = token
        } else if text.contains("{n}") {
            template = text.replacingOccurrences(of: "{n}", with: token)
        } else {
            template = text
        }
        return Self.unescape(template)
    }

    /// Interprets backslash escapes a user can type in the template field.
    nonisolated private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var iter = s.makeIterator()
        while let c = iter.next() {
            if c == "\\", let next = iter.next() {
                switch next {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "\\": out.append("\\")
                default: out.append(c); out.append(next)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// For a stop-enabled time sequence, decide — for a given 0-based iteration —
    /// whether to type this value and whether to halt the whole run afterwards.
    /// Handles wrapping across midnight (e.g. start 23:00, step 15, stop 01:00).
    /// Returns `(type: true, halt: false)` whenever a stop doesn't apply.
    nonisolated func sequenceStopDecision(iteration: Int) -> (type: Bool, halt: Bool) {
        guard kind == .typeText, seqStopEnabled, seqFormat.isTime, seqStep != 0 else {
            return (true, false)
        }
        let startTod = ((seqStart % 1440) + 1440) % 1440
        let stopTod  = ((seqStop  % 1440) + 1440) % 1440
        // Distance from start to stop, travelling in the step's direction, in 1...1440.
        var delta = (seqStep > 0) ? (stopTod - startTod) : (startTod - stopTod)
        delta = ((delta % 1440) + 1440) % 1440
        if delta == 0 { delta = 1440 }                  // start == stop ⇒ run one full day
        let progress = abs(seqStep) * iteration
        if progress < delta  { return (true, false) }
        if progress == delta { return (true, true) }    // lands exactly on stop: type it, then halt
        return (false, true)                            // would overshoot: halt before passing it
    }

    nonisolated private func sequenceToken(iteration: Int) -> String {
        let value = seqStart + seqStep * iteration
        switch seqFormat {
        case .none:
            return ""
        case .number:
            let negative = value < 0
            var digits = String(abs(value))
            if digits.count < seqPad {
                digits = String(repeating: "0", count: seqPad - digits.count) + digits
            }
            return (negative ? "-" : "") + digits
        case .timeHHMM, .timeColon:
            let mins = ((value % 1440) + 1440) % 1440   // wrap into a single 24h day
            let sep = seqFormat == .timeColon ? ":" : ""
            return String(format: "%02d\(sep)%02d", mins / 60, mins % 60)
        }
    }

    var summary: String {
        switch kind {
        case .click:
            return "\(button.displayName)点击 (\(Int(x)), \(Int(y)))" +
                (clickCount > 1 ? " ×\(clickCount)" : "")
        case .mouseDown:
            return "\(button.displayName)按下 (\(Int(x)), \(Int(y)))" +
                (clickCount > 1 ? " ×\(clickCount)" : "")
        case .mouseUp:
            return "\(button.displayName)松开 (\(Int(x)), \(Int(y)))"
        case .mouseDrag:
            return "\(button.displayName)拖动至 (\(Int(x)), \(Int(y)))"
        case .mouseMove:
            return "移动至 (\(Int(x)), \(Int(y)))"
        case .keyDown:
            return "按下：\(KeyCodeNames.label(for: keyCode, modifiers: modifierFlags))"
        case .keyUp:
            return "松开：\(KeyCodeNames.label(for: keyCode, modifiers: modifierFlags))"
        case .keyCombo:
            return "按键：\(KeyCodeNames.label(for: keyCode, modifiers: modifierFlags)) · 原坐标 (\(Int(x)), \(Int(y)))"
        case .flagsChanged:
            return "修饰键：\(KeyCodeNames.modifierLabel(for: modifierFlags))"
        case .scroll:
            return "滚动 Δ(\(Int(scrollDeltaX)), \(Int(scrollDeltaY)))"
        case .typeText:
            let first = renderedText(iteration: 0)
            let preview = first.replacingOccurrences(of: "\n", with: "⏎")
                               .replacingOccurrences(of: "\t", with: "⇥")
            if seqFormat == .none {
                return "输入：“\(preview)”"
            }
            let next = renderedText(iteration: 1)
                .replacingOccurrences(of: "\n", with: "⏎")
                .replacingOccurrences(of: "\t", with: "⇥")
            return "输入：“\(preview)” → “\(next)” …"
        }
    }
}
