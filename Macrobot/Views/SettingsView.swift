import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject var hotkeys: HotkeyPreferences

    var body: some View {
        Form {
            Section {
                ShortcutRecorderRow(title: "录制 / 停止录制", config: $hotkeys.record)
                ShortcutRecorderRow(title: "执行 / 停止执行", config: $hotkeys.play)
            } header: {
                Text("全局快捷键")
            } footer: {
                Text("即使窗口未激活也能使用，建议设置 F6、F7 等功能键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("恢复默认设置") { hotkeys.resetToDefaults() }
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
                Text(listening ? "请按快捷键…" : config.displayString)
                    .frame(minWidth: 130)
                    .foregroundStyle(listening ? Color.accentColor : .primary)
            }
            .buttonStyle(.bordered)
            .help("点击后直接按下要设置的快捷键，按 Esc 取消。")
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
