// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HushType",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/Settings", from: "3.1.2"),
        .package(url: "https://github.com/felixfu824/speech-swift.git", revision: "d603472b11c21f5fb6492e9448a04ee669d0bf64"),
        // Direct mlx-swift dep so live caption can bound the GPU buffer cache
        // (MLX.GPU.set(cacheLimit:) / clearCache) — speech-swift transitively
        // depends on the same version, so SwiftPM resolves a single copy.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
    ],
    targets: [
        .executableTarget(
            name: "HushType",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Settings", package: "Settings"),
            ],
            path: "Sources/HushType",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "HushTypeTests",
            dependencies: ["HushType"],
            path: "Tests/HushTypeTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
