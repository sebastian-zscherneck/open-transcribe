// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenTranscribe",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OpenTranscribeCore", targets: ["OpenTranscribeCore"]),
        .executable(name: "opentranscribed", targets: ["opentranscribed"]),
        .executable(name: "otcli", targets: ["otcli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.6.0"),
        // Command Line Tools ship no Swift Testing module, so the package supplies it.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.3.1"),
    ],
    targets: [
        .target(
            name: "OpenTranscribeCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "opentranscribed", dependencies: ["OpenTranscribeCore"]),
        .executableTarget(name: "otcli", dependencies: ["OpenTranscribeCore"]),
        .testTarget(
            name: "OpenTranscribeCoreTests",
            dependencies: ["OpenTranscribeCore", .product(name: "Testing", package: "swift-testing")]
        ),
    ]
)
