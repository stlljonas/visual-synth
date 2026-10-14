import SwiftUI

struct ControlPanel: View {
    @Environment(Engine.self) private var engine
    @State private var query = ""
    @AppStorage("favoritesOnly") private var favoritesOnly = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()
            searchBar
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
                // lazy: only the cards on screen are built and measured, so opening one doesn't re-layout all of them
                LazyVStack(alignment: .leading, spacing: 8) {
                    if query.isEmpty && !favoritesOnly { ScenesSection() }
                    section("Favourites", "starred ☆", allCards, favourites: true)
                    if query.isEmpty && !favoritesOnly {
                        SectionTitle("Master", "")
                        AudioSyncRow()
                        ModuleCard(module: engine.master, alwaysOpen: true)
                    }
                    section("Colour", "", [engine.palette])
                    section("Layers", "repeating elements, stacked", engine.generators, drift: true)
                    section("Effects", "applied top to bottom", engine.effects, drift: true, reorderable: true)
                    section("Modulators", "route with right-click → Modulate by", engine.modulators)
                    if nothingShown {
                        Text(favoritesOnly && query.isEmpty
                             ? "No favourites yet: star a card with ☆ to keep it here."
                             : "Nothing matches “\(query)”.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                }
                .padding(12)
            }
            Text("Scroll on a slider to change it (⌥ = fine) · double-click resets · right-click: MIDI learn, modulate · ↝ drift\nTab hides panel · Space / A–K play notes · 1–9 scenes · ⌘S save scene · ⌘F search · ⌃⌘F full screen")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.3))
        }
        .background(Color(white: 0.09))
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search layers, effects, sliders…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Button { favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(favoritesOnly ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Show only starred cards")
            // ⌘F focuses the search field
            Button("") { engine.showPanel = true; searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
    }

    /// Favourites have their own section at the top, so the other sections leave them out.
    private func visible(_ modules: [Module], favourites: Bool = false) -> [(Module, [Param]?)] {
        modules.compactMap { m in
            if engine.favorites.contains(m.id) != favourites { return nil }
            if favoritesOnly && !favourites { return nil }
            guard let params = Fuzzy.filter(m, query) else { return nil }
            return (m, params)
        }
    }

    private var nothingShown: Bool {
        (favoritesOnly || !query.isEmpty)
            && visible(allCards).isEmpty && visible(allCards, favourites: true).isEmpty
    }

    private var allCards: [Module] { [engine.palette] + engine.generators + engine.effects + engine.modulators }

    @ViewBuilder
    private func section(_ title: String, _ subtitle: String, _ modules: [Module],
                         drift: Bool = false, reorderable: Bool = false, favourites: Bool = false) -> some View {
        let shown = visible(modules, favourites: favourites)
        if !shown.isEmpty {
            SectionTitle(title, subtitle, modules: drift ? modules : [])
            ForEach(shown, id: \.0.id) { m, params in
                ModuleCard(module: m, reorderable: reorderable && query.isEmpty && !favoritesOnly,
                           only: params, forceOpen: !query.isEmpty)
            }
        }
    }
}

/// Fuzzy matching: every word of the query must appear in the card's name (letters in order, gaps allowed)
/// or literally in its description; otherwise the card shows only the sliders whose names match.
enum Fuzzy {
    static func matches(_ word: Substring, _ text: String) -> Bool {
        var it = text.lowercased().makeIterator()
        for ch in word {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }

    static func words(_ q: String) -> [Substring] { q.lowercased().split(separator: " ") }

    /// nil: hide the card. [] / nil params: show all sliders. Otherwise: only these sliders.
    static func filter(_ m: Module, _ query: String) -> [Param]?? {
        let ws = words(query)
        if ws.isEmpty { return .some(nil) }
        let kind = m.spec.kind.rawValue
        let cardHit = ws.allSatisfy { w in
            matches(w, m.spec.name) || m.spec.help.lowercased().contains(w) || kind.hasPrefix(w)
        }
        if cardHit { return .some(nil) }
        let ps = m.allParams.filter { p in ws.allSatisfy { matches($0, p.spec.name) } }
        return ps.isEmpty ? nil : .some(ps)
    }
}

/// Saved scenes as thumbnails: click to load (crossfades over Master › Scene fade), right-click for more.
private struct ScenesSection: View {
    @State private var renaming: SceneLibrary.Entry?
    @State private var newName = ""
    private var lib: SceneLibrary { Shared.scenes }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("SCENES").font(.system(size: 11, weight: .bold)).tracking(1.2)
                Text("keys 1–9 · program change").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { lib.saveNew() } label: { Label("Save", systemImage: "plus") }
                    .help("Save what's on screen as a new scene (⌘S)")
                Button("Import…") { lib.importFiles() }
                    .help("Add scene files (.json), e.g. ones exported from another Mac")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .padding(.top, 8)
            if lib.entries.isEmpty {
                Text("Save the current look with + Save (⌘S). Click a scene to switch to it, crossfading over Master › Scene fade.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(lib.entries.enumerated()), id: \.1.id) { i, e in
                        SceneTile(entry: e, number: i < 9 ? i + 1 : nil, current: lib.current == e.url)
                            .onTapGesture { lib.load(e) }
                            .contextMenu {
                                Button("Load") { lib.load(e) }
                                Button("Update with Current Look") { lib.update(e) }
                                Button("Rename…") { newName = e.name; renaming = e }
                                Divider()
                                Button("Export…") { lib.export(e) }
                                Button("Show in Finder") { lib.revealInFinder(e) }
                                Divider()
                                Button("Move to Trash") { lib.delete(e) }
                            }
                    }
                }
            }
        }
        .alert("Rename scene", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let r = renaming { lib.rename(r, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

private struct SceneTile: View {
    let entry: SceneLibrary.Entry
    let number: Int?
    let current: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let img = entry.thumbnail {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(height: 54)
                .frame(maxWidth: .infinity)
                .clipped()
                if let n = number {
                    Text("\(n)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.6)))
                        .padding(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(current ? Color.accentColor : Color.white.opacity(hovering ? 0.35 : 0.1),
                                  lineWidth: current ? 2 : 1)
            )
            Text(entry.name)
                .font(.system(size: 10))
                .foregroundStyle(current ? .primary : .secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Click to switch to “\(entry.name)” · right-click to rename, update, export or delete")
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
                Text(engine.audioStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if engine.audioStatus.contains("permission") || engine.audioStatus.contains("allow") {
                    Button("Open Privacy Settings") {
                        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                        NSWorkspace.shared.open(URL(string: url)!)
                    }
                    .controlSize(.small)
                }
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
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
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
            FrameGraph()
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

/// Frame rate over the last 10 s (line) and GPU time per frame (faint area), redrawn on its own.
private struct FrameGraph: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !engine.showPanel)) { ctx in
            let now = ctx.date.timeIntervalSinceReferenceDate - Date().timeIntervalSinceReferenceDate + CACurrentMediaTime()
            Canvas { gc, size in
                let hz = max(30, engine.displayHz)
                let top = hz * 1.1
                func x(_ t: Double) -> CGFloat { size.width * CGFloat(1 - (now - t) / 10) }
                func y(_ fps: Double) -> CGFloat { size.height * CGFloat(1 - min(fps, top) / top) }
                let frames = engine.frameHistory.filter { now - $0.t <= 10 }
                // target line
                var target = Path()
                target.move(to: CGPoint(x: 0, y: y(hz)))
                target.addLine(to: CGPoint(x: size.width, y: y(hz)))
                gc.stroke(target, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                guard frames.count > 1 else { return }
                // GPU time as a share of the frame budget
                var gpu = Path()
                gpu.move(to: CGPoint(x: x(frames[0].t), y: size.height))
                for f in frames {
                    let share = min(1, f.gpu / (1000 / hz))
                    gpu.addLine(to: CGPoint(x: x(f.t), y: size.height * CGFloat(1 - share)))
                }
                gpu.addLine(to: CGPoint(x: x(frames.last!.t), y: size.height))
                gc.fill(gpu, with: .color(.blue.opacity(0.18)))
                // fps, averaged over ~6 frames: dropped frames still show, timer jitter doesn't
                var line = Path()
                for (i, f) in frames.enumerated() {
                    let lo = max(0, i - 3), hi = min(frames.count - 1, i + 3)
                    let dt = frames[lo...hi].map(\.dt).reduce(0, +) / Double(hi - lo + 1)
                    let p = CGPoint(x: x(f.t), y: y(1 / max(dt, 1e-4)))
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                let avg = Double(frames.count - 1) / max(frames.last!.t - frames[0].t, 1e-3)
                gc.stroke(line, with: .color(avg < hz * 0.95 ? .orange : .green), lineWidth: 1.2)
            }
        }
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.03)))
        .help("Frames per second over the last 10 s (dashed: display refresh rate); blue: GPU time per frame")
    }
}

private let driftIcon = "point.topleft.down.to.point.bottomright.curvepath"
private let modTint = Color(red: 0.72, green: 0.5, blue: 1)

struct ModuleCard: View {
    @Bindable var module: Module
    var alwaysOpen = false
    var reorderable = false
    /// Only these sliders (search hits); nil = all.
    var only: [Param]? = nil
    var forceOpen = false
    @Environment(Engine.self) private var engine

    private var tint: Color {
        switch module.spec.kind {
        case .generator: return Color(hue: Double(module.common[0].value), saturation: 0.65, brightness: 0.95)
        case .effect: return Color(red: 1, green: 0.62, blue: 0.25)
        case .modulator: return modTint
        case .palette: return Color(red: 1, green: 0.4, blue: 0.75)
        case .master: return Color(white: 0.85)
        }
    }

    private var open: Bool { alwaysOpen || module.expanded || forceOpen }
    private var shownParams: [Param] { only.map { o in module.params.filter { p in o.contains { $0 === p } } } ?? module.params }
    private var shownCommon: [Param] { only.map { o in module.common.filter { p in o.contains { $0 === p } } } ?? module.common }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !alwaysOpen { header }
            if module.spec.kind == .palette { PaletteStrip() }
            if open {
                if module.id == "camera" { CameraPicker() }
                if module.id == "media" { MediaPicker() }
                ForEach(shownParams) { ParamSlider(param: $0, tint: tint) }
                if module.spec.kind == .palette && Int(module.params[0].packed) == Palettes.presets.count {
                    CustomPaletteEditor()
                }
                if !shownCommon.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(shownCommon) { ParamSlider(param: $0, tint: tint) }
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
        // switching a card on opens it, switching it off folds it away
        .onChange(of: module.enabled) { _, on in module.expanded = on }
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
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(module.spec.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(module.enabled ? .primary : .secondary)
                    if module.spec.kind == .modulator, module.enabled { ModMeter(sourceId: module.id) }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(module.spec.help)
            let fav = engine.favorites.contains(module.id)
            Button {
                if fav { engine.favorites.remove(module.id) } else { engine.favorites.insert(module.id) }
            } label: {
                Image(systemName: fav ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(fav ? Color.yellow : Color.secondary.opacity(0.6))
            .help(fav ? "Remove from favourites" : "Add to favourites (★ filter at the top)")
            if reorderable {
                iconButton("arrow.up", "Move earlier in the chain") { engine.moveEffect(module, by: -1) }
                iconButton("arrow.down", "Move later in the chain") { engine.moveEffect(module, by: 1) }
            }
            Button { module.toggleWalk() } label: {
                Image(systemName: driftIcon)
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

/// Live output of a modulation source (redrawn on its own, the rest of the panel stays still).
private struct ModMeter: View {
    let sourceId: String
    @Environment(Engine.self) private var engine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !engine.showPanel)) { _ in
            let i = Modulators.index(of: sourceId) ?? 0
            let bipolar = Modulators.sources[i].bipolar
            let v = CGFloat(engine.modValues[i])
            ZStack(alignment: bipolar ? .center : .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(modTint)
                    .frame(width: max(2, abs(v) * (bipolar ? 18 : 36)))
                    .offset(x: bipolar ? v * 9 : 0)
            }
            .frame(width: 36, height: 4)
        }
    }
}

private struct PaletteStrip: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !engine.showPanel)) { _ in
            let stops = engine.paletteStops
            let shift = Double(engine.palette.params[1].effective(engine.modValues))
            let colors = (0...20).map { k -> Color in
                let t = (Double(k) / 20 + shift).truncatingRemainder(dividingBy: 1)
                let x = t * Double(stops.count)
                let i = Int(x) % stops.count, j = (i + 1) % stops.count
                let f = Float(x - floor(x)), s = f * f * (3 - 2 * f)
                let c = stops[i] + (stops[j] - stops[i]) * s
                return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                .frame(height: 10)
        }
    }
}

private struct CustomPaletteEditor: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        HStack(spacing: 6) {
            Text("Colours").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            ForEach(engine.customPalette.indices, id: \.self) { i in
                ColorPicker("", selection: Binding(
                    get: {
                        let c = engine.customPalette[i]
                        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
                    },
                    set: { col in
                        if let rgb = NSColor(col).usingColorSpace(.sRGB) {
                            engine.customPalette[i] = SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent),
                                                            Float(rgb.blueComponent))
                        }
                    }), supportsOpacity: false)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 4)
    }
}

struct ParamSlider: View {
    @Bindable var param: Param
    let tint: Color
    /// Depth sliders: no drift, MIDI learn or modulation of their own.
    var compact = false
    /// For depth sliders: the slider they belong to (gets the scroll wheel back on exit).
    var parent: Param? = nil
    @Environment(Engine.self) private var engine
    @State private var hovering = false

    private var learning: Bool { engine.learning === param }
    private var sourceName: String? {
        param.modSource.flatMap { id in Modulators.sources.first { $0.id == id }?.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(param.spec.name).font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
                if let cc = param.cc {
                    Text("CC\(cc)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.25)))
                }
                if let name = sourceName {
                    Text("∿ \(name)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(modTint.opacity(0.3)))
                        .help("Modulated by \(name); right-click to change or remove")
                }
                Spacer()
                if !compact {
                    Button { param.walk.toggle() } label: {
                        Image(systemName: driftIcon)
                            .font(.system(size: 9, weight: param.walk ? .bold : .regular))
                            .frame(width: 14, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(param.walk ? tint : Color.secondary.opacity(hovering ? 0.8 : 0.25))
                    .help("Drift: let this slider wander (random walk)")
                }
                Text(param.display).font(.system(size: compact ? 10 : 11, design: .monospaced)).foregroundStyle(.primary)
            }
            if let options = param.spec.options {
                optionPicker(options)
            } else {
                track
            }
            if let depth = param.modDepth {
                HStack(alignment: .bottom, spacing: 6) {
                    Button { param.modUnipolar.toggle() } label: {
                        Text(param.modUnipolar ? "+" : "±")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 18, height: 16)
                            .background(RoundedRectangle(cornerRadius: 3).fill(modTint.opacity(0.25)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(param.modUnipolar
                          ? "+: pushes the slider up from its value (0…1 of the source; negative depth pushes down). Click for ±"
                          : "±: swings the slider both ways around its value. Click for +")
                    ParamSlider(param: depth, tint: modTint, compact: true, parent: param)
                }
                .padding(.leading, 10)
            }
        }
        .padding(.vertical, compact ? 0 : 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(hovering && !compact ? 0.05 : 0))
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
                ScrollRouter.shared.hovered = parent
            }
        }
        .contextMenu {
            if !compact {
                Button(learning ? "Cancel MIDI Learn" : "MIDI Learn") { engine.learning = learning ? nil : param }
                if param.cc != nil { Button("Forget CC\(param.cc!)") { param.cc = nil } }
                Menu("Modulate by") {
                    ForEach(Modulators.sources, id: \.id) { s in
                        Button((param.modSource == s.id ? "✓ " : "") + s.name) { param.route(to: s.id) }
                    }
                }
                if param.modSource != nil { Button("Remove Modulation") { param.route(to: nil) } }
            }
            Button("Reset to \(param.format(param.spec.def))") { param.reset() }
        }
        .help(param.spec.help ?? "")
    }

    private var track: some View {
        GeometryReader { geo in
            let n = CGFloat(param.normalized)
            let zeroN = param.spec.min < 0 && param.spec.max > 0 ? CGFloat(-param.spec.min / param.range) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(height: compact ? 3 : 4)
                // filled part from zero (bipolar params fill from the middle)
                Capsule()
                    .fill(tint.opacity(hovering ? 1 : 0.8))
                    .frame(width: max(2, abs(n - zeroN) * geo.size.width), height: compact ? 3 : 4)
                    .offset(x: min(n, zeroN) * geo.size.width)
                if param.modSource != nil { ModulatedMarker(param: param, width: geo.size.width) }
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                    .frame(width: compact ? 8 : 10, height: compact ? 8 : 10)
                    .offset(x: n * geo.size.width - (compact ? 4 : 5))
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
        .frame(height: compact ? 10 : 14)
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

/// Where the modulator currently pushes the slider (a ring riding along the track).
private struct ModulatedMarker: View {
    let param: Param
    let width: CGFloat
    @Environment(Engine.self) private var engine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !engine.showPanel)) { _ in
            let v = param.effective(engine.modValues)
            let n = CGFloat(param.range == 0 ? 0 : (v - param.spec.min) / param.range)
            Circle()
                .strokeBorder(modTint, lineWidth: 2)
                .frame(width: 10, height: 10)
                .offset(x: n * width - 5)
        }
    }
}

/// Camera card: which camera, and how it's doing (resolution, measured fps, or what's wrong).
private struct CameraPicker: View {
    private var state: SourcesState { Shared.sources.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "camera").font(.system(size: 10)).foregroundStyle(.secondary)
                if state.devices.isEmpty {
                    Text("No camera found").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: Binding(
                        get: { state.selected.flatMap { s in state.devices.first { $0.id == s }?.id } ?? state.devices[0].id },
                        set: { Shared.sources.camera.select($0) })) {
                        ForEach(state.devices) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                Button { Shared.sources.camera.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Look for cameras again")
            }
            if !state.status.isEmpty {
                Text(state.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// Image / Video card: the file, and a button to open another.
private struct MediaPicker: View {
    @Environment(Engine.self) private var engine
    private var state: SourcesState { Shared.sources.state }

    var body: some View {
        HStack(spacing: 6) {
            Button("Open…") { MediaPicker.open(engine) }
                .controlSize(.small)
            Text(state.mediaStatus.isEmpty ? "Open an image or video, or drop one on the picture" : state.mediaStatus)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    static func open(_ engine: Engine) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.showMedia(url)
    }
}
