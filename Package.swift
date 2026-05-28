// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "iQualize",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "iQualize",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/iQualize",
            exclude: ["Info.plist"],
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
        // process, the main app's AVAudioEngine output to the AirPods is
        // preemptible by Continuity (just like Spotify).
        .executableTarget(
            name: "iQualizeCapture",
            path: "Sources/iQualizeCapture",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        // Requires Xcode (not just Command Line Tools) for XCTest
        // .testTarget(
        //     name: "iQualizeTests",
        //     dependencies: ["iQualize"],
        //     path: "Tests/iQualizeTests"
        // ),
    ],
    swiftLanguageModes: [.v6]
)
