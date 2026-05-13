// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HushType",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", branch: "main"),
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
            ],
            path: "Sources/HushType",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
