import Foundation
@preconcurrency import MLXAudioSTT

/// Everything that differs between local speech model families, declared once. The engine loads
/// models through it, and the app asks it which files a download keeps and whether a folder holds a
/// complete model of the family. Adding a family is one entry in `all` plus its rows in the app's
/// `ModelCatalog.json`, whose `family` field names the entry.
public struct LocalSpeechFamily: Sendable {
    /// The name the catalog uses, such as "whisper".
    public let name: String
    /// What messages call the family, such as "Whisper".
    public let displayName: String
    /// Files a model folder needs besides its `.safetensors` weights.
    public let requiredFiles: [String]
    /// Whether the runtime can run without a language and work out the spoken one itself. Measured, not
    /// taken from a README. A checkpoint can still be single-language; the catalog row says what each
    /// checkpoint offers, and only a family that detects may have rows that claim detection.
    public let detectsLanguage: Bool
    /// Recognizes the family's parsed `config.json`.
    let recognizes: @Sendable ([String: Any]) -> Bool
    /// Turns a BCP-47 code, or nil for detection, into what the runtime's generation parameters expect.
    let languageArgument: @Sendable (String?) -> String?
    let load: @Sendable (URL) async throws -> any STTGenerationModel
    /// Tokens one 30-second window may generate. Nil keeps the runtime's default, capped at 1024.
    var maxTokens: Int? = nil
    /// Every value the runtime's language table accepts, for runtimes that silently fall back on an
    /// unknown one. Copied from the pinned checkpoint; a test checks every catalog language lands in it.
    var languageArguments: Set<String>? = nil

