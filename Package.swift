// swift-tools-version: 6.2
//
//  Package.swift
//  InterLude
//
//  How the modules fit together:
//
//  - InterLudeCore is portable Swift: stream handling, detection, playout, the web app's contract, and the Cast and
//    Sonos protocols. It builds on macOS, Linux and Windows.
//  - InterLudePortable decodes and encodes audio with ffmpeg, for platforms without Apple's frameworks.
//  - InterLudeHTTP is the web server on Hummingbird; InterLudeML runs the open speech models (ONNX Runtime and
//    whisper.cpp); InterLudeCast casts over SwiftNIO. All three are for macOS and Linux, as is interlude-server.
//  - Everything that needs Apple's frameworks (their implementations, the menu bar app and the measuring tools) is
//    declared only when building on macOS.

import PackageDescription

var targets: [Target] = [
    .target(name: "InterLudeCore", path: "Sources/InterLudeCore"),
    .target(name: "InterLudePortable", dependencies: ["InterLudeCore"], path: "Sources/InterLudePortable"),
    .target(name: "InterLudeHTTP", dependencies: ["InterLudeCore", .product(name: "Hummingbird", package: "hummingbird")],
            path: "Sources/InterLudeHTTP"),
    // The C libraries the speech models need, found with pkg-config.
    .systemLibrary(name: "COnnxRuntime", path: "Sources/COnnxRuntime", pkgConfig: "libonnxruntime",
                   providers: [.brew(["onnxruntime"])]),
    .systemLibrary(name: "CGGML", path: "Sources/CGGML", pkgConfig: "ggml", providers: [.brew(["ggml"])]),
    .systemLibrary(name: "CWhisper", path: "Sources/CWhisper", pkgConfig: "whisper", providers: [.brew(["whisper.cpp"])]),
    .target(name: "InterLudeML", dependencies: ["InterLudeCore", "COnnxRuntime", "CGGML", "CWhisper"], path: "Sources/InterLudeML"),
    .target(name: "InterLudeCast", dependencies: ["InterLudeCore", .product(name: "NIOCore", package: "swift-nio"),
                                                  .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl")],
            path: "Sources/InterLudeCast"),
    .executableTarget(name: "interlude-server", dependencies: ["InterLudeCore", "InterLudePortable", "InterLudeHTTP", "InterLudeML", "InterLudeCast"],
                      path: "Sources/InterLudeServer"),
    .testTarget(name: "InterLudeCoreTests", dependencies: ["InterLudeCore"], path: "Tests/InterLudeCoreTests"),
    // The fixture is read from the source tree by path, so it isn't bundled.
    .testTarget(name: "InterLudePortableTests", dependencies: ["InterLudeCore", "InterLudePortable", "InterLudeHTTP", "InterLudeML", "InterLudeCast"],
                path: "Tests/InterLudePortableTests", exclude: ["Fixtures"]),
]

#if os(macOS)
let apple: [Target.Dependency] = ["InterLudeCore", "InterLudeApple"]
targets += [
    .target(name: "InterLudeApple", dependencies: ["InterLudeCore"], path: "Sources/InterLudeApple"),
    .executableTarget(name: "InterLude", dependencies: apple, path: "Sources/InterLudeApp"),
    // Command-line tools for measuring and tuning detection (README, "Tools").
    .executableTarget(name: "record", dependencies: ["InterLudeCore"], path: "Tools/Record"),
    .executableTarget(name: "classify", dependencies: apple + ["InterLudeML"], path: "Tools/Classify"),
    .executableTarget(name: "evaluate", dependencies: ["InterLudeCore"], path: "Tools/Evaluate"),
    .executableTarget(name: "ident-check", dependencies: apple + ["InterLudePortable"], path: "Tools/IdentCheck"),
    .executableTarget(name: "signoff-check", dependencies: apple + ["InterLudeML"], path: "Tools/SignoffCheck"),
    .testTarget(name: "InterLudeAppleTests", dependencies: apple, path: "Tests/InterLudeAppleTests"),
]
#endif

let package = Package(
    name: "InterLude",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
    ],
    targets: targets
)
