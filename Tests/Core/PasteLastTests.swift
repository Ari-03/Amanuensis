import Foundation
import Testing

@testable import AmanuensisCore

struct PasteLastTests {
    private func entry(_ status: RecordingStatus, raw: String = "", final: String = "") -> RecordingEntry {
        RecordingEntry(
            mode: DictationMode(name: "Voice to text", preset: .dictation), rawText: raw, finalText: final,
            status: status)
    }

    @Test func picksTheNewestEntryThatReachedAResult() {
        // Newest first, as History loads it. Expired text leaves a row with neither text.
        let history = [
            entry(.transcribing), entry(.interrupted, raw: "cut short"), entry(.empty, raw: "um"),
            entry(.noSpeech), entry(.complete), entry(.complete, raw: " ", final: " \n"),
            entry(.complete, raw: "newest", final: "Newest"), entry(.complete, raw: "older", final: "Older"),
        ]
        #expect(history.newestFinished?.finalText == "Newest")
        #expect(history.prefix(6).newestFinished == nil)
        // A failed cleanup's original is its result, so an older transcript never stands in for it.
        let failed = entry(.failed, raw: "original", final: "Original")
        #expect(([failed] + history).newestFinished?.finalText == "Original")
    }

    @Test func shortcutIsUnsetByDefaultAndSurvivesSaving() throws {
        var settings = AppSettings()
        #expect(settings.pasteLastShortcut == nil)
        settings.pasteLastShortcut = ShortcutBinding(keyCode: 9, modifiers: 2304, display: "⌥⌘V")
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved == settings)
    }
}
