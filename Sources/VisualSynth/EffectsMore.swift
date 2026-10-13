/// More effects, same conventions as Effects.swift; shaders in Shaders/EffectsMore.metal.
/// Listed after Effects.all in the chain (reorderable in the UI).
enum EffectsMore {
    static let all: [ModuleSpec] = [
        // Phase distortion for space: bend the whole image around a centre.
        ModuleSpec(id: "polar", name: "Polar Warp", kind: .effect, function: "fx_polar", params: [
            .choice("mode", "Mode", ["Rings", "Spokes", "Inverse (unroll)"],
                    help: "Rings: vertical bars become circles. Spokes: they fan out. Inverse: unrolls circles into lines"),
            .int("repeat", "Repeat", 1, 12, 2, help: "Copies around the circle"),
            .range("twist", "Twist", -4, 4, 0.6, help: "Turns rings into spirals"),
            .range("zoom", "Zoom", 0.25, 4, 1),
            .range("spin", "Spin", -1, 1, 0.125, unit: "/beat", help: "Turns per beat"),
            .range("scroll", "Scroll", -2, 2, 0, unit: "/beat", help: "Moves the image outward (or inward)"),
            .range("cx", "Centre X", -1, 1, 0),
            .range("cy", "Centre Y", -1, 1, 0),
            .choice("seam", "Seam", ["Mirror", "Wrap"], help: "Mirror hides the join where the image wraps around"),
            .range("pulse", "Note kick", 0, 1, 0.3, help: "Twist jumps on each note"),
        ], help: "Wraps the picture around a centre: bars become rings, spokes or spirals"),

        // Delay with several taps: each tap is a moved, scaled, tinted copy.
        ModuleSpec(id: "multitap", name: "Multi-tap Delay", kind: .effect, function: "fx_multitap", params: [
            .int("taps", "Taps", 1, 8, 4, help: "Number of copies"),
            .range("dx", "Offset X", -0.5, 0.5, 0.06, help: "Shift per tap"),
            .range("dy", "Offset Y", -0.5, 0.5, 0.0),
            .range("scale", "Scale per tap", 0.7, 1.3, 0.94),
            .range("rotate", "Rotate per tap", -45, 45, 0, unit: "°"),
            .range("decay", "Decay", 0, 1, 0.7, help: "Level of each tap relative to the previous one"),
            .range("hue", "Hue per tap", -0.5, 0.5, 0.08),
            .choice("lfo", "LFO shape", ["Off", "Sine", "Saw", "Steps"], 1, help: "Modulates the spread of the taps"),
            .range("rate", "LFO rate", 0, 4, 0.25, unit: "/beat"),
            .range("depth", "LFO depth", 0, 1, 0.6),
            .range("pulse", "Note kick", 0, 1, 0.4, help: "Taps fly apart on each note"),
            .choice("combine", "Combine", ["Max", "Add", "Screen"]),
        ], help: "Copies of the image at spaced offsets, each quieter than the last, like delay taps"),

        // Sidechain compression: everything dips on each hit, then pumps back.
        ModuleSpec(id: "duck", name: "Sidechain Duck", kind: .effect, function: "fx_duck", params: [
            .choice("source", "Trigger", ["Notes", "Beat", "Notes + beat", "Gate (held)"], 1,
                    help: "Notes: ducks on each note. Beat: pumps on the beat like a kick sidechain"),
            .range("depth", "Depth", 0, 1, 0.8),
            .range("rate", "Beat rate", 0.25, 4, 1, unit: "/beat", help: "Pumps per beat (Beat trigger)"),
            .range("shape", "Release shape", 0.2, 5, 1.6, help: "Higher = snaps back faster"),
            .range("darken", "Darken", 0, 1, 0.9),
            .range("shrink", "Shrink", 0, 1, 0.25),
            .range("blur", "Blur", 0, 1, 0),
            .range("desat", "Desaturate", 0, 1, 0.3),
            .range("rotate", "Twist", -1, 1, 0, help: "Rotates away while ducked"),
        ], help: "Darkens / shrinks / blurs on each hit, then recovers: the pumping of a sidechained compressor"),

        // Freeze / hold / looper stutter.
        ModuleSpec(id: "freeze", name: "Freeze / Hold", kind: .effect, function: "fx_freeze", params: [
            .choice("mode", "Hold when", ["Note held", "Always", "Note hit", "Beat stutter"], 3,
                    help: "Beat stutter grabs a fresh frame every N beats"),
            .range("length", "Stutter length", 0.25, 8, 1, unit: " beats"),
            .range("amount", "Hold", 0, 1, 1, help: "How strongly the frozen image is kept"),
            .range("live", "Live level", 0, 1, 0.5, help: "Live image on top of the frozen one (Max / Add)"),
            .range("fade", "Fade", 0, 4, 0.4, unit: "/s", help: "Frozen image fades out over time"),
            .choice("combine", "Combine", ["Replace", "Max", "Add"],
                    help: "Replace: pure freeze. Max / Add: the live image paints into the frozen one"),
            .range("drift", "Drift", -1, 1, 0, help: "The frozen image slides down (or up) while held"),
            .range("zoom", "Zoom", -1, 1, 0, help: "The frozen image zooms while held"),
        ], help: "Holds the last frame while a note is held, always, or in beat-synced stutters"),

        // A "filter" that keeps only edges: like a band-pass on the image.
        ModuleSpec(id: "edges", name: "Neon Edges", kind: .effect, function: "fx_edges", params: [
            .range("thick", "Thickness", 0.5, 6, 1.5, unit: " px"),
            .range("thresh", "Threshold", 0, 1, 0.1, help: "Ignore weaker edges"),
            .range("gain", "Gain", 0, 4, 1.6),
            .range("glow", "Glow", 0, 2, 0.6, help: "Soft halo around the lines"),
            .range("fill", "Keep fill", 0, 1, 0.15, help: "0 = only the lines, 1 = lines over the original"),
            .choice("color", "Colour", ["Direction", "Source", "Fixed", "White"]),
            .range("hue", "Hue", 0, 1, 0.55),
            .range("cycle", "Hue cycle", -1, 1, 0.125, unit: "/beat"),
            .range("pulse", "Note kick", 0, 1, 0.5, help: "Lines flash brighter on notes"),
        ], help: "Traces outlines (Sobel) as glowing neon lines"),

        // Directional max-blur, like pixel sorting.
        ModuleSpec(id: "smear", name: "Smear", kind: .effect, function: "fx_smear", params: [
            .range("length", "Length", 0, 0.6, 0.15),
            .range("angle", "Angle", -180, 180, -90, unit: "°", help: "-90 = drips down"),
            .int("taps", "Quality", 4, 24, 16, help: "Samples along the streak"),
            .range("thresh", "Threshold", 0, 1, 0.25, help: "Only parts brighter than this smear"),
            .range("decay", "Tail fade", 0, 1, 0.5),
            .choice("mode", "Mode", ["Streak", "Pixel sort", "Both ways"]),
            .range("spin", "Spin", -1, 1, 0, unit: "/beat"),
            .range("wobble", "Angle LFO", 0, 90, 0, unit: "°", help: "Angle swings once per bar"),
            .range("pulse", "Note kick", 0, 1, 0.5, help: "Streaks stretch on each note"),
            .range("tint", "Tail hue", -0.5, 0.5, 0, help: "Hue shift along the streak"),
        ], help: "Bright parts streak out along a direction, sharp like pixel sorting"),

        // Datamosh: feedback whose pixels flow along gradients / noise / blocks.
        ModuleSpec(id: "melt", name: "Melt / Datamosh", kind: .effect, function: "fx_melt", params: [
            .range("amount", "Amount", 0, 20, 4, unit: " px", help: "Displacement per frame"),
            .range("decay", "Feedback", 0, 0.99, 0.9, help: "How long melted pixels last"),
            .range("grad", "Gradient flow", -1, 1, 0.6, help: "Pixels slide along brightness slopes"),
            .range("noise", "Noise flow", 0, 1, 0.5),
            .range("scale", "Noise scale", 0.5, 12, 3),
            .range("speed", "Noise speed", 0, 2, 0.25, unit: "/beat"),
            .range("gravity", "Gravity", -1, 1, 0.4, help: "Drips down (or up)"),
            .range("blocks", "Blocks", 0, 1, 0, help: "Datamosh: motion in square macroblocks, new vectors on each note"),
            .range("bsize", "Block size", 8, 128, 48, unit: " px"),
            .range("hue", "Hue drift", -0.1, 0.1, 0.01),
            .range("pulse", "Note kick", 0, 1, 0.5, help: "Melts faster on notes"),
            .choice("combine", "Combine", ["Max", "Add", "Behind"], help: "Behind: the live image covers the melt"),
        ], help: "Feedback that flows and drips: the last frame melts along gradients, noise or macroblocks"),

        ModuleSpec(id: "crt", name: "CRT / Scanlines", kind: .effect, function: "fx_crt", params: [
            .range("lines", "Lines", 100, 1200, 360, help: "Scanlines across the height"),
            .range("scan", "Scanline depth", 0, 1, 0.55),
            .choice("maskType", "Mask", ["Aperture grille", "Slot", "Dots", "None"]),
            .range("mask", "Mask depth", 0, 1, 0.45),
            .range("maskSize", "Mask size", 1, 8, 2, unit: " px"),
            .range("curve", "Curvature", 0, 0.5, 0.12),
            .range("vignette", "Vignette", 0, 1, 0.45),
            .range("bloom", "Bloom", 0, 2, 0.6),
            .range("bleed", "Colour bleed", 0, 4, 1, unit: " px"),
            .range("flicker", "Note flicker", 0, 1, 0.4, help: "Brightness jumps and lines jitter on notes"),
            .range("roll", "Roll bar", 0, 1, 0.15, help: "Bright band rolling down once per bar"),
            .range("bright", "Brightness", 0.5, 2, 1.3, help: "Makes up for the darkening of lines and mask"),
        ], help: "Old monitor: scanlines, RGB phosphor mask, curved glass, glow"),

        ModuleSpec(id: "halftone", name: "Halftone", kind: .effect, function: "fx_halftone", params: [
            .range("cell", "Cell size", 3, 80, 14, unit: " px"),
            .range("angle", "Angle", -90, 90, 45, unit: "°"),
            .choice("mode", "Screen", ["Mono", "RGB (dark)", "CMY (paper)"]),
            .range("gain", "Dot gain", 0.2, 2, 1.1, help: "Dot size for a given brightness"),
            .range("color", "Source colour", 0, 1, 1, help: "Mono: 0 = white dots, 1 = coloured by the image"),
            .range("spin", "Spin", -0.25, 0.25, 0, unit: "/beat"),
            .range("pulse", "Note kick", 0, 1, 0.3, help: "Dots grow on notes"),
            .choice("shape", "Dot shape", ["Round", "Square", "Line"]),
            .range("soft", "Softness", 0, 1, 0),
        ], help: "Print-style dot screen: dot size follows brightness"),

        ModuleSpec(id: "solarize", name: "Solarize / Invert", kind: .effect, function: "fx_solarize", params: [
            .range("amount", "Solarize", 0, 1, 0.8, help: "Folds the bright half back down (Sabattier)"),
            .range("thresh", "Threshold", 0.05, 0.95, 0.5),
            .range("lfo", "Threshold LFO", 0, 0.45, 0.2, help: "Threshold sweeps with the beat"),
            .range("rate", "LFO rate", 0, 2, 0.25, unit: "/beat"),
            .range("spread", "RGB spread", 0, 0.3, 0.08, help: "Different threshold per channel = colour fringes"),
            .range("invert", "Invert", 0, 1, 0),
            .range("pulse", "Invert on notes", 0, 1, 0.5, help: "Flashes inverted on each note"),
            .int("steps", "Posterize", 0, 16, 0, help: "Colour steps per channel, 0 = off"),
            .range("gain", "Gain", 0.5, 3, 1.2, help: "Brightness after the curve"),
        ], help: "Darkroom solarization curve, note-triggered inversion and posterization"),

        ModuleSpec(id: "lens", name: "Lens / Fisheye", kind: .effect, function: "fx_lens", params: [
            .range("distort", "Distortion", -1, 1, 0.35, help: "+ fisheye (barrel), - pincushion"),
            .range("zoom", "Zoom", 0.5, 2, 1.1),
            .range("ca", "Chromatic aberration", 0, 1, 0.3, help: "Colour fringes towards the edges"),
            .range("cx", "Centre X", -1, 1, 0),
            .range("cy", "Centre Y", -1, 1, 0),
            .range("bulge", "Note bulge", -1, 1, 0.5, help: "Bulges out on each note (negative pinches)"),
            .range("rate", "LFO rate", 0, 2, 0.25, unit: "/beat"),
            .range("depth", "LFO depth", 0, 1, 0.3, help: "Distortion breathes with the beat"),
            .choice("edge", "Edges", ["Black", "Mirror", "Repeat"], 1),
            .range("vignette", "Vignette", 0, 1, 0.3),
        ], help: "Fisheye / pincushion lens with chromatic aberration that bulges on notes"),
    ]
}
