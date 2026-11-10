import Foundation
import Testing

@testable import AmanuensisCore

struct RecorderOutcomeTests {
    @Test func causesMapToTheirLabelsAndActions() {
        let expected: [(RecorderOutcome.Cause, String, RecorderOutcome.Action?)] = [
            (.inserted(app: "Mail"), "Inserted in Mail", nil),
            (.inserted(app: nil), "Inserted", nil),
            (.copied, "Copied. Press ⌘V", nil),
            (.needsAccessibility, "Copied. Press ⌘V", .allowPaste),
            (.savedToHistory, "Saved to History", nil),
            (.noSpeech, "No speech detected", nil),
            (.nothingToInsert, "Nothing to insert", nil),
            (.cleanupFailed, "Cleanup failed", .pasteOriginal),
            (
                .failed(.modelNotInstalled("Parakeet TDT 0.6B V2")), "Parakeet TDT 0.6B V2 not installed",
                .openModels
            ),
            (.failed(.apiKeyMissing(provider: "OpenAI")), "OpenAI key missing", .openModels),
            (
                .failed(.blockedByLocalOnly(modelName: "OpenAI Cleanup")), "Blocked by local-only",
                .openSettings
            ),
            (.failed(.noMicrophone), "No microphone", .openSound),
            (.failed(.appleSpeechNotReady), "Apple Speech not ready", .openModels),
            (.interrupted, "Recording interrupted", .showInHistory),
            (.failed(nil), "Couldn't finish", .showInHistory),
        ]
        for (cause, label, action) in expected {
            let outcome = RecorderOutcome(cause, recordingID: nil, at: 0)
            #expect(outcome.label == label)
            #expect(outcome.action == action)
            // Failures always offer a way forward; only the Accessibility hint is a self-closing action.
            if outcome.kind == .failure { #expect(action != nil) }
            #expect((outcome.kind == .warning) == (action == .allowPaste))
        }
    }

    @Test func successesNoticesAndWarningsCloseAfterTwoSeconds() {
        for cause in [RecorderOutcome.Cause.inserted(app: "Notes"), .noSpeech, .needsAccessibility] {
            let outcome = RecorderOutcome(cause, recordingID: nil, at: 100)
            #expect(!outcome.isExpired(at: 101.9))
            #expect(outcome.isExpired(at: 102))
        }
    }

    @Test func leavingThePillAfterTheDeadlineGivesAShortGrace() {
        var outcome = RecorderOutcome(.noSpeech, recordingID: nil, at: 100)
        outcome.pointerLeft(at: 110)
        #expect(!outcome.isExpired(at: 110.1))
        #expect(outcome.isExpired(at: 110 + RecorderOutcome.hoverGrace))
        var early = RecorderOutcome(.copied, recordingID: nil, at: 100)
        early.pointerLeft(at: 100.5)
        #expect(early.deadline == 102)
    }

    @Test func failuresNeverExpire() {
        var outcome = RecorderOutcome(.cleanupFailed, recordingID: UUID(), at: 100)
        outcome.pointerLeft(at: 200)
        #expect(outcome.deadline == nil)
        #expect(!outcome.isExpired(at: 10_000))
    }

    @Test func presentedStyleFloatsFailuresAndHidesQuietOutcomesInHidden() {
        let success = RecorderOutcome(.inserted(app: nil), recordingID: nil, at: 0)
        let failure = RecorderOutcome(.failed(nil), recordingID: nil, at: 0)
        let warning = RecorderOutcome(.needsAccessibility, recordingID: nil, at: 0)
        func style(
            _ saved: RecorderStyle, alwaysShow: Bool = false, busy: Bool = false, outcome: RecorderOutcome?
        )
            -> RecorderStyle?
        {
            RecorderLayout.presentedStyle(
                saved: saved, alwaysShow: alwaysShow, busy: busy, cancellationPending: false, outcome: outcome
            )
        }
        #expect(style(.mini, outcome: nil) == nil)
        #expect(style(.mini, alwaysShow: true, outcome: nil) == .mini)
        #expect(style(.mini, outcome: success) == .mini)
        #expect(style(.notch, outcome: success) == .notch)
        #expect(style(.notch, outcome: failure) == .mini)
        #expect(style(.hidden, alwaysShow: true, busy: true, outcome: nil) == nil)
        #expect(style(.hidden, outcome: success) == nil)
        #expect(style(.hidden, outcome: failure) == .mini)
        // The Accessibility hint behaves like other self-closing outcomes.
        #expect(style(.mini, outcome: warning) == .mini)
        #expect(style(.notch, outcome: warning) == .notch)
        #expect(style(.hidden, outcome: warning) == nil)
        #expect(
            RecorderLayout.presentedStyle(
                saved: .hidden, alwaysShow: false, busy: true, cancellationPending: true, outcome: nil)
                == .mini)
    }

    @Test func dataDirectoryOverrideReplacesApplicationSupport() throws {
        let override = try AppDataDirectory.url(environment: [
            AppDataDirectory.environmentKey: "/tmp/proof/data"
        ])
        #expect(override.path == "/tmp/proof/data")
        #expect(throws: AppDataDirectory.OverrideError.self) {
            try AppDataDirectory.url(environment: [AppDataDirectory.environmentKey: "relative/data"])
        }
        let standard = try AppDataDirectory.url(environment: [:])
        #expect(standard.lastPathComponent == "Amanuensis")
        #expect(standard.deletingLastPathComponent().lastPathComponent == "Application Support")
    }
}
