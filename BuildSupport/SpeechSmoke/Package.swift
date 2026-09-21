// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SpeechSmoke",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpeechSmoke", targets: ["SpeechSmoke"]),
        .executable(name: "SpeechBench", targets: ["SpeechBench"]),
        .executable(name: "SpeechLifecycle", targets: ["SpeechLifecycle"]),
    ],
    dependencies: [
        .package(path: "../../Packages/LocalSpeech"),
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
    ],
    targets: [
        .executableTarget(name: "SpeechSmoke", dependencies: ["LocalSpeech"]),
        .executableTarget(name: "SpeechLifecycle", dependencies: ["LocalSpeech"]),
        .executableTarget(
            name: "SpeechBench",
            dependencies: [
                "LocalSpeech",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ]),
    ]
)
