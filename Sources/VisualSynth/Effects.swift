/// Effects: a chain of full-screen passes, applied in list order (reorderable in the UI).
/// Each one has a fragment function `fx_<id>` in Shaders/Effects.metal;
/// its params arrive as `p[0]`, `p[1]`, … in the order listed here. Mix is added automatically.
enum Effects {
    static let all: [ModuleSpec] = [
        ModuleSpec(id: "echo", name: "Echo (feedback)", kind: .effect, function: "fx_echo", params: [
            .range("feedback", "Feedback", 0, 0.99, 0.85, help: "How long trails last"),
            .range("zoom", "Zoom", -0.05, 0.05, 0.005, help: "Per frame; positive zooms trails outward"),
            .range("rotate", "Rotate", -90, 90, 0, unit: "°/s"),
            .range("dx", "Drift X", -1, 1, 0),
            .range("dy", "Drift Y", -1, 1, 0),
            .range("hue", "Hue shift", -0.5, 0.5, 0, help: "Each echo shifts colour"),
            .choice("mode", "Combine", ["Max", "Add"]),
        ], help: "Video feedback: like a delay, each frame repeats the last one, transformed"),
        ModuleSpec(id: "chroma", name: "Chroma Split (chorus)", kind: .effect, function: "fx_chroma", params: [
            .range("amount", "Amount", 0, 0.05, 0.006),
            .range("angle", "Angle", -180, 180, 0, unit: "°"),
            .range("rate", "LFO rate", 0, 4, 0.5, unit: "/beat"),
            .range("depth", "LFO depth", 0, 1, 0.5),
            .range("pulse", "Note kick", 0, 1, 0.5, help: "Split widens on each note"),
        ], help: "Separates red / green / blue like detuned voices"),
    ]
}
