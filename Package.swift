// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoEditor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VideoEditor",
            path: "Sources/VideoEditor",
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreText")
            ]
        )
    ]
)
