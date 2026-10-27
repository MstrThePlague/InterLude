// swift-tools-version: 6.2
import PackageDescription

// InterLudeCore is portable Swift and builds on macOS, Linux and Windows. InterLudePortable holds the platform
// implementations that work away from the Mac, and builds on all three too. InterLudeHTTP is the web server on
// Hummingbird, and InterLudeML runs the speech models (ONNX Runtime and whisper.cpp); both are for macOS and Linux,
// and interlude-server runs on both. Everything that needs Apple's
// frameworks (their implementations, the menu bar app and the measuring tools) is declared only when building on macOS.
var targets: [Target] = [
    .target(name: "InterLudeCore", path: "Sources/InterLudeCore"),
    .target(name: "InterLudePortable", dependencies: ["InterLudeCore"], path: "Sources/InterLudePortable"),
    .target(name: "InterLudeHTTP", dependencies: ["InterLudeCore", .product(name: "Hummingbird", package: "hummingbird")],
            path: "Sources/InterLudeHTTP"),
    .systemLibrary(name: "COnnxRuntime", path: "Sources/COnnxRuntime", pkgConfig: "libonnxruntime",
                   providers: [.brew(["onnxruntime"])]),
    .systemLibrary(name: "CGGML", path: "Sources/CGGML", pkgConfig: "ggml", providers: [.brew(["ggml"])]),
    .systemLibrary(name: "CWhisper", path: "Sources/CWhisper", pkgConfig: "whisper", providers: [.brew(["whisper.cpp"])]),
    .target(name: "InterLudeML", dependencies: ["InterLudeCore", "COnnxRuntime", "CGGML", "CWhisper"], path: "Sources/InterLudeML"),
    .executableTarget(name: "interlude-server", dependencies: ["InterLudeCore", "InterLudePortable", "InterLudeHTTP", "InterLudeML"],
                      path: "Sources/InterLudeServer"),
    .testTarget(name: "InterLudeCoreTests", dependencies: ["InterLudeCore"], path: "Tests/InterLudeCoreTests"),
    .testTarget(name: "InterLudePortableTests", dependencies: ["InterLudeCore", "InterLudePortable", "InterLudeHTTP", "InterLudeML"],
                path: "Tests/InterLudePortableTests"),
]

#if os(macOS)
let apple: [Target.Dependency] = ["InterLudeCore", "InterLudeApple"]
targets += [
    .target(name: "InterLudeApple", dependencies: ["InterLudeCore"], path: "Sources/InterLudeApple"),
    .executableTarget(name: "InterLude", dependencies: apple, path: "Sources/InterLudeApp"),
    .executableTarget(name: "spike01-stream", path: "Tools/Spike01Stream"),
    .executableTarget(name: "record", dependencies: ["InterLudeCore"], path: "Tools/Record"),
    .executableTarget(name: "classify", dependencies: apple + ["InterLudeML"], path: "Tools/Classify"),
    .executableTarget(name: "evaluate", dependencies: ["InterLudeCore"], path: "Tools/Evaluate"),
    .executableTarget(name: "serve", dependencies: apple, path: "Tools/Serve"),
    .executableTarget(name: "cast-spike", dependencies: apple, path: "Tools/CastSpike"),
    .executableTarget(name: "ident-check", dependencies: apple + ["InterLudePortable"], path: "Tools/IdentCheck"),
    .executableTarget(name: "voice-changes", dependencies: apple, path: "Tools/VoiceChanges"),
    .executableTarget(name: "presenter-check", dependencies: apple, path: "Tools/PresenterCheck"),
    .executableTarget(name: "signoff-check", dependencies: apple + ["InterLudeML"], path: "Tools/SignoffCheck"),
    .executableTarget(name: "rms-poll", path: "Tools/RmsPoll"),
    .testTarget(name: "InterLudeAppleTests", dependencies: apple, path: "Tests/InterLudeAppleTests"),
]
#endif

let package = Package(
    name: "InterLude",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0")],
    targets: targets
)
