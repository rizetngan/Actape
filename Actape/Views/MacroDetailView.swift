import SwiftUI

struct MacroDetailView: View {
    @EnvironmentObject var store: MacroStore
    @Binding var macro: Macro
    /// Remembers the finite repeat count while "Infinite" is toggled on.
    @State private var lastFiniteRepeat: Int = 1

    private var isInfinite: Bool { macro.repeatCount == 0 }

    private var infiniteBinding: Binding<Bool> {
        Binding(
            get: { macro.repeatCount == 0 },
            set: { inf in
                if inf {
                    if macro.repeatCount != 0 { lastFiniteRepeat = macro.repeatCount }
                    macro.repeatCount = 0
                } else {
                    macro.repeatCount = max(1, lastFiniteRepeat)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            eventList
            Divider()
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title + summary
            VStack(alignment: .leading, spacing: 2) {
                TextField("宏名称", text: $macro.name)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                Text("\(macro.events.count) 步 · \(formatted(ms: macro.totalDurationMs))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Playback controls
            HStack(alignment: .center, spacing: 20) {
                repeatControl
                Divider().frame(height: 34)
                speedControl
                Spacer(minLength: 0)
            }
            triggerControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var triggerControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
            Text("触发键")
                .font(.subheadline)
            Spacer()
            Button {
                if store.capturingTriggerFor == macro.id {
                    store.cancelTriggerCapture()
                } else {
                    store.beginTriggerCapture(for: macro.id)
                }
            } label: {
                Text(store.capturingTriggerFor == macro.id
                     ? "请按触发键…（取消）"
                     : macro.triggerDisplay)
                    .frame(minWidth: 140)
            }
            .disabled(store.isRecording || store.isPlaying || store.capturingActionFor != nil)
            .help("直接按鼠标侧键、键盘单键或快捷键组合")
            if macro.triggerButton != nil || macro.triggerKeyCode != nil {
                Button {
                    store.clearTrigger(for: macro.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("清除触发键绑定")
            }
            Toggle("按住循环", isOn: Binding(
                get: { macro.triggerHold == true },
                set: { macro.triggerHold = $0 }
            ))
            .toggleStyle(.checkbox)
            .disabled(store.isRecording || store.isPlaying)
        }
    }

    private var repeatControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("执行次数")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if isInfinite {
                    Text("∞")
                        .font(.title3.monospacedDigit())
                        .frame(width: 64, height: 22, alignment: .center)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                } else {
                    Stepper(value: $macro.repeatCount, in: 1...100000) {
                        TextField("", value: $macro.repeatCount, formatter: Self.repeatFormatter)
                            .frame(width: 56)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("×").foregroundStyle(.secondary)
                }
                Toggle("无限循环", isOn: infiniteBinding)
                    .toggleStyle(.checkbox)
                    .help("持续循环，直到手动停止或满足停止条件。")
            }
        }
    }

    private var speedControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("执行速度")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(value: $macro.playbackSpeed, in: 0.1...10.0)
                    .frame(width: 150)
                Text(String(format: "%.2f×", macro.playbackSpeed))
                    .font(.callout.monospacedDigit())
                    .frame(width: 52, alignment: .leading)
                Button {
                    macro.playbackSpeed = 1.0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("恢复为 1 倍速")
                .disabled(abs(macro.playbackSpeed - 1.0) < 0.001)
            }
        }
    }

    private static let repeatFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 1
        return f
    }()

    // MARK: Event list

    private var eventList: some View {
        Group {
            if macro.events.isEmpty {
                ContentUnavailableView {
                    Label("还没有操作步骤", systemImage: "waveform.path")
                } description: {
                    Text("点击「开始录制」或按 F6，记录鼠标与键盘操作。")
                } actions: {
                    Button {
                        store.toggleRecording()
                    } label: {
                        Label(store.isRecording ? "结束录制" : "开始录制",
                              systemImage: store.isRecording ? "stop.circle.fill" : "record.circle")
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No `selection:` binding: a selection-enabled List turns rows into
                // buttons that swallow clicks before the inline TextFields can focus,
                // which made the editor fields read-only. Per-row delete buttons
                // replace selection-based deletion; .onMove keeps drag-to-reorder.
                List {
                    ForEach($macro.events) { $event in
                        EventRowView(event: $event) {
                            macro.events.removeAll { $0.id == event.id }
                        }
                    }
                    .onMove { indices, newOffset in
                        macro.events.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    store.beginActionCapture(for: macro.id)
                } label: {
                    Label("录入操作", systemImage: "record.circle")
                }
                Button {
                    addTypeTextEvent()
                } label: {
                    Label("输入文字", systemImage: "character.cursor.ibeam")
                }
                Button {
                    addWaitEvent()
                } label: {
                    Label("等待", systemImage: "clock")
                }
            } label: {
                Label("添加步骤", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.capturingActionFor != nil || store.isRecording || store.isPlaying)

            if store.capturingActionFor == macro.id {
                Button("取消录入") { store.cancelActionCapture() }
                    .controlSize(.small)
            }

            Button {
                clearAll()
            } label: {
                Label("清空步骤", systemImage: "xmark.octagon")
            }
            .disabled(macro.events.isEmpty || store.capturingActionFor != nil)

            Spacer()
            Text("拖动调整顺序")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    // MARK: Actions

    private func addWaitEvent() {
        var event = MacroEvent()
        event.kind = .wait
        event.delayMs = 300
        macro.events.append(event)
    }

    private func addTypeTextEvent() {
        var e = MacroEvent()
        e.kind = .typeText
        e.delayMs = 200
        // Defaults tuned for the common case: 24h timestamps every 15 minutes
        // (0000, 0015, 0030, 0045, 0100 …), one per macro repeat.
        e.text = ""
        e.seqFormat = .timeHHMM
        e.seqStart = 0
        e.seqStep = 15
        macro.events.append(e)
    }

    private func clearAll() {
        macro.events.removeAll()
    }

    private func formatted(ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        let s = Double(ms) / 1000
        return String(format: "%.2f s", s)
    }
}
