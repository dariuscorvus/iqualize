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
        // Requires Xcode (not just Command Line Tools) for XCTest
        // .testTarget(
        //     name: "iQualizeTests",
        //     dependencies: ["iQualize"],
        //     path: "Tests/iQualizeTests"
        // ),
    ],
    swiftLanguageModes: [.v6]
)
