import SwiftUI
import Carbon.HIToolbox

@main
struct ActapeApp: App {
    @StateObject private var store = MacroStore()
    @StateObject private var hotkeys = HotkeyPreferences()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(hotkeys)
                .onAppear { applyHotkeys() }
                .onChange(of: hotkeys.record) { applyHotkeys() }
                .onChange(of: hotkeys.play) { applyHotkeys() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建宏") { store.addMacro() }
                    .keyboardShortcut("n", modifiers: [.command])
                Divider()
                Button("导入宏…") { store.importFromFile() }
                    .keyboardShortcut("o", modifiers: [.command])
                Menu("导出") {
                    Button("导出当前宏…") {
                        if let m = store.selectedMacro {
                            store.exportToFile([m], suggestedName: m.name)
                        }
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.selectedMacro == nil)

                    Button("导出全部宏…") {
                        store.exportToFile(store.macros, suggestedName: "全部宏")
                    }
                    .disabled(store.macros.isEmpty)
                }
            }
            CommandMenu("宏") {
                Button(store.isRecording ? "结束录制" : "开始录制") {
                    store.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button(store.isPlaying ? "停止执行" : "执行宏") {
                    store.togglePlayback()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(store.selectedMacro?.events.isEmpty ?? true)

                Divider()

                Button("打开系统权限设置…") {
                    AccessibilityHelper.openSystemSettings()
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(hotkeys)
        }
    }

    /// (Re)registers the configurable global shortcuts and keeps the recorder
    /// from capturing them. Safe to call repeatedly — it replaces all bindings.
    @MainActor
    private func applyHotkeys() {
        HotkeyManager.shared.setBindings([
            (hotkeys.record.keyCode, hotkeys.record.carbonModifiers, { store.toggleRecording() }),
            (hotkeys.play.keyCode,   hotkeys.play.carbonModifiers,   { store.togglePlayback() }),
        ])
        store.setBlockedKeyCodes(hotkeys.blockedKeyCodes)
    }
}
