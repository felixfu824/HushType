// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VoxKey",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "VoxKey",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ],
            path: "Sources/VoxKey",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
