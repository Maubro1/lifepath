// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Diary",
    // macOS so `swift test` runs on the CI host.
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "Diary", targets: ["Diary"])],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.1.0"),
    ],
    targets: [
        .target(name: "Diary", dependencies: [
            "Core",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "DiaryTests", dependencies: ["Diary", "Core"]),
    ]
)
