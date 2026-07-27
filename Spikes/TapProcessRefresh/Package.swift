// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "TapProcessRefresh",
    // 14.2, not 14.0 — CATap (AudioHardwareCreateProcessTap) landed in 14.2.
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "TapProcessRefresh",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/TapProcessRefresh/Info.plist",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
