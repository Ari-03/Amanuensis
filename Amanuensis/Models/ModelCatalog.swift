import Foundation

/// Model identities are separate from the pinned artifact used to run them.
/// Speech artifacts include their tokenizers so loading never needs a network fallback.
enum ModelCatalog {
    static let models: [ModelDescriptor] =
        [
            ModelDescriptor(
                id: "apple-speech", name: "Apple Speech", provider: "Apple", purpose: .speech,
                location: .system, family: .apple,
                summary: "On-device English recognition. Availability depends on this Mac's speech assets.",
                license: "Provided by macOS"
            )
        ] + whisperModels + [
            ModelDescriptor(
                id: "parakeet-v2", name: "Parakeet TDT 0.6B V2", provider: "NVIDIA", purpose: .speech,
                location: .local, family: .parakeet,
                summary: "English speech recognition. MLX conversion by mlx-community.", sizeLabel: "2.47 GB",
                repository: "mlx-community/parakeet-tdt-0.6b-v2",
                revision: "8ae155301e23d820d82aa60d24817c900e69e487", license: "CC BY 4.0"
            ),
            ModelDescriptor(
                id: "parakeet-v3", name: "Parakeet TDT 0.6B V3", provider: "NVIDIA", purpose: .speech,
                location: .local, family: .parakeet,
                summary: "Multilingual speech recognition used for English. MLX conversion by mlx-community.",
                sizeLabel: "2.51 GB", repository: "mlx-community/parakeet-tdt-0.6b-v3",
                revision: "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15", license: "CC BY 4.0"
            ),
            ModelDescriptor(
                id: "cohere-transcribe", name: "Cohere Transcribe", provider: "Cohere", purpose: .speech,
                location: .local, family: .cohere,
                summary: "March 2026 checkpoint. Public 4-bit MLX conversion by beshkenadze.",
                sizeLabel: "1.51 GB", repository: "beshkenadze/cohere-transcribe-03-2026-mlx-4bit",
                revision: "104bc4391b5b1a12b040859793d7148525e1a08c", license: "Apache 2.0"
            ),
            ModelDescriptor(
                id: "s1-mini", name: "S1-mini", provider: "Superwhisper", purpose: .cleanup,
                location: .local, family: .s1mini,
                summary: "Local transcript cleanup with tone and list controls. Official Q4_K_M GGUF.",
                sizeLabel: "484 MB", repository: "superwhisper/s1-mini-GGUF",
                revision: "34add00a48a2e5d24e5a4ee5405a99620a3a240c", fileName: "s1-mini-q4_k_m.gguf",
                sha256: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634",
                license: "Apache 2.0 with S1-mini by Superwhisper naming requirement"
            ),
            ModelDescriptor(
                id: "openai-transcribe", name: "GPT-4o Transcribe", provider: "OpenAI", purpose: .speech,
                location: .cloud, family: .openAI, summary: "Transcription using your OpenAI API key.",
                apiModelID: "gpt-4o-transcribe", license: "OpenAI API terms"
            ),
            ModelDescriptor(
                id: "openai-mini-transcribe", name: "GPT-4o Mini Transcribe", provider: "OpenAI",
                purpose: .speech,
                location: .cloud, family: .openAI, summary: "Transcription using your OpenAI API key.",
                apiModelID: "gpt-4o-mini-transcribe", license: "OpenAI API terms"
            ),
            ModelDescriptor(
                id: "groq-whisper", name: "Whisper Large V3 Turbo", provider: "Groq", purpose: .speech,
                location: .cloud, family: .groq, summary: "Hosted Whisper using your Groq API key.",
                apiModelID: "whisper-large-v3-turbo", license: "Groq API terms"
            ),
            ModelDescriptor(
                id: "openai-cleanup", name: "OpenAI Cleanup", provider: "OpenAI", purpose: .cleanup,
                location: .cloud, family: .openAI,
                summary: "Choose a text model and use your OpenAI API key.",
                apiModelID: "gpt-4.1-mini", license: "OpenAI API terms"
            ),
            ModelDescriptor(
                id: "claude-cleanup", name: "Claude Cleanup", provider: "Anthropic", purpose: .cleanup,
                location: .cloud, family: .anthropic,
                summary: "Choose a Claude model and use your Anthropic API key.",
                apiModelID: "claude-sonnet-4-6", license: "Anthropic API terms"
            ),
            ModelDescriptor(
                id: "ollama-cleanup", name: "Ollama", provider: "Local server", purpose: .cleanup,
                location: .local, family: .ollama,
                summary: "Connect to an installed Ollama model on this Mac.",
                license: "Depends on the selected model"
            ),
        ]

    // Verified against publisher repository metadata, September 19, 2026.
    // openai/whisper-large contains V1. The Python library's `large` alias instead means V3.
    private static let whisperModels: [ModelDescriptor] = [
        ("tiny", "169d4a4341b33bc18d8881c4b69c2e104e1cc0af", "151 MB"),
        ("tiny.en", "87c7102498dcde7456f24cfd30239ca606ed9063", "151 MB"),
        ("base", "e37978b90ca9030d5170a5c07aadb050351a65bb", "290 MB"),
        ("base.en", "911407f4214e0e1d82085af863093ec0b66f9cd6", "290 MB"),
        ("small", "973afd24965f72e36ca33b3055d56a652f456b4d", "967 MB"),
        ("small.en", "e8727524f962ee844a7319d92be39ac1bd25655a", "967 MB"),
        ("medium", "abdf7c39ab9d0397620ccaea8974cc764cd0953e", "3.06 GB"),
        ("medium.en", "2e98eb6279edf5095af0c8dedb36bdec0acd172b", "3.06 GB"),
        ("large-v1", "4ef9b41f0d4fe232daafdb5f76bb1dd8b23e01d7", "6.17 GB"),
        ("large-v2", "ae4642769ce2ad8fc292556ccea8e901f1530655", "6.17 GB"),
        ("large-v3", "06f233fe06e710322aca913c1bc4249a0d71fce1", "3.09 GB"),
        ("large-v3-turbo", "41f01f3fe87f28c78e2fbf8b568835947dd65ed9", "1.62 GB"),
    ].map { variant, revision, size in
        ModelDescriptor(
            id: "whisper-\(variant)",
            name: "Whisper \(variant.replacingOccurrences(of: ".en", with: " English"))",
            provider: "OpenAI", purpose: .speech, location: .local, family: .whisper,
            summary: "Official safetensors and tokenizer. Runs locally using MLX.", sizeLabel: size,
            repository: "openai/whisper-\(variant == "large-v1" ? "large" : variant)",
            revision: revision, license: "MIT"
        )
    }
}
