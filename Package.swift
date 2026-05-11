// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ShotMark",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "ShotMark", targets: ["ShotMark"])
    ],
    targets: [
        .executableTarget(
            name: "ShotMark",
            path: "Sources/ShotMark",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Translation"),
                .linkedFramework("_Translation_SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Vision")
            ]
        )
    ]
)
