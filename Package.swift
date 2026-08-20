// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIRecorderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .executable(name: "recorder-core-check", targets: ["RecorderCoreCheck"])
    ],
    targets: [
        .target(name: "RecorderCore"),
        .executableTarget(name: "RecorderCoreCheck", dependencies: ["RecorderCore"])
    ]
)
