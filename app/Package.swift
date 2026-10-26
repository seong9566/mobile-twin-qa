// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QATwin",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "QATwinCore", targets: ["QATwinCore"]),
        .executable(name: "QATwinApp", targets: ["QATwinApp"]),
    ],
    targets: [
        .target(name: "QATwinCore"),
        .executableTarget(
            name: "QATwinApp",
            dependencies: ["QATwinCore"],
            // SwiftUI VideoPlayer가 쓰는 AVPlayerView를 실행 시 찾을 수 있게 명시적으로 링크한다.
            linkerSettings: [.linkedFramework("AVKit")]
        ),
        .testTarget(
            name: "QATwinCoreTests",
            dependencies: ["QATwinCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
