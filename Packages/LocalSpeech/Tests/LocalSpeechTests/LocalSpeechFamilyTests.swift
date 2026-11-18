import Foundation
import Testing

@testable import LocalSpeech

/// The app's catalog names local speech families by string, so a typo or a claim the runtime cannot
/// keep would only show at record time. These read the catalog file the app bundles.
@Test func everyLocalSpeechRowInTheAppCatalogNamesAFamilyThatCanRunIt() throws {
    let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Amanuensis/Models/ModelCatalog.json")
    let rows = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [[String: Any]])
    let local = rows.filter { $0["location"] as? String == "local" && $0["purpose"] as? String == "speech" }
    #expect(local.count > 3)
    for row in local {
        let family = try LocalSpeechFamily.named(row["family"] as? String ?? "")
        if row["detectsLanguage"] as? Bool == true {
            #expect(family.detectsLanguage, "\(row["id"] ?? "") claims detection \(family.name) lacks")
        }
        // A runtime that falls back silently, such as Nemotron to detection, must get a key it knows.
        guard let accepted = family.languageArguments else { continue }
        let declared: [String?] = (row["languages"] as? [String] ?? []).map(Optional.some)
        let codes = declared + (family.detectsLanguage ? [nil] : [])
        for code in codes {
            // No argument at all is how some runtimes are asked to detect.
            guard let argument = family.languageArgument(code) else { continue }
            #expect(
                accepted.contains(argument),
                "\(row["id"] ?? "") sends \(argument) for \(code ?? "detection"), which \(family.name) lacks")
        }
    }
}

@Test func familiesThatCannotDetectRefuseToRunWithoutALanguage() async {
    let engine = LocalSpeechEngine()
    await #expect(throws: LocalSpeechError.languageRequired("Whisper")) {
        try await engine.transcribe(
            audioURL: URL(fileURLWithPath: "/nonexistent.wav"),
            modelDirectory: URL(fileURLWithPath: "/nonexistent-model"), family: "whisper", language: nil)
    }
}

@Test func nemoConfigurationsWithNonFiniteNumbersAreRecognized() throws {
    let parakeet = try LocalSpeechFamily.named("parakeet")
    try parakeet.checkConfiguration(
        Data(#"{"encoder":{"x":-Infinity},"decoder":{"vocabulary":["a"]},"y":NaN}"#.utf8))
    #expect(throws: LocalSpeechError.unrecognizedConfiguration("Parakeet")) {
        try parakeet.checkConfiguration(Data(#"{"encoder":{},"decoder":{"vocabulary":[]}}"#.utf8))
    }
    #expect(throws: LocalSpeechError.unrecognizedConfiguration("Moonshine")) {
        try LocalSpeechFamily.named("moonshine").checkConfiguration(Data(#"{"model_type":"whisper"}"#.utf8))
    }
}

@Test func runtimesReceiveTheLanguageInTheirOwnForm() throws {
    #expect(try LocalSpeechFamily.named("whisper").languageArgument("jv") == "jw")
    #expect(try LocalSpeechFamily.named("moonshine").languageArgument("en") == nil)
    let qwen = try LocalSpeechFamily.named("qwen3asr")
    #expect(qwen.languageArgument("ja") == "Japanese")
    #expect(qwen.languageArgument("tl") == "Filipino")
    #expect(qwen.languageArgument(nil) == nil)
    let nemotron = try LocalSpeechFamily.named("nemotron")
    #expect(nemotron.languageArgument(nil) == "auto")
    #expect(nemotron.languageArgument("zh") == "zh-CN")
    #expect(nemotron.languageArgument("ja") == "ja-JP")
}

@Test func downloadsAndSnapshotsKeepTheSameFiles() {
    for name in ["config.json", "model.safetensors", "merges.txt", "tokenizer.model", "tokenizer.vocab"] {
        #expect(LocalSpeechFamily.isModelFile(name), "\(name)")
    }
    for name in ["model.fp32.safetensors", "README.md", "canary.nemo", "model_config.yaml"] {
        #expect(!LocalSpeechFamily.isModelFile(name), "\(name)")
    }
}
