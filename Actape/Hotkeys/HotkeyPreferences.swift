import Foundation
import AppKit
import Carbon.HIToolbox
import Combine

/// A single global shortcut: a virtual key code plus Carbon modifier mask
/// (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`) as required by
/// `RegisterEventHotKey`.
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Human-readable form like "F6" or "⌘⇧R".
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += KeyCodeNames.keyLabel(for: UInt16(keyCode))
        return s
    }
}

/// Persisted, observable global-shortcut settings. Changes are saved to
/// `UserDefaults` and observed by the app to re-register the Carbon hotkeys
/// and update which keycodes the recorder filters out.
@MainActor
final class HotkeyPreferences: ObservableObject {
    @Published var record: HotkeyConfig { didSet { save() } }
    @Published var play: HotkeyConfig { didSet { save() } }

    static let defaultRecord = HotkeyConfig(keyCode: UInt32(kVK_F6), carbonModifiers: 0)
    static let defaultPlay   = HotkeyConfig(keyCode: UInt32(kVK_F7), carbonModifiers: 0)

    private static let recordKey = "hotkey.record"
    private static let playKey   = "hotkey.play"

    init() {
        let defaults = UserDefaults.standard
        record = Self.load(Self.recordKey, fallback: Self.defaultRecord, from: defaults)
        play   = Self.load(Self.playKey,   fallback: Self.defaultPlay,   from: defaults)
    }

    /// Keycodes that the recorder must ignore so toggling record/play doesn't
    /// pollute the recording.
    var blockedKeyCodes: Set<UInt16> {
        [UInt16(record.keyCode), UInt16(play.keyCode)]
    }

    func resetToDefaults() {
        record = Self.defaultRecord
        play = Self.defaultPlay
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(record) { d.set(data, forKey: Self.recordKey) }
        if let data = try? JSONEncoder().encode(play)   { d.set(data, forKey: Self.playKey) }
    }

    private static func load(_ key: String, fallback: HotkeyConfig, from d: UserDefaults) -> HotkeyConfig {
        guard let data = d.data(forKey: key),
              let cfg = try? JSONDecoder().decode(HotkeyConfig.self, from: data) else {
            return fallback
        }
        return cfg
    }

    /// Maps the Cocoa modifier flags from an `NSEvent` to a Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}
