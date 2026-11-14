// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Core",
    // macOS so `swift test` runs on the CI host.
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
