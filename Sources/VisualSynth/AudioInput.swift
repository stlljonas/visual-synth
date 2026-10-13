import Foundation

/// Listens to the Mac's own audio output (Spotify, YouTube, …) and feeds the engine:
/// beat tracking → `engine.audioTempo(bpm:beatTime:confidence:)`, band levels → `engine.bass/mid/high/level`.
/// Started and stopped by the "Sync to Mac audio" switch (`engine.audioEnabled`).
final class AudioInput {
    private let engine: Engine

    init(engine: Engine) {
        self.engine = engine
    }

    func start() {
        engine.audioStatus = "not implemented yet"
    }

    func stop() {}
}
