import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacroStore: ObservableObject {
    @Published var macros: [Macro] = []
    @Published var selectedMacroId: UUID?
    @Published var isRecording: Bool = false
    @Published var isPlaying: Bool = false
    @Published var statusMessage: String = "Ready"
    @Published var playbackProgress: (rep: Int, step: Int)?

    private let recorder = EventRecorder()
    private let player = EventPlayer()
    private let storageURL: URL
    private var saveDebounce: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Macrobot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("macros.json")
        load()
        if selectedMacroId == nil {
            selectedMacroId = macros.first?.id
        }
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        if let decoded = try? JSONDecoder().decode([Macro].self, from: data) {
            macros = decoded
        }
    }

    func save() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(macros)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveDebounce?.cancel()
        saveDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            self?.save()
        }
    }

    // MARK: - Import / Export

    /// Prompts for a destination and writes the given macros as a `.json` file.
    func exportToFile(_ macrosToExport: [Macro], suggestedName: String) {
        guard !macrosToExport.isEmpty else {
            statusMessage = "Nothing to export."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName.hasSuffix(".json") ? suggestedName : "\(suggestedName).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(macrosToExport).write(to: url, options: .atomic)
            let n = macrosToExport.count
            statusMessage = "Exported \(n) \(n == 1 ? "macro" : "macros") to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Prompts for a `.json` file and appends its macros (with fresh IDs).
    func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let dec = JSONDecoder()
            // Accept either an array of macros or a single macro.
            let imported: [Macro]
            if let many = try? dec.decode([Macro].self, from: data) {
                imported = many
            } else {
                imported = [try dec.decode(Macro.self, from: data)]
            }
            guard !imported.isEmpty else {
                statusMessage = "No macros found in \(url.lastPathComponent)."
                return
            }
            let fresh = imported.map { m -> Macro in
                var copy = m
                copy.id = UUID()
                copy.events = m.events.map { e in var ev = e; ev.id = UUID(); return ev }
                return copy
            }
            macros.append(contentsOf: fresh)
            selectedMacroId = fresh.first?.id
            scheduleSave()
            statusMessage = "Imported \(fresh.count) \(fresh.count == 1 ? "macro" : "macros") from \(url.lastPathComponent)."
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Macro CRUD

    var selectedMacro: Macro? {
        guard let id = selectedMacroId else { return nil }
        return macros.first(where: { $0.id == id })
    }

    func binding(for id: UUID) -> Binding<Macro>? {
        guard macros.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.macros.first(where: { $0.id == id }) ?? Macro(name: "") },
            set: { newValue in
                if let i = self.macros.firstIndex(where: { $0.id == id }) {
                    self.macros[i] = newValue
                    self.scheduleSave()
                }
            }
        )
    }

    func addMacro() {
        let newMacro = Macro(name: "Macro \(macros.count + 1)")
        macros.append(newMacro)
        selectedMacroId = newMacro.id
        scheduleSave()
    }

    func deleteMacro(id: UUID) {
        macros.removeAll { $0.id == id }
        if selectedMacroId == id {
            selectedMacroId = macros.first?.id
        }
        scheduleSave()
    }

    func duplicateMacro(id: UUID) {
        guard let original = macros.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) Copy"
        copy.events = original.events.map { evt in
            var e = evt
            e.id = UUID()
            return e
        }
        macros.append(copy)
        selectedMacroId = copy.id
        scheduleSave()
    }

    func renameMacro(id: UUID, to name: String) {
        guard let idx = macros.firstIndex(where: { $0.id == id }) else { return }
        macros[idx].name = name
        scheduleSave()
    }

    // MARK: - Event editing

    func updateEvent(macroId: UUID, event: MacroEvent) {
        guard let mIdx = macros.firstIndex(where: { $0.id == macroId }),
              let eIdx = macros[mIdx].events.firstIndex(where: { $0.id == event.id })
        else { return }
        macros[mIdx].events[eIdx] = event
        scheduleSave()
    }

    func deleteEvents(macroId: UUID, ids: Set<UUID>) {
        guard let mIdx = macros.firstIndex(where: { $0.id == macroId }) else { return }
        macros[mIdx].events.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func moveEvents(macroId: UUID, fromOffsets: IndexSet, toOffset: Int) {
        guard let mIdx = macros.firstIndex(where: { $0.id == macroId }) else { return }
        macros[mIdx].events.move(fromOffsets: fromOffsets, toOffset: toOffset)
        scheduleSave()
    }

    func addBlankEvent(macroId: UUID) {
        guard let mIdx = macros.firstIndex(where: { $0.id == macroId }) else { return }
        var e = MacroEvent()
        e.kind = .click
        e.delayMs = 200
        e.x = 100
        e.y = 100
        macros[mIdx].events.append(e)
        scheduleSave()
    }

    // MARK: - Recording

    /// Keep the recorder from capturing the global toggle shortcuts.
    func setBlockedKeyCodes(_ codes: Set<UInt16>) {
        recorder.blockedKeyCodes = codes
    }

    func startRecording(intoNewMacro: Bool = true) {
        guard !isRecording, !isPlaying else { return }

        if !AccessibilityHelper.isTrusted(prompt: false) {
            statusMessage = "Accessibility permission required. Click the banner to grant access."
            _ = AccessibilityHelper.isTrusted(prompt: true)
            return
        }

        if intoNewMacro || selectedMacro == nil {
            addMacro()
        }

        guard let macroId = selectedMacroId else { return }

        // Clear events when recording into the selected macro? We append.
        let started = recorder.start { [weak self] event in
            guard let self = self else { return }
            guard let idx = self.macros.firstIndex(where: { $0.id == macroId }) else { return }
            self.macros[idx].events.append(event)
        }

        if started {
            isRecording = true
            statusMessage = "Recording… press F6 to stop."
        } else {
            statusMessage = "Failed to start event tap. Grant Accessibility access."
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recorder.stop()
        isRecording = false
        statusMessage = "Stopped. \(selectedMacro?.events.count ?? 0) events recorded."
        scheduleSave()
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    // MARK: - Playback

    func playSelected() {
        guard !isRecording else { return }
        guard let macro = selectedMacro, !macro.events.isEmpty else {
            statusMessage = "Nothing to play."
            return
        }
        if !AccessibilityHelper.isTrusted(prompt: false) {
            statusMessage = "Accessibility permission required for playback."
            _ = AccessibilityHelper.isTrusted(prompt: true)
            return
        }
        if isPlaying { player.cancel(); return }

        isPlaying = true
        playbackProgress = (1, 0)
        statusMessage = "Playing \(macro.name)…"

        player.play(macro: macro,
                    onProgress: { [weak self] rep, step in
                        self?.playbackProgress = (rep, step)
                    },
                    onFinish: { [weak self] cancelled in
                        guard let self = self else { return }
                        self.isPlaying = false
                        self.playbackProgress = nil
                        self.statusMessage = cancelled ? "Playback stopped." : "Playback finished."
                    })
    }

    func stopPlayback() {
        guard isPlaying else { return }
        player.cancel()
        isPlaying = false
        playbackProgress = nil
        statusMessage = "Playback stopped."
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            playSelected()
        }
    }
}
