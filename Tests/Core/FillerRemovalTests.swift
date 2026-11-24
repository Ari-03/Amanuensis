import Foundation
import Testing

@testable import AmanuensisCore

struct FillerRemovalTests {
    private func clean(_ text: String, keeping vocabulary: [VocabularyEntry] = []) -> String {
        TextRules.removingFillers(from: text, keeping: vocabulary)
    }

    @Test(arguments: [
        ("I um think", "I think"),
        ("I uh uh think erm so", "I think so"),
        ("Um, uh, we should go", "We should go"),
        ("um we should go", "we should go"),
        ("Right. Uhm, let's go. Hmm... okay.", "Right. Let's go. Okay."),
        ("Right. Um. Let's go. Uh, iPhone prices", "Right. Let's go. iPhone prices"),
        ("Is it? Uh, 5 people", "Is it? 5 people"),
        ("I was, um, going", "I was, going"),
        ("apples, um, oranges", "apples, oranges"),
        ("apples um, oranges", "apples, oranges"),
        ("apples, um uh oranges", "apples, oranges"),
        ("I was, um... going", "I was... going"),
        ("I think so, um.", "I think so."),
        ("I think so, um", "I think so"),
        ("First line, um\nUh, second\nthird um\n", "First line\nSecond\nthird"),
        ("Um.", ""), ("Uh, um...", ""), ("Um.\num", ""),
    ])
    func fillersGo(text: String, expected: String) { #expect(clean(text) == expected) }

    @Test(arguments: [
        "I like it, you know, so we mean well, right?",
        "Uh-huh, uh-oh, mhm, mm, ah, er, the ER, umbrella, hummus, human, sum",
        "She attends UM and reads HMM papers. UM won.",
        "Umm Kulthum sang. Um and Ki-joon met Mr. Um, then Mrs. Um, at Umm Qasr.",
        "5 um and 10 hm", "um's um-hum _um um_ #um um.com um/uh 'um", "Hmm? Hmm! You mean um?",
        "The word \"um\" and (uh) and “um.”", "I think — um, we—um—left",
        "Leading and\n\n  inner   spacing, stays.", "ümlaut, 会um議, naïve um\u{301}", "", "Um",
    ])
    func everythingElseIsKept(text: String) { #expect(clean(text) == text) }

    @Test func vocabularyPhrasesAreKept() {
        let vocabulary = [
            VocabularyEntry(word: "umm"), VocabularyEntry(word: "oum uh (band)", replacement: "x"),
        ]
        #expect(
            clean("the Oum uh (band), umm, uh, and um so", keeping: vocabulary)
                == "the Oum uh (band), umm, and so")
        #expect(clean("Uh, umm, well", keeping: vocabulary) == "Umm, well")
        #expect(clean("the Oum uh band", keeping: []) == "the Oum band")
    }

    @Test func appliesOnlyToEnglishWhenTheModeAsks() {
        // "Um" is a word in German and Portuguese.
        var entry = RecordingEntry(
            mode: DictationMode(name: "Voice to text", preset: .dictation), rawText: "Es geht um alles")
        #expect(entry.transcript == entry.rawText)
        entry.mode.removesFillers = true
        for language: SpeechLanguage in [.code("de"), .code("pt"), .automatic] {
            entry.language = language
            #expect(entry.transcript == entry.rawText)
        }
        entry.rawText = "it is, uh, about um everything"
        entry.language = .english
        #expect(entry.transcript == "it is, about everything")
        #expect(entry.rawText == "it is, uh, about um everything")
        // Rows from before languages existed were dictated in English.
        entry.language = nil
        #expect(entry.transcript == "it is, about everything")
    }

    @Test func modesSavedWithoutTheSettingDecodeWithItOff() throws {
        let saved = try JSONDecoder().decode(
            SavedConfiguration.self, from: Data(SavedFormatCompatibilityTests.configuration.utf8))
        #expect(saved.modes.count == 6 && saved.modes.allSatisfy { !$0.removesFillers })
        let row = try JSONDecoder().decode(
            RecordingEntry.self, from: Data(SavedFormatCompatibilityTests.recording.utf8))
        #expect(!row.mode.removesFillers && row.transcript == row.rawText)
        #expect(DictationMode.initial.allSatisfy { !$0.removesFillers })
        var mode = saved.modes[0]
        mode.removesFillers = true
        #expect(try JSONDecoder().decode(DictationMode.self, from: JSONEncoder().encode(mode)) == mode)
    }
}
