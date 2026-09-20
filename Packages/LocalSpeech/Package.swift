// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "LocalSpeech",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LocalSpeech", targets: ["LocalSpeech"])],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            exact: "0.31.6"
        ),
    ],
    targets: [
        .target(
            name: "LocalSpeech",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .testTarget(name: "LocalSpeechTests", dependencies: ["LocalSpeech"]),
    ],
    swiftLanguageModes: [.v6]
)