    /// Every family this build can run, in no particular order.
    public static let all: [LocalSpeechFamily] = [
        LocalSpeechFamily(
            name: "whisper", displayName: "Whisper",
            requiredFiles: ["config.json", "tokenizer.json", "tokenizer_config.json"],
            // The pinned Whisper omits its language token for nil but has no detection pass, which
            // produced dots and stray letters on short French and English clips.
            detectsLanguage: false,
            recognizes: { $0["model_type"] as? String == "whisper" || $0["n_mels"] != nil },
            // Whisper's tokenizer names Javanese with the retired code "jw".
            languageArgument: { $0 == "jv" ? "jw" : $0 },
            load: { try await WhisperModel.fromDirectory($0) }),
        LocalSpeechFamily(
            name: "parakeet", displayName: "Parakeet",
            requiredFiles: ["config.json"],
            // V3 detects; V2 is English only. The runtime ignores the language either way.
            detectsLanguage: true,
            // Parakeet's decoder reads its token table from the configuration, not from a tokenizer file.
            recognizes: { config in
                guard config["encoder"] != nil, let decoder = config["decoder"] as? [String: Any] else {
                    return false
                }
                let joint = config["joint"] as? [String: Any]
                let vocabulary =
                    joint?["vocabulary"] as? [String] ?? decoder["vocabulary"] as? [String]
                    ?? config["labels"] as? [String]
                return vocabulary?.isEmpty == false
            },
            languageArgument: { $0 },
            load: { try ParakeetModel.fromDirectory($0) }),
        LocalSpeechFamily(
            name: "cohere", displayName: "Cohere Transcribe",
            requiredFiles: ["config.json", "tokenizer.model", "tokenizer_config.json"],
            // Upstream silently substitutes English for nil or any code outside its fourteen languages.
            detectsLanguage: false,
            recognizes: { ($0["model_type"] as? String)?.contains("cohere") == true },
            languageArgument: { $0 },
            load: { try CohereTranscribeModel.fromDirectory($0) }),
        LocalSpeechFamily(
            name: "moonshine", displayName: "Moonshine",
            requiredFiles: ["config.json", "tokenizer.json"],
            // English-only checkpoints; the runtime takes no language.
            detectsLanguage: false,
            recognizes: { $0["model_type"] as? String == "moonshine" },
            languageArgument: { _ in nil },
            load: { try await MoonshineModel.fromModelDirectory($0) },
            // The runtime's default of 200 cut off the end of a 30-second window of English read at 380
            // words a minute; 400 kept it. At 180 and 280 words a minute, 1000 changed nothing.
            maxTokens: 400),
        LocalSpeechFamily(
            name: "qwen3asr", displayName: "Qwen3-ASR",
            requiredFiles: ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"],
            // Without a language the model names the one it heard before the transcript.
            detectsLanguage: true,
            recognizes: { $0["model_type"] as? String == "qwen3_asr" },
            // The runtime takes English language names, such as "French", from its configuration.
            languageArgument: { code in
                code.map { ["tl": "Filipino"][$0] ?? englishName(of: $0) }
            },
            load: { try await Qwen3ASRModel.fromModelDirectory($0) },
            // `support_languages` in mlx-community/Qwen3-ASR-0.6B-4bit@313d850 config.json.
            languageArguments: [
                "Chinese", "English", "Cantonese", "Arabic", "German", "French", "Spanish",
                "Portuguese", "Indonesian", "Italian", "Korean", "Russian", "Thai", "Vietnamese",
                "Japanese", "Turkish", "Hindi", "Malay", "Dutch", "Swedish", "Danish", "Finnish",
                "Polish", "Czech", "Filipino", "Persian", "Greek", "Romanian", "Hungarian",
                "Macedonian",
            ]),
        LocalSpeechFamily(
            name: "nemotron", displayName: "Nemotron ASR",
            requiredFiles: ["config.json"],
            // The configuration's prompt table has an "auto" entry for detection.
            detectsLanguage: true,
            recognizes: { $0["model_type"] as? String == "nemotron_asr" },
            // Its prompt table lists a few languages only with a region.
            // An unknown key silently runs detection instead.
            languageArgument: { code in
                guard let code else { return "auto" }
                let regional = [
                    "ja": "ja-JP", "zh": "zh-CN", "vi": "vi-VN", "he": "he-IL", "th": "th-TH", "mt": "mt-MT",
                ]
                return regional[code] ?? code
            },
            load: { try NemotronASRModel.fromDirectory($0) },
            // `prompt.prompt_dictionary` keys in
            // mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit@7279359 config.json.
            languageArguments: [
                "af-ZA", "am-ET", "ar", "ar-AR", "auto", "ay-BO", "az-AZ", "bg", "bg-BG", "bn-IN",
                "cs", "cs-CZ", "da", "da-DK", "de", "de-DE", "el", "el-GR", "en", "en-GB", "en-US",
                "enGB", "es", "es-ES", "es-US", "esES", "et", "et-EE", "fa-IR", "fi", "fi-FI", "fr",
                "fr-CA", "fr-FR", "gn-PY", "gu-IN", "ha-NG", "haw-US", "he-IL", "hi", "hi-HI", "hi-IN",
                "hr", "hr-HR", "hu", "hu-HU", "hy-AM", "id-ID", "ig-NG", "it", "it-IT", "ja-JA",
                "ja-JP", "ka-GE", "km-KH", "kn-IN", "ko", "ko-KO", "ko-KR", "ku-TR", "ky-KG", "ln-CD",
                "lt", "lt-LT", "lv", "lv-LV", "mi-NZ", "ml-IN", "mr-IN", "ms-MY", "mt-MT", "nah-MX",
                "nb", "nb-NO", "ne-NP", "nl", "nl-NL", "nn", "nn-NO", "no", "no-NO", "ny-MW", "or-KE",
                "pl", "pl-PL", "pt", "pt-BR", "pt-PT", "qu-PE", "ro", "ro-RO", "ru", "ru-RU", "rw-RW",
                "si-LK", "sk", "sk-SK", "sl", "sl-SI", "sm-WS", "so-SO", "sv", "sv-SE", "sw-KE",
                "ta-IN", "te-IN", "tg-TJ", "th-TH", "to-TO", "tr", "tr-TR", "uk", "uk-UA", "ur-PK",
                "uz-UZ", "vi-VN", "yo-NG", "zh-CN", "zh-TW", "zh-ZH", "zu-ZA",
            ]),
    ]

    /// The family the catalog names, or `LocalSpeechError.unsupportedFamily`.
    public static func named(_ name: String) throws -> LocalSpeechFamily {
        guard let family = all.first(where: { $0.name == name }) else {
            throw LocalSpeechError.unsupportedFamily(name)
        }
        return family
    }

    /// Whether a file from a model repository is one the runtimes read. Downloads keep only these
    /// (plus licence files), and the engine's private snapshot copies them. Full-precision duplicates
    /// that some repositories publish beside the weights are skipped.
    public static func isModelFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !name.contains(".fp32") && ["json", "safetensors", "txt", "model", "vocab"].contains(ext)
    }

    /// Throws unless `config.json`'s contents describe a model of this family.
    public func checkConfiguration(_ data: Data) throws {
        // NeMo conversions write non-standard floating-point values, which their loaders also accept.
        var text = String(decoding: data, as: UTF8.self)
        for value in ["-Infinity", "Infinity", "NaN"] {
            text = text.replacingOccurrences(of: value, with: "null")
        }
        guard let config = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            recognizes(config)
        else { throw LocalSpeechError.unrecognizedConfiguration(displayName) }
    }

    private static func englishName(of code: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }
}
