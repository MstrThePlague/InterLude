// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InterLude",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "InterLudeCore", path: "Sources/InterLudeCore"),
        .executableTarget(name: "InterLude", dependencies: ["InterLudeCore"], path: "Sources/InterLudeApp"),
        .executableTarget(name: "spike01-stream", path: "Tools/Spike01Stream"),
        .executableTarget(name: "record", dependencies: ["InterLudeCore"], path: "Tools/Record"),
        .executableTarget(name: "classify", dependencies: ["InterLudeCore"], path: "Tools/Classify"),
        .executableTarget(name: "evaluate", dependencies: ["InterLudeCore"], path: "Tools/Evaluate"),
        .executableTarget(name: "serve", dependencies: ["InterLudeCore"], path: "Tools/Serve"),
        .executableTarget(name: "cast-spike", dependencies: ["InterLudeCore"], path: "Tools/CastSpike"),
        .executableTarget(name: "ident-check", dependencies: ["InterLudeCore"], path: "Tools/IdentCheck"),
        .executableTarget(name: "voice-changes", dependencies: ["InterLudeCore"], path: "Tools/VoiceChanges"),
        .executableTarget(name: "presenter-check", dependencies: ["InterLudeCore"], path: "Tools/PresenterCheck"),
        .executableTarget(name: "signoff-check", dependencies: ["InterLudeCore"], path: "Tools/SignoffCheck"),
        .executableTarget(name: "rms-poll", path: "Tools/RmsPoll"),
        .testTarget(name: "InterLudeCoreTests", dependencies: ["InterLudeCore"], path: "Tests/InterLudeCoreTests"),
    ]
)
