// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VisualSynth",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VisualSynth",
            path: "Sources/VisualSynth",
            exclude: ["Shaders"]
        )
    ]
)
