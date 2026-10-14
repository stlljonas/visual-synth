import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Saved scenes: one JSON file each in Engine.scenesDir (a Snapshot with its name and a thumbnail inside,
/// so a scene can be exported and imported as a single file). Numbered in the order they were saved:
/// keys 1–9 and MIDI program change 0–8 recall the first nine.
@Observable
final class SceneLibrary {
    struct Entry: Identifiable {
        let url: URL
        var name: String
        var thumbnail: NSImage?
        var id: URL { url }
    }

    private(set) var entries: [Entry] = []
    /// The scene loaded last (highlighted in the panel).
    var current: URL?
    @ObservationIgnored private let engine: Engine
    /// Small PNG of the current picture, provided by the renderer.
    @ObservationIgnored var thumbnailProvider: (() -> Data?)?

    init(engine: Engine) {
        self.engine = engine
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Engine.scenesDir, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.pathExtension == "json" } ?? []
        let dated = urls.map { u in
            (u, (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        entries = dated.sorted { $0.1 < $1.1 }.compactMap { u, _ in
            guard let s = Self.read(u) else { return nil }
            let img = s.thumbnail.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            return Entry(url: u, name: s.name ?? u.deletingPathExtension().lastPathComponent, thumbnail: img)
        }
    }

    static func read(_ url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func write(_ s: Snapshot, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // existing files are rewritten in place: an atomic replace would give them a new creation date, and that's
        // what numbers the scenes
        let exists = FileManager.default.fileExists(atPath: url.path)
        if let data = try? enc.encode(s) { try? data.write(to: url, options: exists ? [] : .atomic) }
    }

    private func currentSnapshot(named name: String) -> Snapshot {
        var s = engine.snapshot()
        s.name = name
        s.thumbnail = thumbnailProvider?()?.base64EncodedString()
        return s
    }

    private func freeURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = Engine.scenesDir.appendingPathComponent(safe).appendingPathExtension("json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Engine.scenesDir.appendingPathComponent("\(safe) \(n)").appendingPathExtension("json")
            n += 1
        }
        return url
    }

    /// Save what's on screen now as a new scene.
    @discardableResult
    func saveNew(name: String? = nil) -> URL {
        let name = name ?? "Scene \(entries.count + 1)"
        let url = freeURL(for: name)
        write(currentSnapshot(named: name), to: url)
        current = url
        reload()
        return url
    }

    /// Replace a scene with what's on screen now (keeps its name and number).
    func update(_ e: Entry) {
        write(currentSnapshot(named: e.name), to: e.url)
        current = e.url
        reload()
    }

    func load(_ e: Entry) {
        guard let s = Self.read(e.url) else { return }
        let fade = Double(engine.master.param("scenefade")!.value)
        engine.applyScene(s, fade: fade)
        current = e.url
        if s.thumbnail == nil {
            // older presets and imports have no picture yet: take one once the scene has faded in
            DispatchQueue.main.asyncAfter(deadline: .now() + fade + 1) { [weak self] in
                guard let self, self.current == e.url, var s = Self.read(e.url), s.thumbnail == nil,
                      let png = self.thumbnailProvider?() else { return }
                s.thumbnail = png.base64EncodedString()
                self.write(s, to: e.url)
                self.reload()
            }
        }
    }

    func load(index: Int) {
        guard entries.indices.contains(index) else { return }
        load(entries[index])
    }

    func rename(_ e: Entry, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, var s = Self.read(e.url) else { return }
        s.name = name
        write(s, to: e.url)      // the file keeps its place (creation date) in the numbering
        reload()
    }

    func delete(_ e: Entry) {
        try? FileManager.default.trashItem(at: e.url, resultingItemURL: nil)
        if current == e.url { current = nil }
        reload()
    }

    func export(_ e: Entry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = e.name + ".json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: e.url, to: dest)
    }

    /// Import scene files (also accepts presets saved by older versions); returns how many worked.
    @discardableResult
    func importFiles() -> Int {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return 0 }
        var n = 0
        for src in panel.urls {
            guard var s = Self.read(src) else { continue }
            let name = s.name ?? src.deletingPathExtension().lastPathComponent
            s.name = name
            write(s, to: freeURL(for: name))
            n += 1
        }
        reload()
        return n
    }

    func revealInFinder(_ e: Entry? = nil) {
        if let e { NSWorkspace.shared.activateFileViewerSelecting([e.url]) } else { NSWorkspace.shared.open(Engine.scenesDir) }
    }
}
