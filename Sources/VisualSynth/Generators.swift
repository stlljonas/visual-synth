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
        ModuleSpec(id: "shapes", name: "Polygons", kind: .generator, function: "gen_shapes", params: [
            .int("sides", "Sides", 3, 12, 6),
            .choice("layout", "Layout", ["Grid", "Ring", "Single"], 0),
            .int("count", "Count", 1, 16, 4, help: "Grid rows, or shapes around the ring"),
            .range("size", "Size", 0.05, 1, 0.7),
            .choice("style", "Style", ["Outline", "Filled"], 0),
            .range("thick", "Thickness", 0.02, 0.6, 0.12, help: "Outline thickness, relative to the size"),
            .range("spin", "Spin", -2, 2, 0.125, unit: "/beat", help: "Turns per beat"),
            .range("alt", "Alternate", 0, 1, 1, help: "Neighbours spin the other way"),
            .range("stagger", "Stagger", 0, 1, 0.25, help: "Rotation offset from shape to shape"),
            .range("orbit", "Orbit", -1, 1, 0.0625, unit: "/beat", help: "Ring layout: turns per beat of the whole ring"),
            .int("nest", "Nested", 1, 8, 1, help: "Concentric copies inside each shape"),
            .range("pulse", "Pulse size", 0, 1, 0.4, help: "Shapes grow on each MIDI note"),
            .range("jump", "Note jump", 0, 1, 0, help: "Random rotation jump on each note"),
            .range("rainbow", "Rainbow", 0, 1, 0.15, help: "Spread hue across shapes"),
            .range("soft", "Softness", 0, 1, 0),
            .range("flow", "Flow", -2, 2, 0, unit: "/beat", help: "Nested copies stream outwards (negative: inwards)"),
        ], hue: 0.92, help: "Rotating regular polygons in a grid, a ring or one big nested shape"),
    ]
}
