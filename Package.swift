// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "iQualize",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "IQControlProtocol",
            path: "Sources/IQControlProtocol"
        ),
        // C shim for the capture ring's cross-process head publication
        // (#133): release-store / acquire-load on the shared header's 64-bit
        // head fields. C because the macOS 14 floor rules out
        // Synchronization.Atomic and swift-atomics is a heavy dependency for
        // four functions.
        .target(
            name: "IQRingAtomics",
            path: "Sources/IQRingAtomics"
        ),
        // Named "iqualize-cli", not "iqualize" — a same-named target would collide with
        // the "iQualize" app target's binary on macOS's default case-insensitive filesystem.
        // install.sh renames the built binary to "iqualize" when it copies it into place.
        .executableTarget(
            name: "iqualize-cli",
            dependencies: [
                "IQControlProtocol",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/iqualize-cli"
        ),
        .executableTarget(
            name: "iQualize",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                "IQControlProtocol",
                "IQRingAtomics",
            ],
            path: "Sources/iQualize",
            exclude: ["Info.plist", "AppIcon.icns"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("Accelerate"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/iQualize/Info.plist",
                ]),
            ]
        ),
        // Capture helper — owns the CATap + aggregate IOProc so that the main
        // iQualize process is not the one Continuity sees as the audio
        // observer. With the tap-owning process separated from the rendering
        // process, the main app's AVAudioEngine output is preemptible by
        // Continuity (just like Spotify). See docs/CONTINUITY.md.
        .executableTarget(
            name: "iQualizeCapture",
            dependencies: ["IQRingAtomics"],
            path: "Sources/iQualizeCapture",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        // Needs full Xcode for XCTest — Command Line Tools alone can't build
        // the test bundle.
        .testTarget(
            name: "iQualizeTests",
            dependencies: ["iQualize"],
            path: "Tests/iQualizeTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
