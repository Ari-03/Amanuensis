# Dictation app research

Research collected September 19, 2026 for the [Amanuensis product brief](../product-brief.md). These notes use official documentation and source repositories. They are not results from installing or benchmarking the apps.

Start with the [consolidated implementation plan](../implementation-plan.md) for the proposed build. It resolves alternative recommendations below and records the temporary starter-build compatibility check. No inference or signed insertion has been validated yet.

| Question | Findings |
| --- | --- |
| Which apps already support much of the requested workflow? | [Handy and VoiceInk](local-dictation-apps.md) |
| What can we learn about meetings and local transcription? | [MacWhisper](macwhisper.md) |
| How should tone, vocabulary, and recording controls work? | [Wispr Flow and Willow](contextual-dictation.md) |
| What can a native Mac app implement, and what needs permission? | [macOS feasibility](macos-feasibility.md) |
| How can existing local models be used? | [Local model pipeline](local-model-pipeline.md) |
| Can we include the required S1-mini independently? | [S1-mini availability and runtime contract](s1-mini-availability.md) |
| Can Cohere, Whisper, and Parakeet run offline? | [Requested offline models](requested-offline-models.md) |
| How should Apple recognition and ranked microphone inputs work? | [Apple speech and microphone priorities](apple-speech-and-microphones.md) |
| Which speech and cleanup API providers are requested? | [OpenAI, Groq, Claude, and optional Ollama](api-providers.md) |
| What should the app look like? | [Native visual design](native-visual-design.md), [desktop design references](desktop-design-references.md) |
| How should first launch and the catalog behave? | [Onboarding and library UX](onboarding-and-library-ux.md) |
| What does each recording state mean? | [Recording interaction plan](recording-interaction-plan.md) |
| How do the native runtimes fit together? | [Runtime integration](runtime-integration-plan.md), [module architecture](module-architecture.md) |
| How do we handle paste permissions and releases? | [Insertion and distribution](insertion-and-distribution-plan.md) |
| How do we preserve recordings and install models? | [Storage and model management](storage-and-model-management.md) |
| What must pass before a release? | [Validation and release](validation-and-release-plan.md) |
| What names and domains are worth considering? | [Names and domains](names-and-domains.md) |
| What did independent plan review find? | [Plan review](plan-review.md) |

VoiceInk is the closest documented comparison for this brief. It combines per-app modes, separate speech and cleanup choices, vocabulary and replacements, imported local Whisper models, and notch/mini recording UI. Its documentation is a useful interaction reference. [Modes](https://tryvoiceink.com/docs/modes), [local models](https://tryvoiceink.com/docs/local-models), [vocabulary](https://tryvoiceink.com/docs/vocabulary), [replacements](https://tryvoiceink.com/docs/word-replacements), [recording appearance](https://tryvoiceink.com/docs/settings-general)

The proposed priorities for Amanuensis are unrestricted local execution, reliable insertion, and recoverable transcripts. Show where both speech recognition and cleanup run. A local speech model alone does not guarantee an offline workflow, as MacWhisper's privacy documentation explains. [Processing locations](https://docs.macwhisper.com/article/52-keeping-transcriptions-private)

The second walkthrough fixes the required families: local Whisper, Parakeet, Cohere Transcribe, Apple recognition, and S1-mini cleanup; API speech from OpenAI/Groq and API cleanup from OpenAI/Claude. Additional local cleanup through Ollama is desired. Exact artifacts, runtime versions, and default selections remain open.

S1-mini has official standalone weights and third-party integration instructions. Cohere also publishes a local-inference checkpoint; its official download access and independently converted Mac artifacts need explicit treatment. These findings establish independent acquisition paths, not tested Amanuensis integrations. [S1-mini release](https://huggingface.co/superwhisper/s1-mini-GGUF), [Cohere release](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)

Before selecting runtimes, test the required S1-mini and speech paths on the intended hardware, including offline startup, memory, and recording-to-insertion latency. Before promising meeting speaker labels, test mixed microphone/system audio with overlapping speakers. Before calling the recording indicator complete, test it on a notched display and an external monitor.
