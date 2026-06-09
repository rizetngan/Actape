import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject var hotkeys: HotkeyPreferences

    var body: some View {
        Form {
            Section {
                ShortcutRecorderRow(title: "Toggle recording", config: $hotkeys.record)
                ShortcutRecorderRow(title: "Toggle playback", config: $hotkeys.play)
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Text("These work system-wide, even when Macrobot isn’t focused. Function keys (F6, F7…) are recommended — a shortcut’s key won’t be captured while you record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { hotkeys.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 260)
    }
}

/// A row showing the current shortcut and a button that captures a new one by
/// listening for the next key press via a local event monitor.
private struct ShortcutRecorderRow: View {
    let title: String
    @Binding var config: HotkeyConfig

    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                listening ? stop() : start()
            } label: {
                Text(listening ? "Press a shortcut…" : config.displayString)
                    .frame(minWidth: 130)
                    .foregroundStyle(listening ? Color.accentColor : .primary)
            }
            .buttonStyle(.bordered)
            .help("Click, then press the key combination you want.")
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc with no modifiers cancels without rebinding.
            if event.keyCode == UInt16(kVK_Escape),
               HotkeyPreferences.carbonModifiers(from: event.modifierFlags) == 0 {
                stop()
                return nil
            }
            config = HotkeyConfig(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: HotkeyPreferences.carbonModifiers(from: event.modifierFlags)
            )
            stop()
            return nil   // swallow so the keypress doesn't leak to the UI
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        listening = false
    }
}
