# Visual Synth

Generative visuals for music, native on macOS (Swift + Metal), driven by USB MIDI.

Repeating elements (layers: bars, shapes, …) are drawn on the GPU and run through a chain
of effects, the visual equivalents of synth FX (echo = video feedback, chorus = chroma split, …).
Every parameter is a slider: drag it, scroll on it (⌥ for fine), double-click to reset,
right-click → MIDI Learn to map a knob.

## Run

    swift run -c release            # dev: shaders reload live when you edit Sources/VisualSynth/Shaders/*.metal
    scripts/make-app.sh             # builds VisualSynth.app (double-clickable)

Keys: Tab hides the panel · Space and A S D F G H J K play notes (no MIDI device needed) ·
⌃⌘F full screen · ⌘S / ⌘O save / open presets · Esc cancels MIDI learn.

MIDI: every source is connected automatically (hot-plug). Notes drive the pulse envelope
(Master › Note decay) used by "Note gate", "Pulse …" and "Note kick" params; MIDI clock sets the tempo.

## Adding a layer or effect

1. Add a `ModuleSpec` to `Generators.swift` or `Effects.swift` (params land in the shader as `p[0…15]`).
2. Write `gen_<id>` / `fx_<id>` in `Shaders/Generators.metal` / `Shaders/Effects.metal`
   following the conventions at the top of `Shaders/Common.metal`.
3. Check: `swift build && .build/debug/VisualSynth --check`, look at it:
   `.build/debug/VisualSynth --render out.png --only bars,<id> --notes`, and time it:
   `.build/debug/VisualSynth --bench --all --size 2560x1664`.
