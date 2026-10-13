import AppKit
import MetalKit
import SwiftUI

enum Shared {
    static let engine = Engine()
    static var midi: MIDIInput?
    static weak var renderer: Renderer?
}

struct VisualSynthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Visual Synth") {
            RootView()
                .environment(Shared.engine)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandMenu("Visuals") {
                Button("Show / Hide Panel  (Tab)") { Shared.engine.showPanel.toggle() }
                Button("Reload Shaders") { Shared.renderer?.reloadShaders() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Save Preset…") { Presets.save() }.keyboardShortcut("s", modifiers: .command)
                Button("Open Preset…") { Presets.open() }.keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Shared.engine.load()
        Shared.midi = MIDIInput(engine: Shared.engine)
        ScrollRouter.shared.install()
        KeyboardInput.install(engine: Shared.engine)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Shared.engine.save() }
        if let path = ProcessInfo.processInfo.environment["VISUALSYNTH_DEBUG"] { Debug.start(snapshot: path) }
    }

    func applicationWillTerminate(_ notification: Notification) { Shared.engine.save() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        HStack(spacing: 0) {
            MetalView(engine: engine)
                .ignoresSafeArea()
            if engine.showPanel {
                ControlPanel()
                    .frame(width: 340)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.black)
        .animation(.easeOut(duration: 0.15), value: engine.showPanel)
    }
}

struct MetalView: NSViewRepresentable {
    let engine: Engine

    func makeCoordinator() -> Renderer {
        let r = Renderer(device: MTLCreateSystemDefaultDevice()!, engine: engine)
        Shared.renderer = r
        return r
    }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.autoResizeDrawable = true          // drawable = view size × backing scale (Retina)
        v.preferredFramesPerSecond = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 120
        v.enableSetNeedsDisplay = false
        v.isPaused = false
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

/// Scrolling over a slider changes it (instead of scrolling the panel).
final class ScrollRouter {
    static let shared = ScrollRouter()
    weak var hovered: Param?
    private var monitor: Any?

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let p = self?.hovered else { return e }
            p.nudge(with: e)
            return nil
        }
    }
}

/// Keys: Tab panel · Space pulse · A S D F G H J K play notes (no MIDI device needed).
enum KeyboardInput {
    static let keys: [String: Int] = ["a": 60, "s": 62, "d": 64, "f": 65, "g": 67, "h": 69, "j": 71, "k": 72, " ": 60]

    static func install(engine: Engine) {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            if e.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return e }
            if e.window?.firstResponder is NSText { return e }
            if e.keyCode == 48 {    // Tab
                if e.type == .keyDown { engine.showPanel.toggle() }
                return nil
            }
            if e.keyCode == 53, e.type == .keyDown { // Esc cancels MIDI learn
                engine.learning = nil
                return nil
            }
            guard let ch = e.charactersIgnoringModifiers?.lowercased(), let n = keys[ch] else { return e }
            if e.type == .keyDown {
                if !e.isARepeat { engine.noteOn(n, velocity: 100) }
            } else {
                engine.noteOff(n)
            }
            return nil
        }
    }
}

enum Presets {
    static func save() {
        let panel = NSSavePanel()
        panel.directoryURL = Engine.presetsDir
        panel.nameFieldStringValue = "Preset.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { Shared.engine.save(to: url) }
    }

    static func open() {
        let panel = NSOpenPanel()
        panel.directoryURL = Engine.presetsDir
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { Shared.engine.load(from: url) }
    }
}

/// VISUALSYNTH_DEBUG=/path/prefix: log stats every 2 s and save a snapshot of the window's UI.
enum Debug {
    static func start(snapshot prefix: String) {
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let e = Shared.engine
            print(String(format: "fps %.1f  gpu %.2f ms  %@  midi: %@", e.fps, e.gpuMs, e.resolution,
                         e.midiDevices.joined(separator: ", ")))
            fflush(stdout)
            guard let view = NSApp.windows.first?.contentView else { return }
            n += 1
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)\(n).png"))
        }
    }
}
