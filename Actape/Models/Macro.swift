import Foundation

struct Macro: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var events: [MacroEvent] = []
    var repeatCount: Int = 1   // 0 means infinite
    var playbackSpeed: Double = 1.0
    /// macOS CGEvent button number (usually 3/4 for side buttons).
    /// Optional so macros saved by the upstream app still decode unchanged.
    var triggerButton: Int? = nil
    /// Additional optional fields retain compatibility with older JSON exports.
    var triggerKeyCode: UInt16? = nil
    var triggerModifierFlags: UInt64? = nil
    var triggerHold: Bool? = nil

    var triggerDisplay: String {
        if let code = triggerKeyCode {
            return KeyCodeNames.label(for: code, modifiers: triggerModifierFlags ?? 0)
        }
        return triggerButton.map { "侧键 \($0)" } ?? "未绑定"
    }
    var createdAt: Date = Date()

    var totalDurationMs: Int {
        events.reduce(0) { $0 + max(0, $1.delayMs) }
    }
}
