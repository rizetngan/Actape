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
    @Published var statusMessage: String = "就绪"
    @Published var playbackProgress: (rep: Int, step: Int)?
    @Published var capturingTriggerFor: UUID?
    @Published var capturingActionFor: UUID?
    private var captureMouseDown: MacroEvent?
    private var captureDrag: MacroEvent?
    private var captureKeyDown: MacroEvent?
    private var activeHoldMacroID: UUID?
    private var blockedTriggerKeys: Set<UInt16> = []

    private let mouseButtons = MouseTriggerMonitor()
    private let recorder = EventRecorder()
    private let player = EventPlayer()
    private let storageURL: URL
    private var saveDebounce: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
        let isPreview = Bundle.main.bundleIdentifier == "com.rizetngan.actape.unified-preview"
        let dir = support.appendingPathComponent(
            isPreview ? "Actape-UnifiedInput-Preview" : "Actape", isDirectory: true)
        let legacyURL = support
            .appendingPathComponent(isPreview ? "Actape" : "Macrobot", isDirectory: true)
            .appendingPathComponent("macros.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("macros.json")

        // Preserve existing macros when upgrading from the previous product name.
        if !FileManager.default.fileExists(atPath: storageURL.path),
           FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.copyItem(at: legacyURL, to: storageURL)
        }
        load()
        if selectedMacroId == nil {
            selectedMacroId = macros.first?.id
        }

        mouseButtons.resolveMacro = { [weak self] input in
            self?.macros.first(where: { macro in
                switch input {
                case .mouse(let button):
                    return macro.triggerButton == button
                case .key(let key, let modifiers):
                    return macro.triggerKeyCode == key &&
                           (macro.triggerModifierFlags ?? 0) == modifiers
                }
            })?.id
        }
        mouseButtons.onCapture = { [weak self] id, input in
            Task { @MainActor [weak self] in self?.assignTrigger(input, to: id) }
        }
        mouseButtons.onTrigger = { [weak self] id, down in
            self?.triggerMacro(id, pressed: down)
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
            statusMessage = "保存失败：\(error.localizedDescription)"
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
            statusMessage = "没有可导出的宏。"
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
            statusMessage = "已导出 \(n) 个宏：\(url.lastPathComponent)"
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
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
                statusMessage = "文件中没有宏：\(url.lastPathComponent)"
                return
            }
            let fresh = imported.map { m -> Macro in
                var copy = m
                copy.id = UUID()
                // Imported macros must be rebound explicitly to avoid stealing a side button.
                copy.triggerButton = nil
                copy.triggerKeyCode = nil
                copy.triggerModifierFlags = nil
                copy.events = m.events.map { e in var ev = e; ev.id = UUID(); return ev }
                return copy
            }
            macros.append(contentsOf: fresh)
            selectedMacroId = fresh.first?.id
            scheduleSave()
            statusMessage = "已从 \(url.lastPathComponent) 导入 \(fresh.count) 个宏"
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
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
        let newMacro = Macro(name: "宏 \(macros.count + 1)")
        macros.append(newMacro)
        selectedMacroId = newMacro.id
        scheduleSave()
    }

    func deleteMacro(id: UUID) {
        if capturingTriggerFor == id { cancelTriggerCapture() }
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
        copy.name = "\(original.name) 副本"
        copy.triggerButton = nil
        copy.triggerKeyCode = nil
        copy.triggerModifierFlags = nil
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

    // MARK: - Unified mouse / keyboard macro triggers

    func ensureTriggerMonitor() {
        guard AccessibilityHelper.isTrusted(prompt: false) else { return }
        if !mouseButtons.start() {
            statusMessage = "无法启动全局输入监听，请检查设备控制和数据访问权限。"
        }
    }

    func beginTriggerCapture(for macroID: UUID) {
        guard macros.contains(where: { $0.id == macroID }) else { return }
        guard !isRecording, !isPlaying, capturingActionFor == nil else {
            statusMessage = "请先结束录制、步骤录入或执行。"
            return
        }
        guard AccessibilityHelper.isTrusted(prompt: false) else {
            _ = AccessibilityHelper.isTrusted(prompt: true)
            statusMessage = "请先授予输入控制权限。"
            return
        }
        guard mouseButtons.start() else {
            statusMessage = "无法检测鼠标或键盘输入。"
            return
        }
        capturingTriggerFor = macroID
        mouseButtons.captureNextButton(for: macroID)
        statusMessage = "请按鼠标侧键、单键或快捷键组合，Esc 取消。"
    }

    func cancelTriggerCapture() {
        capturingTriggerFor = nil
        mouseButtons.cancelCapture()
    }

    func clearTrigger(for macroID: UUID) {
        guard let index = macros.firstIndex(where: { $0.id == macroID }) else { return }
        macros[index].triggerButton = nil
        macros[index].triggerKeyCode = nil
        macros[index].triggerModifierFlags = nil
        cancelTriggerCapture()
        scheduleSave()
        statusMessage = "已清除触发键绑定。"
    }

    private func confirmBinding(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "触发键确认"
        alert.informativeText = text
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func assignTrigger(_ input: TriggerInput, to macroID: UUID) {
        guard let index = macros.firstIndex(where: { $0.id == macroID }) else { return }
        cancelTriggerCapture()
        if case .key(let code, _) = input {
            if code == 53 || blockedTriggerKeys.contains(code) {
                statusMessage = "该键已用于取消或全局录制快捷键，请换一个触发键。"
                return
            }
        }
        let conflict = macros.firstIndex(where: { i in
            guard i.id != macroID else { return false }
            switch input {
            case .mouse(let button): return i.triggerButton == button
            case .key(let code, let flags):
                return i.triggerKeyCode == code && (i.triggerModifierFlags ?? 0) == flags
            }
        })
        if let conflict, !confirmBinding(
            "该触发键已用于「\(macros[conflict].name)」，是否转移给「\(macros[index].name)」？"
        ) {
            statusMessage = "已保留原绑定。"
            return
        }
        if case .key(let code, let flags) = input, flags == 0 {
            let label = KeyCodeNames.label(for: code, modifiers: 0)
            if label.count == 1 && !confirmBinding(
                "普通单键设为全局触发后，正常输入该字符也会启动宏。仍要绑定吗？"
            ) {
                statusMessage = "已取消单键绑定。"
                return
            }
        }
        if let conflict {
            macros[conflict].triggerButton = nil
            macros[conflict].triggerKeyCode = nil
            macros[conflict].triggerModifierFlags = nil
        }
        switch input {
        case .mouse(let button):
            macros[index].triggerButton = button
            macros[index].triggerKeyCode = nil
            macros[index].triggerModifierFlags = nil
        case .key(let code, let flags):
            macros[index].triggerButton = nil
            macros[index].triggerKeyCode = code
            macros[index].triggerModifierFlags = flags
        }
        scheduleSave()
        statusMessage = "已绑定 \(macros[index].triggerDisplay) 至「\(macros[index].name)」。"
    }

    private func triggerMacro(_ macroID: UUID, pressed: Bool) {
        guard !isRecording, capturingTriggerFor == nil, capturingActionFor == nil else { return }
        if !pressed {
            if activeHoldMacroID == macroID {
                activeHoldMacroID = nil
                stopPlayback()
            }
            return
        }
        if isPlaying {
            stopPlayback()
            activeHoldMacroID = nil
            return
        }
        guard let macro = macros.first(where: { $0.id == macroID }),
              !macro.events.isEmpty else { return }
        selectedMacroId = macroID
        if macro.triggerHold == true {
            activeHoldMacroID = macroID
            var repeated = macro
            repeated.repeatCount = 0
            startPlayback(repeated)
        } else {
            activeHoldMacroID = nil
            startPlayback(macro)
        }
    }

    // MARK: - Single operation capture

    func beginActionCapture(for macroID: UUID) {
        guard macros.contains(where: { $0.id == macroID }),
              !isRecording, !isPlaying, capturingTriggerFor == nil,
              capturingActionFor == nil else { return }
        guard AccessibilityHelper.isTrusted(prompt: false) else {
            _ = AccessibilityHelper.isTrusted(prompt: true)
            statusMessage = "录入操作需要系统输入权限。"
            return
        }
        captureMouseDown = nil
        captureDrag = nil
        captureKeyDown = nil
        capturingActionFor = macroID
        mouseButtons.isSuspended = true
        let started = recorder.start { [weak self] event in
            self?.handleCapturedAction(event)
        }
        if !started {
            capturingActionFor = nil
            mouseButtons.isSuspended = false
            statusMessage = "无法开始录入操作。"
        } else {
            statusMessage = "请执行一次鼠标或键盘操作；Esc 取消。"
        }
    }

    func cancelActionCapture() {
        guard capturingActionFor != nil else { return }
        recorder.stop()
        capturingActionFor = nil
        captureMouseDown = nil
        captureDrag = nil
        captureKeyDown = nil
        mouseButtons.isSuspended = false
    }

    private func finishCapturedAction(_ events: [MacroEvent]) {
        guard let id = capturingActionFor else { return }
        cancelActionCapture()
        guard let index = macros.firstIndex(where: { $0.id == id }), !events.isEmpty else { return }
        macros[index].events.append(contentsOf: events)
        scheduleSave()
        statusMessage = "已录入 \(events.count) 个步骤。"
    }

    private func handleCapturedAction(_ event: MacroEvent) {
        guard capturingActionFor != nil else { return }
        // Do not record clicks on Actape's own Cancel button or editor.
        // Keyboard keys can still be captured while Actape is active.
        if NSApp.isActive && (event.kind.isMouse || event.kind == .scroll) { return }
        switch event.kind {
        case .click, .scroll:
            finishCapturedAction([event])
        case .mouseDown:
            captureMouseDown = event
        case .mouseDrag:
            captureDrag = event
        case .mouseUp:
            if let down = captureMouseDown {
                if let drag = captureDrag {
                    finishCapturedAction([down, drag, event])
                } else {
                    finishCapturedAction([down, event])
                }
            }
        case .keyDown:
            if event.keyCode == 53 { cancelActionCapture(); statusMessage = "已取消录入。"; return }
            if captureKeyDown == nil { captureKeyDown = event }
        case .keyUp:
            if let down = captureKeyDown, down.keyCode == event.keyCode {
                var combo = down
                combo.kind = .keyCombo
                combo.modifierFlags = down.modifierFlags
                finishCapturedAction([combo])
            }
        default: break
        }
    }

    // MARK: - Recording

    /// Keep the recorder from capturing the global toggle shortcuts.
    func setBlockedKeyCodes(_ codes: Set<UInt16>) {
        recorder.blockedKeyCodes = codes
        blockedTriggerKeys = codes
    }

    func startRecording(intoNewMacro: Bool = true) {
        guard !isRecording, !isPlaying, capturingActionFor == nil else { return }

        if !AccessibilityHelper.isTrusted(prompt: false) {
            statusMessage = "需要设备控制和数据访问权限，请点击顶部提示授权。"
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
            cancelTriggerCapture()
            mouseButtons.isSuspended = true
            isRecording = true
            statusMessage = "正在录制… 按 F6 结束。"
        } else {
            statusMessage = "录制启动失败，请检查设备控制和数据访问权限。"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recorder.stop()
        isRecording = false
        mouseButtons.isSuspended = false
        statusMessage = "录制完成，共 \(selectedMacro?.events.count ?? 0) 步。"
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
        guard !isRecording, capturingActionFor == nil else { return }
        guard let macro = selectedMacro, !macro.events.isEmpty else {
            statusMessage = "没有可执行的步骤。"
            return
        }
        if !AccessibilityHelper.isTrusted(prompt: false) {
            statusMessage = "执行宏需要设备控制和数据访问权限。"
            _ = AccessibilityHelper.isTrusted(prompt: true)
            return
        }
        if isPlaying { player.cancel(); return }
        startPlayback(macro)
    }

    private func startPlayback(_ macro: Macro) {
        isPlaying = true
        playbackProgress = (1, 0)
        statusMessage = "正在执行「\(macro.name)」…"

        player.play(macro: macro,
                    onProgress: { [weak self] rep, step in
                        self?.playbackProgress = (rep, step)
                    },
                    onFinish: { [weak self] cancelled in
                        guard let self = self else { return }
                        self.isPlaying = false
                        self.activeHoldMacroID = nil
                        self.playbackProgress = nil
                        self.statusMessage = cancelled ? "已停止执行。" : "执行完成。"
                    })
    }

    func stopPlayback() {
        guard isPlaying else { return }
        activeHoldMacroID = nil
        player.cancel()
        isPlaying = false
        playbackProgress = nil
        statusMessage = "已停止执行。"
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            playSelected()
        }
    }
}
