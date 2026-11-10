import Foundation
import Testing

@testable import AmanuensisCore

/// Checks `Amanuensis/Models/ModelCatalog.json`, the file the app bundles, against the rules the app
/// relies on. The app decodes it the same way at launch.
struct ModelCatalogTests {
    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Amanuensis/Models/ModelCatalog.json")

    private let models: [ModelDescriptor]

    init() throws {
        models = try ModelDescriptor.catalog(from: Data(contentsOf: Self.catalogURL))
    }

    private func isHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    @Test func idsAreUniqueAndEveryReferencedIDResolves() {
        let ids = models.map(\.id)
        #expect(Set(ids).count == ids.count)
        // Renamed models, and the models new modes start with, must still exist.
        let referenced =
            Array(DictationMode.legacyModelIDs.values)
            + DictationMode.initial.flatMap { [$0.speechModelID, $0.cleanupModelID].compactMap { $0 } }
        for id in referenced { #expect(ids.contains(id), "\(id) is missing from the catalog") }
        for old in DictationMode.legacyModelIDs.keys { #expect(!ids.contains(old)) }
    }

    /// The Models screen shows the summary to tell rows apart, so no two rows may share one.
    @Test func everyRowHasItsOwnSummary() {
        let summaries = models.map(\.summary)
        #expect(Set(summaries).count == summaries.count)
        #expect(!summaries.contains(""))
    }

    @Test func downloadsArePinnedAndSized() {
        // Every model that runs on this Mac from managed files is downloaded.
        let downloadable = models.filter { $0.location == .local }
        #expect(!downloadable.isEmpty)
        for model in downloadable {
            #expect(model.repository != nil, "\(model.id) needs a repository")
            #expect(isHex(model.revision ?? "", length: 40), "\(model.id) needs a 40-hex revision")
            #expect((model.byteCount ?? 0) > 0, "\(model.id) needs its download size")
        }
        for model in models {
            if let sha256 = model.sha256 { #expect(isHex(sha256, length: 64), "\(model.id) checksum") }
            // Only downloads have a size, so the size label never describes something the app cannot fetch.
            if model.repository == nil { #expect(model.byteCount == nil) }
        }
    }

    /// Releases before byte counts require `sizeLabel` on every saved snapshot, so the loader always
    /// sets it, from the byte count, and the file itself never repeats the size.
    @Test func snapshotsKeepTheSizeLabelOlderReleasesRequire() throws {
        let raw =
            try JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalogURL)) as? [[String: Any]]
        #expect(raw?.allSatisfy { $0["sizeLabel"] == nil } == true)
        let parakeet = try #require(models.first { $0.id == "parakeet-v2" })
        #expect(parakeet.sizeLabel == ModelDescriptor.formatBytes(parakeet.byteCount ?? 0))
        for model in models {
            let encoded =
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any]
            #expect(encoded?["sizeLabel"] is String, "\(model.id) must write sizeLabel")
        }
    }

    @Test func speechModelsDeclareTheirLanguages() {
        for model in models {
            guard let languages = model.languages else {
                Issue.record("\(model.id) must declare languages; nil is reserved for old snapshots")
                continue
            }
            #expect(Set(languages).count == languages.count)
            for code in languages {
                #expect(code.count >= 2 && code.count <= 3 && code.allSatisfy(\.isLowercase), "\(code)")
                #expect(Locale(identifier: "en").localizedString(forLanguageCode: code) != nil, "\(code)")
            }
            guard model.purpose == .speech else { continue }
            // Local speech models list what they handle. Providers and macOS decide for the rest.
            #expect(languages.isEmpty == (model.location != .local), "\(model.id) languages")
            if model.id.hasSuffix(".en") || model.id == "parakeet-v2" { #expect(languages == ["en"]) }
        }
    }

    /// Mode pickers list catalog rows resolved with the saved model IDs; the compatible rows have no
    /// default, so only a resolved row can be available.
    @Test func aConfiguredCompatibleRowIsAvailableOnlyOnceResolved() throws {
        var readiness = RecordingReadiness(
            requireLocalProcessing: false, installedModelIDs: [], connectedProviders: [.openAICompatible],
            appleSpeechReadyLanguages: [], appleSpeechLanguages: nil, cleanupHelperAvailable: true)
        let row = try #require(models.first { $0.id == "compatible-cleanup" })
        #expect(row.apiModelID == nil)
        let resolved = row.applying(["compatible-cleanup": " openai/gpt-4.1-mini "])
        #expect(resolved.apiModelID == "openai/gpt-4.1-mini")
        #expect(readiness.isAvailable(resolved))
        #expect(!readiness.isAvailable(row))
        #expect(readiness.blocker(for: row, language: .english) == .providerNotSetUp(provider: row.provider))
        // An empty choice keeps the catalog default, which these rows lack.
        #expect(!readiness.isAvailable(row.applying(["compatible-cleanup": "  "])))
        readiness.connectedProviders = []
        #expect(
            readiness.blocker(for: resolved, language: .english) == .providerNotSetUp(provider: row.provider))
    }

    @Test func detectionIsClaimedOnlyWhereItWorks() {
        // The pinned MLX Whisper omits its language token for detection but has no detection pass, which
        // produced dots and stray letters for French and English clips. Apple Speech cannot detect.
        for model in models where model.engine == .whisper || model.engine == .apple {
            #expect(model.detectsLanguage == false, "\(model.id)")
        }
        #expect(models.contains { $0.purpose == .speech && $0.detectsLanguage == true })
    }
}

/// Configuration and History rows written by the release at commit 7c748a4 must still load. The JSON
/// below was produced by that commit's `Domain.swift` and `ModelCatalog.swift`, encoded the way
/// LocalStore writes it, so these are that format's real bytes rather than a hand-written imitation.
struct SavedFormatCompatibilityTests {
    static let configuration = #"""
        {"microphones":[{"id":"builtin","isEnabled":true,"name":"MacBook Pro Microphone"}],"mode\#
        s":[{"appBundleIDs":[],"autoPaste":true,"capitalize":true,"customPrompt":"","id":"111111\#
        11-2222-3333-4444-555555555555","identifySpeakers":false,"name":"Voice to text","playbac\#
        k":"Keep playing","preset":"Voice to text","recordSystemAudio":false,"speechModelID":"wh\#
        isper-tiny","tone":"semi-formal","useLists":false},{"appBundleIDs":[],"autoPaste":true,"\#
        capitalize":true,"cleanupModelID":"s1-mini","customPrompt":"","id":"F3844A60-A349-4CF0-8\#
        0C6-0B18ADE8791A","identifySpeakers":false,"name":"Message","playback":"Keep playing","p\#
        reset":"Message","recordSystemAudio":false,"speechModelID":"groq-whisper","tone":"casual\#
        ","useLists":false},{"appBundleIDs":[],"autoPaste":true,"capitalize":true,"cleanupModelI\#
        D":"openai-cleanup","customPrompt":"","id":"6CB8679B-56FC-4506-87B9-705FB6B6A4EF","ident\#
        ifySpeakers":false,"name":"Mail","playback":"Keep playing","preset":"Mail","recordSystem\#
        Audio":false,"speechModelID":"openai-mini-transcribe","tone":"semi-formal","useLists":fa\#
        lse},{"appBundleIDs":[],"autoPaste":true,"capitalize":true,"cleanupModelID":"s1-mini","c\#
        ustomPrompt":"","id":"F392772B-0E29-4AC0-BE4B-AA8CF34FC5A2","identifySpeakers":false,"na\#
        me":"Notes","playback":"Keep playing","preset":"Notes","recordSystemAudio":false,"speech\#
        ModelID":"apple-speech","tone":"semi-formal","useLists":true},{"appBundleIDs":[],"autoPa\#
        ste":false,"capitalize":true,"cleanupModelID":"s1-mini","customPrompt":"","id":"62F0DAD4\#
        -40C6-4650-919C-7F12138FAC61","identifySpeakers":false,"name":"Meeting","playback":"Keep\#
         playing","preset":"Meeting","recordSystemAudio":true,"speechModelID":"apple-speech","to\#
        ne":"semi-formal","useLists":true},{"appBundleIDs":[],"autoPaste":true,"capitalize":true\#
        ,"customPrompt":"","id":"B18457FB-EBFD-4771-AA8A-2B8E717C968E","identifySpeakers":false,\#
        "name":"Custom","playback":"Keep playing","preset":"Custom","recordSystemAudio":false,"s\#
        peechModelID":"apple-speech","tone":"semi-formal","useLists":false}],"settings":{"always\#
        ShowRecorder":true,"apiModelOverrides":{"openai-mini-transcribe":"gpt-4o-mini-transcribe\#
        "},"appearance":"system","audioRetentionDays":7,"automaticModeSelection":true,"errorLogg\#
        ing":false,"hasCompletedSetup":false,"launchAtLogin":false,"modeShortcut":{"display":"⌥⇧\#
        ⌘K","keyCode":40,"modifiers":2816},"playSoundEffects":false,"recorderStyle":"notch","req\#
        uireLocalProcessing":false,"selectedModeID":"11111111-2222-3333-4444-555555555555","text\#
        RetentionDays":0,"toggleShortcut":{"display":"⌥⌘Space","keyCode":49,"modifiers":2304}},"\#
        vocabulary":[{"id":"2C16A1B3-6449-4699-AFA3-11B078C71E16","replacement":"Amanuensis","wo\#
        rd":"amanuensis"}]}
        """#

    static let recording = #"""
        {"audioFileName":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.wav","cleanupSnapshot":{"family":\#
        "s1mini","fileName":"s1-mini-q4_k_m.gguf","id":"s1-mini","license":"Apache 2.0 with S1-m\#
        ini by Superwhisper naming requirement","location":"local","name":"S1-mini","provider":"\#
        Superwhisper","purpose":"cleanup","repository":"superwhisper\/s1-mini-GGUF","revision":"\#
        34add00a48a2e5d24e5a4ee5405a99620a3a240c","sha256":"3b41ebe2502cbd03e811d5d16b022f5ab551\#
        eda58d62597d152f89535003c634","sizeLabel":"484 MB","summary":"Local transcript cleanup w\#
        ith tone and list controls. Official Q4_K_M GGUF."},"countedInStatistics":false,"created\#
        At":784000000,"duration":3.2,"finalText":"Please send the notes","id":"AAAAAAAA-BBBB-CCC\#
        C-DDDD-EEEEEEEEEEEE","mode":{"appBundleIDs":[],"autoPaste":true,"capitalize":true,"custo\#
        mPrompt":"","id":"11111111-2222-3333-4444-555555555555","identifySpeakers":false,"name":\#
        "Voice to text","playback":"Keep playing","preset":"Voice to text","recordSystemAudio":f\#
        alse,"speechModelID":"whisper-tiny","tone":"semi-formal","useLists":false},"rawText":"pl\#
        ease send the notes","speechSnapshot":{"family":"whisper","id":"whisper-tiny","license":\#
        "MIT","location":"local","name":"Whisper tiny","provider":"OpenAI","purpose":"speech","r\#
        epository":"openai\/whisper-tiny","revision":"169d4a4341b33bc18d8881c4b69c2e104e1cc0af",\#
        "sizeLabel":"151 MB","summary":"Official safetensors and tokenizer. Runs locally using M\#
        LX."},"status":"complete","vocabularySnapshot":[{"id":"2C16A1B3-6449-4699-AFA3-11B078C71\#
        E16","replacement":"Amanuensis","word":"amanuensis"}]}
        """#

    @Test func configurationFromBeforeLanguagesLoadsWithoutOne() throws {
        let saved = try JSONDecoder().decode(SavedConfiguration.self, from: Data(Self.configuration.utf8))
        #expect(saved.settings.dictationLanguage == nil)
        #expect(saved.settings.recorderStyle == .notch)
        #expect(saved.modes.count == 6)
        #expect(saved.modes.allSatisfy { $0.language == nil })
        var modes = saved.modes
        for index in modes.indices { modes[index].migrateModelIDs() }
        #expect(
            modes.map(\.speechModelID).prefix(3) == ["whisper-tiny", "groq-transcribe", "openai-transcribe"])
        let reencoded = try JSONEncoder().encode(saved)
        let again = try JSONDecoder().decode(SavedConfiguration.self, from: reencoded)
        #expect(again.modes == saved.modes)
        #expect(again.settings == saved.settings)
    }

    @Test func historyRowFromBeforeLanguagesRetriesInEnglish() throws {
        let entry = try JSONDecoder().decode(RecordingEntry.self, from: Data(Self.recording.utf8))
        #expect(entry.language == nil)
        #expect(entry.transcriptionLanguage == .english)
        let speech = try #require(entry.speechSnapshot)
        // The old size string is kept, so writing the row back still suits the older release.
        #expect(speech.byteCount == nil && speech.sizeLabel == "151 MB")
        #expect(speech.languages == nil)
        #expect(speech.declares(.english))
        #expect(!speech.declares(.code("fr")))
        let retry = entry.retryAttempt()
        #expect(retry.transcriptionLanguage == .english)
        let readiness = RecordingReadiness(
            requireLocalProcessing: true, installedModelIDs: ["whisper-tiny", "s1-mini"],
            connectedProviders: [],
            appleSpeechReadyLanguages: [], appleSpeechLanguages: nil, cleanupHelperAvailable: true)
        #expect(
            readiness.blocker(
                speech: retry.speechSnapshot, cleanup: retry.cleanupSnapshot,
                cleanupModelID: retry.mode.cleanupModelID, language: retry.transcriptionLanguage,
                identifySpeakers: false) == nil)
    }
}

/// Families this build adds, and the Ollama row it removes, in both directions. Earlier releases decode
/// `family` as a closed enum and fail their whole History load on an unknown value; the 44d2cc9 JSON
/// below was produced by that commit's `Domain.swift`, the way its LocalStore wrote it.
struct FamilyCompatibilityTests {
    static let configuration44 = #"""
        {"microphones":[],"modes":[{"appBundleIDs":[],"autoPaste":true,"capitalize":true,"cleanu\#
        pModelID":"ollama-cleanup","customPrompt":"","id":"11111111-2222-3333-4444-555555555555"\#
        ,"identifySpeakers":false,"name":"Notes","playback":"Keep playing","preset":"Notes","rec\#
        ordSystemAudio":false,"speechModelID":"whisper-tiny","tone":"semi-formal","useLists":tru\#
        e}],"settings":{"alwaysShowRecorder":true,"apiModelOverrides":{},"appearance":"system","\#
        audioRetentionDays":7,"automaticModeSelection":true,"dictationLanguage":"en","errorLoggi\#
        ng":false,"hasCompletedSetup":false,"launchAtLogin":false,"modeShortcut":{"display":"⌥⇧⌘\#
        K","keyCode":40,"modifiers":2816},"playSoundEffects":false,"recorderStyle":"mini","requi\#
        reLocalProcessing":true,"selectedModeID":"11111111-2222-3333-4444-555555555555","textRet\#
        entionDays":0,"toggleShortcut":{"display":"⌥⌘Space","keyCode":49,"modifiers":2304}},"voc\#
        abulary":[]}
        """#

    static let recording44 = #"""
        {"cleanupSnapshot":{"family":"ollama","id":"ollama-cleanup","languages":[],"license":"De\#
        pends on the selected model","location":"local","name":"Ollama","provider":"Local server\#
        ","purpose":"cleanup","sizeLabel":"","summary":"Connect to an installed Ollama model o\#
        n this Mac."},"countedInStatistics":false,"createdAt":784000000,"duration":0,"finalText"\#
        :"","id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","language":"en","mode":{"appBundleIDs":[\#
        ],"autoPaste":true,"capitalize":true,"cleanupModelID":"ollama-cleanup","customPrompt":""\#
        ,"id":"11111111-2222-3333-4444-555555555555","identifySpeakers":false,"name":"Notes","pl\#
        ayback":"Keep playing","preset":"Notes","recordSystemAudio":false,"speechModelID":"whisp\#
        er-tiny","tone":"semi-formal","useLists":true},"rawText":"","speechSnapshot":{"byteCount\#
        ":155454211,"detectsLanguage":false,"family":"whisper","id":"whisper-tiny","languages":[\#
        "af","am","ar","as","az","ba","be","bg","bn","bo","br","bs","ca","cs","cy","da","de","el\#
        ","en","es","et","eu","fa","fi","fo","fr","gl","gu","ha","haw","he","hi","hr","ht","hu",\#
        "hy","id","is","it","ja","jv","ka","kk","km","kn","ko","la","lb","ln","lo","lt","lv","mg\#
        ","mi","mk","ml","mn","mr","ms","mt","my","ne","nl","nn","no","oc","pa","pl","ps","pt","\#
        ro","ru","sa","sd","si","sk","sl","sn","so","sq","sr","su","sv","sw","ta","te","tg","th"\#
        ,"tk","tl","tr","tt","uk","ur","uz","vi","yi","yo","zh"],"license":"MIT","location":"loc\#
        al","name":"Whisper tiny","provider":"OpenAI","purpose":"speech","repository":"openai\/w\#
        hisper-tiny","revision":"169d4a4341b33bc18d8881c4b69c2e104e1cc0af","sizeLabel":"155.5 MB\#
        ","summary":"Official safetensors and tokenizer. Runs locally using MLX."},"status":"fai\#
        led"}
        """#
    /// Every catalog row, as a snapshot would save it, uses only families earlier releases can decode,
    /// and decodes back to its real family. Every stored field is written, so none is dropped silently.
    @Test func snapshotsOfEveryRowSaveAFamilyEarlierReleasesReadAndComeBackIntact() throws {
        let catalog = try ModelDescriptor.catalog(from: Data(contentsOf: ModelCatalogTests.catalogURL))
        let raw = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: ModelCatalogTests.catalogURL))
                as? [[String: Any]])
        for (row, file) in zip(catalog, raw) {
            let data = try JSONEncoder().encode(row)
            let saved = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let family = try #require(saved["family"] as? String)
            #expect(ModelFamily.readableByEarlierReleases.contains(family), "\(row.id) saves \(family)")
            #expect(row.engine.rawValue == file["family"] as? String, "\(row.id)")
            #expect((saved["runtimeFamily"] as? String) == (family == "ollama" ? row.engine.rawValue : nil))
            #expect(try JSONDecoder().decode(ModelDescriptor.self, from: data) == row)
        }
        #expect(catalog.contains { $0.family.rawValue == "ollama" && $0.engine.rawValue == "moonshine" })
        var full = try #require(catalog.first { $0.id == "s1-mini" })
        full.apiModelID = "x"
        full.languages = ["en"]
        full.detectsLanguage = false
        full.runtimeFamily = .s1mini
        let keys = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any]
        ).keys
        for child in Mirror(reflecting: full).children {
            #expect(keys.contains(child.label ?? ""), "\(child.label ?? "") is not saved")
        }
    }

    @Test func aModeAndHistoryRowNamingTheRetiredOllamaRowLoadAndNeedAModel() throws {
        let saved = try JSONDecoder().decode(SavedConfiguration.self, from: Data(Self.configuration44.utf8))
        let mode = try #require(saved.modes.first)
        #expect(mode.cleanupModelID == "ollama-cleanup")
        let catalog = try ModelDescriptor.catalog(from: Data(contentsOf: ModelCatalogTests.catalogURL))
        #expect(!catalog.contains { $0.id == "ollama-cleanup" })
        let readiness = RecordingReadiness(
            requireLocalProcessing: true, installedModelIDs: ["whisper-tiny", "ollama-cleanup"],
            connectedProviders: [], appleSpeechReadyLanguages: [], appleSpeechLanguages: nil,
            cleanupHelperAvailable: true)
        // The mode, as the markers and recording validation resolve it against this catalog.
        let speech = catalog.first { $0.id == mode.speechModelID }
        let cleanup = catalog.first { $0.id == mode.cleanupModelID }
        #expect(
            readiness.blocker(
                speech: speech, cleanup: cleanup, cleanupModelID: mode.cleanupModelID, language: .english,
                identifySpeakers: false) == .cleanupModelMissing)
        // The History row keeps its Ollama snapshot, which a retry cannot run, so it is dropped too.
        let entry = try JSONDecoder().decode(RecordingEntry.self, from: Data(Self.recording44.utf8))
        #expect(entry.cleanupSnapshot?.engine.rawValue == "ollama")
        #expect(entry.cleanupSnapshot?.resolved(against: catalog) == nil)
        let retry = entry.retryAttempt()
        #expect(
            readiness.blocker(
                speech: retry.speechSnapshot?.resolved(against: catalog),
                cleanup: retry.cleanupSnapshot?.resolved(against: catalog),
                cleanupModelID: retry.mode.cleanupModelID, language: retry.transcriptionLanguage,
                identifySpeakers: false) == .cleanupModelMissing)
    }

    /// An earlier release that saves a row back keeps `family: "ollama"` and drops `runtimeFamily`.
    /// A retry takes the family from the catalog row with the same ID.
    @Test func aRowSavedBackByAnEarlierReleaseRetriesWithItsCatalogFamily() throws {
        let catalog = try ModelDescriptor.catalog(from: Data(contentsOf: ModelCatalogTests.catalogURL))
        var snapshot = try #require(catalog.first { $0.id == "moonshine-tiny" })
        snapshot.runtimeFamily = nil
        #expect(snapshot.engine.rawValue == "ollama")
        #expect(snapshot.resolved(against: catalog)?.engine.rawValue == "moonshine")
        // API snapshots of renamed or removed rows still run from the snapshot.
        var renamed = try #require(catalog.first { $0.id == "groq-transcribe" })
        renamed.id = "groq-whisper"
        #expect(renamed.resolved(against: catalog) == renamed)
    }
}

struct SpeechLanguageTests {
    @Test func savesCodesAndDetectionAsPlainStrings() throws {
        let encoded = try JSONEncoder().encode([SpeechLanguage.automatic, .code("fr")])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["auto","fr"]"#)
        #expect(try JSONDecoder().decode([SpeechLanguage].self, from: encoded) == [.automatic, .code("fr")])
    }

    @Test func freshInstallsTakeTheMacsLanguageWhenSupportedElseEnglish() {
        let supported: Set<String> = ["en", "fr", "zh", "no", "tl"]
        func initial(_ preferred: [String]) -> SpeechLanguage {
            SpeechLanguage.initial(freshInstall: true, supported: supported, preferredLanguages: preferred)
        }
        #expect(initial(["fr-CA", "en-US"]) == .code("fr"))
        #expect(initial(["zh-Hans-CN"]) == .code("zh"))
        // macOS says nb and fil; the speech models list no and tl.
        #expect(initial(["nb-NO"]) == .code("no"))
        #expect(initial(["fil-PH"]) == .code("tl"))
        // Only the first preference counts: a Swahili Mac with French second still means Swahili, unsupported.
        #expect(initial(["sw-KE", "fr-FR"]) == .english)
        #expect(initial([]) == .english)
    }

    @Test func existingConfigurationKeepsEnglishWhateverTheMacsLanguage() {
        #expect(
            SpeechLanguage.initial(
                freshInstall: false, supported: ["en", "fr"], preferredLanguages: ["fr-FR"])
                == .english)
    }

    @Test func retriesKeepTheLanguageFrozenWhenRecordingStarted() {
        var entry = RecordingEntry(mode: DictationMode.make(preset: .message))
        entry.language = .code("de")
        entry.mode.language = .code("fr")
        #expect(entry.retryAttempt().transcriptionLanguage == .code("de"))
    }
}
