import SwiftUI

struct ControlPanel: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()
            if let err = engine.shaderError {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Master", "")
                    AudioSyncRow()
                    ModuleCard(module: engine.master, alwaysOpen: true)
                    SectionTitle("Layers", "repeating elements, stacked", modules: engine.generators)
                    ForEach(engine.generators) { ModuleCard(module: $0) }
                    SectionTitle("Effects", "applied top to bottom", modules: engine.effects)
                    ForEach(engine.effects) { ModuleCard(module: $0, reorderable: true) }
                }
                .padding(12)
            }
            Text("Scroll on a slider to change it (⌥ = fine) · double-click resets · right-click for MIDI learn · ↝ drift\nTab hides panel · Space / A–K play notes · ⌃⌘F full screen")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.3))
        }
        .background(Color(white: 0.09))
    }
}

private struct AudioSyncRow: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        @Bindable var engine = engine
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $engine.audioEnabled) {
                Text("Sync to Mac audio").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Follow the beat of whatever plays on this Mac (Spotify, YouTube, …) when no MIDI clock runs")
            if engine.audioEnabled && !engine.audioStatus.isEmpty {
                Text(engine.audioStatus).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct SectionTitle: View {
    let title: String, subtitle: String
    var modules: [Module] = []
    init(_ title: String, _ subtitle: String, modules: [Module] = []) {
        self.title = title
        self.subtitle = subtitle
        self.modules = modules
    }

    /// Drift for the whole section acts on the cards that are switched on.
    private var active: [Module] { modules.filter(\.enabled) }
    private var walking: Bool { active.contains { $0.walking } }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            if !modules.isEmpty {
                Button {
                    let on = !walking
                    for m in active { m.walkable.forEach { $0.walk = on } }
                } label: {
                    Label("Drift all", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 10, weight: walking ? .bold : .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(walking ? Color.accentColor : Color.secondary)
                .disabled(active.isEmpty)
                .help("Let every slider of the switched-on \(title.lowercased()) wander")
            }
        }
        .padding(.top, 8)
    }
}

private struct StatusHeader: View {
    @Environment(Engine.self) private var engine
    @State private var flash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Visual Synth").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "%.0f fps · %.1f ms", engine.fps, engine.gpuMs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(engine.fps > 55 ? Color.secondary : Color.orange)
                    .help("Frames per second · GPU time per frame · \(engine.resolution)")
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.midiDevices.isEmpty ? Color.gray : (flash ? Color.green : Color.green.opacity(0.35)))
                    .frame(width: 7, height: 7)
                Text(engine.midiDevices.isEmpty ? "No MIDI device: plug one in via USB" : engine.midiDevices.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let bpm = engine.clockBPM {
                    Text("\(engine.tempoSource) \(Int(bpm)) bpm").font(.system(size: 10, design: .monospaced)).foregroundStyle(.green)
                }
                Text(engine.resolution).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            if engine.learning != nil {
                Text("MIDI learn: move a knob or fader… (Esc cancels)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.3))
        .onChange(of: engine.midiActivity) {
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { flash = false }
        }
    }
}

struct ModuleCard: View {
    @Bindable var module: Module
    var alwaysOpen = false
    var reorderable = false
    @Environment(Engine.self) private var engine

    private var tint: Color {
        if module.spec.kind == .generator {
            return Color(hue: Double(module.common[0].value), saturation: 0.65, brightness: 0.95)
        }
        return module.spec.kind == .effect ? Color(red: 1, green: 0.62, blue: 0.25) : Color(white: 0.85)
    }

    private var open: Bool { alwaysOpen || module.expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !alwaysOpen { header }
            if open {
                ForEach(module.params) { ParamSlider(param: $0, tint: tint) }
                if !module.common.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(module.common) { ParamSlider(param: $0, tint: tint) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(module.enabled ? 0.075 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(module.enabled && module.spec.kind != .master ? 0.45 : 0), lineWidth: 1)
        )
        .onChange(of: module.enabled) { _, on in if on { module.expanded = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $module.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(tint)
            Button {
                module.expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(module.expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(module.spec.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(module.enabled ? .primary : .secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(module.spec.help)
            if reorderable {
                iconButton("arrow.up", "Move earlier in the chain") { engine.moveEffect(module, by: -1) }
                iconButton("arrow.down", "Move later in the chain") { engine.moveEffect(module, by: 1) }
            }
            Button { module.toggleWalk() } label: {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 10, weight: module.walking ? .bold : .regular))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(module.walking ? tint : Color.secondary)
            .help("Drift: let all sliders of this card wander (random walk)")
            iconButton("dice", "Randomize") { module.randomize() }
            iconButton("arrow.counterclockwise", "Reset") { module.reset() }
        }
    }

    private func iconButton(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10)).frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct ParamSlider: View {
    @Bindable var param: Param
    let tint: Color
    @Environment(Engine.self) private var engine
    @State private var hovering = false

    private var learning: Bool { engine.learning === param }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(param.spec.name).font(.system(size: 11)).foregroundStyle(.secondary)
                if let cc = param.cc {
                    Text("CC\(cc)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.25)))
                }
                Spacer()
                Button { param.walk.toggle() } label: {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 9, weight: param.walk ? .bold : .regular))
                        .frame(width: 14, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(param.walk ? tint : Color.secondary.opacity(hovering ? 0.8 : 0.25))
                .help("Drift: let this slider wander (random walk)")
                Text(param.display).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary)
            }
            if let options = param.spec.options {
                optionPicker(options)
            } else {
                track
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(hovering ? 0.05 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.orange, lineWidth: learning ? 1.5 : 0)
        )
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h {
                ScrollRouter.shared.hovered = param
            } else if ScrollRouter.shared.hovered === param {
                ScrollRouter.shared.hovered = nil
            }
        }
        .contextMenu {
            Button(learning ? "Cancel MIDI Learn" : "MIDI Learn") { engine.learning = learning ? nil : param }
            if param.cc != nil { Button("Forget CC\(param.cc!)") { param.cc = nil } }
            Button("Reset to \(param.format(param.spec.def))") { param.reset() }
        }
        .help(param.spec.help ?? "")
    }

    private var track: some View {
        GeometryReader { geo in
            let n = CGFloat(param.normalized)
            let zeroN = param.spec.min < 0 && param.spec.max > 0 ? CGFloat(-param.spec.min / param.range) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(height: 4)
                // filled part from zero (bipolar params fill from the middle)
                Capsule()
                    .fill(tint.opacity(hovering ? 1 : 0.8))
                    .frame(width: max(2, abs(n - zeroN) * geo.size.width), height: 4)
                    .offset(x: min(n, zeroN) * geo.size.width)
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(radius: 1)
                    .offset(x: n * geo.size.width - 5)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    param.normalized = Float(v.location.x / max(1, geo.size.width))
                }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { param.reset() })
        }
        .frame(height: 14)
    }

    @ViewBuilder
    private func optionPicker(_ options: [String]) -> some View {
        let binding = Binding<Int>(get: { Int(param.packed) }, set: { param.value = Float($0) })
        if options.count <= 4 {
            Picker("", selection: binding) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        } else {
            Picker("", selection: binding) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }
}
