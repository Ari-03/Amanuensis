// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AmanuensisCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "AmanuensisCore", targets: ["AmanuensisCore"])],
    targets: [
        .target(
            name: "AmanuensisCore",
            path: "Amanuensis",
            exclude: [
                "Assets.xcassets", "Views", "Audio", "Inference", "Models", "Network", "Platform",
                "App", "ContentView.swift", "AmanuensisApp.swift",
            ],
            sources: ["Core", "Storage"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AmanuensisCoreTests", dependencies: ["AmanuensisCore"], path: "Tests",
            exclude: ["Storage", "Network", "Platform", "Inference"]
        ),
    ]
)
