import Foundation

struct Macro: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var events: [MacroEvent] = []
    var repeatCount: Int = 1   // 0 means infinite
    var playbackSpeed: Double = 1.0
    var createdAt: Date = Date()

    var totalDurationMs: Int {
        events.reduce(0) { $0 + max(0, $1.delayMs) }
    }
}
