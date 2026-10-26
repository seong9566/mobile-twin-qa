// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QATwin",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "QATwinCore", targets: ["QATwinCore"]),
        .executable(name: "QATwinApp", targets: ["QATwinApp"]),
    ],
    targets: [
        .target(name: "QATwinCore"),
        .executableTarget(
            name: "QATwinApp",
            dependencies: ["QATwinCore"]
        ),
        .testTarget(
            name: "QATwinCoreTests",
            dependencies: ["QATwinCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
