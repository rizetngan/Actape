import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var store: MacroStore
    @EnvironmentObject var hotkeys: HotkeyPreferences
    @State private var showingAccessibilityBanner: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            // Status bar lives at the bottom of the detail pane (under the steps
            // and their actions), per the macOS Tahoe layout — it spans the right
            // column only and leaves the sidebar's own bottom bar untouched.
            VStack(spacing: 0) {
                detail
                statusBar
            }
        }
        .toolbar { toolbarContent }
        .frame(minWidth: 880, minHeight: 540)
        .safeAreaInset(edge: .top) {
            if showingAccessibilityBanner {
                AccessibilityBanner {
                    AccessibilityHelper.openSystemSettings()
                }
            }
        }
        .onAppear {
            showingAccessibilityBanner = !AccessibilityHelper.isTrusted(prompt: false)
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            showingAccessibilityBanner = !AccessibilityHelper.isTrusted(prompt: false)
        }
    }

    // MARK: Status bar (window-wide, bottom)

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: store.isRecording ? "record.circle.fill" :
                                  store.isPlaying ? "play.circle.fill" : "checkmark.circle")
                    .foregroundStyle(store.isRecording ? .red :
                                     store.isPlaying ? .green : .secondary)
                Text(store.statusMessage)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)

                Spacer()

                if let p = store.playbackProgress, store.isPlaying {
                    let total = store.selectedMacro?.repeatCount ?? 0
                    let loop = total == 0 ? "Loop \(p.rep) · ∞" : "Loop \(p.rep)/\(total)"
                    Text("\(loop) · step \(p.step)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(height: 26)
            .background(.bar)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedMacroId) {
                ForEach(store.macros) { macro in
                    MacroRow(macro: macro, isPlayingTarget: store.isPlaying && store.selectedMacroId == macro.id)
                        .tag(macro.id)
                        .contextMenu {
                            Button("Rename") { renameMacroId = macro.id; renameText = macro.name }
                            Button("Duplicate") { store.duplicateMacro(id: macro.id) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.deleteMacro(id: macro.id)
                            }
                        }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.macros[$0].id }
                    for id in ids { store.deleteMacro(id: id) }
                }
            }
            .listStyle(.sidebar)
            .alert("Rename macro", isPresented: Binding(
                get: { renameMacroId != nil },
                set: { if !$0 { renameMacroId = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let id = renameMacroId { store.renameMacro(id: id, to: renameText) }
                    renameMacroId = nil
                }
                Button("Cancel", role: .cancel) { renameMacroId = nil }
            }

            Divider()

            HStack {
                Button {
                    store.addMacro()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New macro")

                Button {
                    if let id = store.selectedMacroId {
                        store.deleteMacro(id: id)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(store.selectedMacroId == nil)
                .help("Delete macro")

                Spacer()

                Text(store.macros.count == 1 ? "1 macro" : "\(store.macros.count) macros")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    @State private var renameMacroId: UUID?
    @State private var renameText: String = ""

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let id = store.selectedMacroId, let macroBinding = store.binding(for: id) {
            MacroDetailView(macro: macroBinding)
                .id(id)
        } else {
            ContentUnavailableView {
                Label("No Macro Selected", systemImage: "wand.and.rays")
            } description: {
                Text("Create a new macro from the sidebar, then press \(Image(systemName: "record.circle")) to record.")
            } actions: {
                Button("New Macro") { store.addMacro() }
                    .controlSize(.large)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.toggleRecording()
            } label: {
                Label(store.isRecording ? "Stop Recording" : "Record",
                      systemImage: store.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(store.isRecording ? .red : nil)
            .disabled(store.isPlaying)
            .help("Toggle recording (\(hotkeys.record.displayString))")

            Button {
                store.togglePlayback()
            } label: {
                Label(store.isPlaying ? "Stop" : "Play",
                      systemImage: store.isPlaying ? "stop.fill" : "play.fill")
            }
            .tint(store.isPlaying ? .green : nil)
            .disabled((store.selectedMacro?.events.isEmpty ?? true) || store.isRecording)
            .help("Toggle playback (\(hotkeys.play.displayString))")
        }
    }
}

private struct MacroRow: View {
    let macro: Macro
    let isPlayingTarget: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isPlayingTarget ? "play.circle.fill" : "list.bullet.rectangle")
                .foregroundStyle(isPlayingTarget ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(macro.name).font(.body)
                Text("\(macro.events.count) events · \(formatted(ms: macro.totalDurationMs))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatted(ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        let s = Double(ms) / 1000
        return String(format: "%.1f s", s)
    }
}

private struct AccessibilityBanner: View {
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility access is required").font(.headline)
                Text("Macrobot needs Accessibility permission to record and replay events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings", action: onOpen)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.yellow.opacity(0.18))
    }
}

#Preview {
    ContentView()
        .environmentObject(MacroStore())
        .environmentObject(HotkeyPreferences())
}
