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
                TextField("Macro name", text: $macro.name)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                Text("\(macro.events.count) \(macro.events.count == 1 ? "step" : "steps") · \(formatted(ms: macro.totalDurationMs))")
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var repeatControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("REPEAT")
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
                Toggle("Loop forever", isOn: infiniteBinding)
                    .toggleStyle(.checkbox)
                    .help("Repeat until you press Stop, or a Type-Text stop time is reached.")
            }
        }
    }

    private var speedControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SPEED")
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
                .help("Reset to 1.00×")
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
                    Label("No events yet", systemImage: "waveform.path")
                } description: {
                    Text("Press F6 (or the record button) to start capturing clicks, drags, scrolls and keyboard input.")
                } actions: {
                    Button {
                        store.toggleRecording()
                    } label: {
                        Label(store.isRecording ? "Stop Recording" : "Start Recording",
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
                    addBlankEvent()
                } label: {
                    Label("Mouse Click", systemImage: "cursorarrow.click")
                }
                Button {
                    addTypeTextEvent()
                } label: {
                    Label("Type Text / Sequence", systemImage: "character.cursor.ibeam")
                }
            } label: {
                Label("Add Step", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                clearAll()
            } label: {
                Label("Clear All", systemImage: "xmark.octagon")
            }
            .disabled(macro.events.isEmpty)

            Spacer()

            Text("Tip: drag rows to reorder. Use a row’s 🗑 button to delete a step.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    // MARK: Actions

    private func addBlankEvent() {
        var e = MacroEvent()
        e.kind = .click
        e.delayMs = 200
        e.x = 100
        e.y = 100
        macro.events.append(e)
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
