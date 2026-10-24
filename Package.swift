// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "APOD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "APOD", targets: ["APOD"]),
    ],
    targets: [
        .target(name: "APODCore"),
        .executableTarget(name: "APOD", dependencies: ["APODCore"]),
        .testTarget(name: "APODCoreTests", dependencies: ["APODCore"]),
    ],
    swiftLanguageModes: [.v5]
)
