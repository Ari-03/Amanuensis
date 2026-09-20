import Foundation
import Testing

@testable import LocalSpeech

@Test func rejectsUnknownFamily() {
    #expect(throws: LocalSpeechError.self) { try ModelFamily(validating: "unknown") }
}

@Test func missingWhisperTokenizerFailsBeforeLoadingWeights() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
    try Data([1]).write(to: directory.appendingPathComponent("model.safetensors"))

    do {
        _ = try LocalModelFiles(source: directory, family: .whisper)
        Issue.record("Incomplete Whisper folder was accepted")
    } catch LocalSpeechError.missingModelFile(let name) {
        #expect(name == "tokenizer.json")
    }
}

@Test func snapshotKeepsTokenizerWhenOriginalDisappears() throws {
    let source = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: source) }
    for filename in ModelFamily.whisper.requiredMetadata {
        try Data("{}".utf8).write(to: source.appendingPathComponent(filename))
    }
    try Data([1]).write(to: source.appendingPathComponent("model.safetensors"))
    let snapshot = try LocalModelFiles(source: source, family: .whisper)
    defer { snapshot.remove() }
    try FileManager.default.removeItem(at: source.appendingPathComponent("tokenizer.json"))

    #expect(
        FileManager.default.fileExists(
            atPath: snapshot.directory.appendingPathComponent("tokenizer.json").path))
    let weightURL = snapshot.directory.appendingPathComponent("model.safetensors")
    #expect(try Data(contentsOf: weightURL) == Data([1]))
}

@Test func requiresCohereSentencePieceModel() throws {
    let source = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: source) }
    try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
    do {
        _ = try LocalModelFiles.validate(directory: source, family: .cohere)
        Issue.record("Cohere folder without tokenizer was accepted")
    } catch LocalSpeechError.missingModelFile(let name) {
        #expect(name == "tokenizer.model")
    }
}

@Test func cancelWithoutActiveRequestIsSafe() async {
    let engine = LocalSpeechEngine()
    engine.cancel()
    await #expect(throws: LocalSpeechError.self) {
        try await engine.transcribe(
            audioURL: URL(fileURLWithPath: "/nonexistent.wav"),
            modelDirectory: URL(fileURLWithPath: "/nonexistent-model"), family: "unknown"
        )
    }
}

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}
