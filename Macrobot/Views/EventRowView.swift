import SwiftUI

struct EventRowView: View {
    @Binding var event: MacroEvent
    var onDelete: () -> Void = {}
    @State private var expanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: event.kind.sfSymbol)
                    .frame(width: 22)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.summary)
                        .font(.body.monospacedDigit())
                    Text(event.kind.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("Δ")
                        .foregroundStyle(.secondary)
                    TextField("",
                              value: $event.delayMs,
                              formatter: Self.intFormatter)
                        .frame(width: 64)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("ms").font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Collapse" : "Edit fields")

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this step")
            }

            if expanded {
                Divider().padding(.vertical, 6)
                editor
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if event.kind == .typeText {
            typeTextEditor
        } else {
            standardEditor
        }
    }

    @ViewBuilder
    private var standardEditor: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            kindPicker
            if event.kind.isMouse {
                xField
                yField
                if event.kind == .click || event.kind == .mouseDown || event.kind == .mouseUp || event.kind == .mouseDrag {
                    buttonPicker
                }
                if event.kind == .click || event.kind == .mouseDown || event.kind == .mouseUp {
                    clickCountField
                }
            }
            if event.kind.isKeyboard {
                keyCodeField
                modifierToggles
            }
            if event.kind == .scroll {
                scrollDeltaXField
                scrollDeltaYField
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: Type Text editor

    @ViewBuilder
    private var typeTextEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                kindPicker
                    .frame(width: 140)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Template").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. {n}\\t or leave blank", text: $event.text)
                        .textFieldStyle(.roundedBorder)
                    Text("“{n}” is replaced by the counter. Use \\t / \\n for Tab / Return.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Counter").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $event.seqFormat) {
                        ForEach(SequenceFormat.allCases, id: \.self) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                if event.seqFormat != .none {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start").font(.caption).foregroundStyle(.secondary)
                        if event.seqFormat.isTime {
                            DatePicker("", selection: timeBinding($event.seqStart),
                                       displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        } else {
                            TextField("", value: $event.seqStart, formatter: Self.signedIntFormatter)
                                .frame(width: 70)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.seqFormat.isTime ? "Step (min)" : "Step")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("", value: $event.seqStep, formatter: Self.signedIntFormatter)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                    }
                    if event.seqFormat == .number {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pad").font(.caption).foregroundStyle(.secondary)
                            TextField("", value: $event.seqPad, formatter: Self.intFormatter)
                                .frame(width: 50)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            if event.seqFormat.isTime {
                HStack(alignment: .center, spacing: 12) {
                    Toggle("Stop run at", isOn: $event.seqStopEnabled)
                        .toggleStyle(.checkbox)
                    DatePicker("", selection: timeBinding($event.seqStop),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(!event.seqStopEnabled)
                    Text("Halts the whole macro once the sequence reaches this time (wraps past 23:59).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if event.seqFormat != .none {
                Text("Preview (per repeat): " + sequencePreview)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(event.seqStopEnabled && event.seqFormat.isTime
                 ? "The counter advances once per macro repeat — set Repeat to ∞ (Infinite) and the run stops itself at the time above."
                 : "The counter advances once per macro repeat — set the macro’s Repeat count to how many values you need.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private var sequencePreview: String {
        var parts: [String] = []
        var halted = false
        let cap = 8
        var i = 0
        while i < cap {
            let decision = event.sequenceStopDecision(iteration: i)
            if decision.type {
                parts.append(event.renderedText(iteration: i)
                    .replacingOccurrences(of: "\n", with: "⏎")
                    .replacingOccurrences(of: "\t", with: "⇥"))
            }
            if decision.halt { halted = true; break }
            i += 1
        }
        let body = parts.joined(separator: "  ")
        if halted { return body + "  ∎ (stop)" }
        return body + "  …"
    }

    /// Bridges an Int "minutes since midnight" value to a `Date` for `DatePicker`.
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                let m = ((minutes.wrappedValue % 1440) + 1440) % 1440
                var comps = DateComponents()
                comps.year = 2000; comps.month = 1; comps.day = 1
                comps.hour = m / 60; comps.minute = m % 60
                return Calendar.current.date(from: comps) ?? Date(timeIntervalSinceReferenceDate: 0)
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    // MARK: Field views

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Type").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $event.kind) {
                ForEach(MacroEventKind.allCases, id: \.self) { k in
                    Text(k.displayName).tag(k)
                }
            }
            .labelsHidden()
        }
    }

    private var xField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("X").font(.caption).foregroundStyle(.secondary)
            TextField("", value: $event.x, formatter: Self.doubleFormatter)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var yField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Y").font(.caption).foregroundStyle(.secondary)
            TextField("", value: $event.y, formatter: Self.doubleFormatter)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var buttonPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Button").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $event.button) {
                ForEach(MouseButton.allCases, id: \.self) { b in
                    Text(b.displayName).tag(b)
                }
            }
            .labelsHidden()
        }
    }

    private var clickCountField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Click count").font(.caption).foregroundStyle(.secondary)
            Stepper(value: $event.clickCount, in: 1...5) {
                Text("\(event.clickCount)")
            }
        }
    }

    private var keyCodeField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Key code").font(.caption).foregroundStyle(.secondary)
            TextField("", value: $event.keyCode, formatter: Self.intFormatter)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var modifierToggles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Modifiers").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                modifierToggle("⇧",  CGEventFlags.maskShift)
                modifierToggle("⌃",  CGEventFlags.maskControl)
                modifierToggle("⌥",  CGEventFlags.maskAlternate)
                modifierToggle("⌘",  CGEventFlags.maskCommand)
                modifierToggle("fn", CGEventFlags.maskSecondaryFn)
            }
        }
    }

    private func modifierToggle(_ label: String, _ mask: CGEventFlags) -> some View {
        let active = (event.modifierFlags & mask.rawValue) != 0
        return Button(label) {
            if active {
                event.modifierFlags &= ~mask.rawValue
            } else {
                event.modifierFlags |= mask.rawValue
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(active ? .accentColor : .secondary)
    }

    private var scrollDeltaXField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ΔX").font(.caption).foregroundStyle(.secondary)
            TextField("", value: $event.scrollDeltaX, formatter: Self.doubleFormatter)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var scrollDeltaYField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ΔY").font(.caption).foregroundStyle(.secondary)
            TextField("", value: $event.scrollDeltaY, formatter: Self.doubleFormatter)
                .textFieldStyle(.roundedBorder)
        }
    }

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 0
        return f
    }()

    private static let signedIntFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.allowsFloats = false
        return f
    }()

    private static let doubleFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.allowsFloats = true
        f.maximumFractionDigits = 1
        return f
    }()
}
