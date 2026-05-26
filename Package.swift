// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoEditor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "VideoEditorLib",
            path: "Sources/VideoEditor",
            exclude: ["App/main.swift"],
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreText")
            ]
        ),
        .executableTarget(
            name: "VideoEditor",
            dependencies: ["VideoEditorLib"],
            path: "Sources/VideoEditorMain",
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreText")
            ]
        ),
        .testTarget(
            name: "VideoEditorTests",
            dependencies: ["VideoEditorLib"],
            path: "Tests/VideoEditorTests",
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreText")
            ]
        )
    ]
)
