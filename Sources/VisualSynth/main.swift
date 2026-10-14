import AppKit
import Foundation

if let code = Headless.run(CommandLine.arguments) { exit(code) }
Relaunch.ifStartedByAnotherApp()
VisualSynthApp.main()

/// Started as a child of another app (a launcher like Raycast, or a terminal), macOS checks camera access against
/// that app, and the built-in camera then sends only black frames. So the .app restarts itself through Launch
/// Services, as if opened from the Dock. Not for `swift run` (no bundle), or with VISUALSYNTH_NO_RELAUNCH set.
enum Relaunch {
    static func ifStartedByAnotherApp() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", getppid() != 1,
              ProcessInfo.processInfo.environment["VISUALSYNTH_NO_RELAUNCH"] == nil else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = Array(CommandLine.arguments.dropFirst())
        config.environment = ["VISUALSYNTH_NO_RELAUNCH": "1"]   // never loop
        let done = DispatchSemaphore(value: 0)
        var ok = false
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { app, _ in
            ok = app != nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        if ok { exit(0) }   // the new instance takes over; if relaunching failed, just carry on here
    }
}
