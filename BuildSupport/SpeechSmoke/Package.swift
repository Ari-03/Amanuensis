// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SpeechSmoke",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SpeechSmoke", targets: ["SpeechSmoke"])],
    dependencies: [.package(path: "../../Packages/LocalSpeech")],
    targets: [
        .executableTarget(name: "SpeechSmoke", dependencies: ["LocalSpeech"])
    ]
)
