// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioRecorder",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AudioRecorderLib", targets: ["AudioRecorderLib"]),
    ],
    targets: [
        .target(
            name: "AudioRecorderLib",
            path: "Sources/Lib",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "AudioRecorder",
            dependencies: ["AudioRecorderLib"],
            path: "Sources/App",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(
            name: "AudioRecorderTests",
            dependencies: ["AudioRecorderLib"],
            path: "Tests/Unit"
        ),
        .executableTarget(
            name: "AudioRecorderIntegration",
            dependencies: ["AudioRecorderLib"],
            path: "Tests/Integration"
        ),
        .executableTarget(
            name: "AudioRecorderStress",
            dependencies: ["AudioRecorderLib"],
            path: "Tests/Stress"
        ),
    ]
)
