import SwiftUI
import Carbon.HIToolbox

@main
struct MacrobotApp: App {
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
                Button("New Macro") { store.addMacro() }
                    .keyboardShortcut("n", modifiers: [.command])
                Divider()
                Button("Import Macros…") { store.importFromFile() }
                    .keyboardShortcut("o", modifiers: [.command])
                Menu("Export") {
                    Button("Export Selected Macro…") {
                        if let m = store.selectedMacro {
                            store.exportToFile([m], suggestedName: m.name)
                        }
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.selectedMacro == nil)

                    Button("Export All Macros…") {
                        store.exportToFile(store.macros, suggestedName: "Macros")
                    }
                    .disabled(store.macros.isEmpty)
                }
            }
            CommandMenu("Macro") {
                Button(store.isRecording ? "Stop Recording" : "Start Recording") {
                    store.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button(store.isPlaying ? "Stop Playback" : "Play Macro") {
                    store.togglePlayback()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(store.selectedMacro?.events.isEmpty ?? true)

                Divider()

                Button("Open Accessibility Settings…") {
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
