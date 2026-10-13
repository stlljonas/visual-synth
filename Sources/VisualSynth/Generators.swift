/// Generators: repeating visual elements, layered on top of each other.
/// Each one has a fragment function `gen_<id>` in Shaders/Generators.metal;
/// its params arrive as `p[0]`, `p[1]`, … in the order listed here.
/// Hue / Saturation / Brightness / Note gate / Blend are added automatically.
enum Generators {
    static let all: [ModuleSpec] = [
        ModuleSpec(id: "bars", name: "Scrolling Bars", kind: .generator, function: "gen_bars", params: [
            .int("count", "Bars", 1, 64, 8),
            .range("width", "Width", 0.01, 1, 0.35, help: "Share of each period that is lit"),
            .range("speed", "Speed", -4, 4, 0.25, unit: "/beat", help: "Periods per beat; negative scrolls right-to-left"),
            .range("angle", "Angle", -90, 90, 0, unit: "°"),
            .range("soft", "Softness", 0, 0.5, 0),
            .range("pulse", "Pulse width", 0, 1, 0.3, help: "Bars widen on each MIDI note"),
            .range("rainbow", "Rainbow", 0, 1, 0, help: "Spread hue across bars"),
        ], enabled: true, hue: 0.55, help: "Vertical bars moving across the screen, synced to the beat"),
    ]
}
