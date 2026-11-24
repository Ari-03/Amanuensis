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
        ("Um, I think so.", "I think so."),
        ("Um I think so", "I think so"),
        ("Um, uh, we should go", "We should go"),
        ("um, we should go", "we should go"),
        ("Right. Uhm, let's go. Hmm... okay.", "Right. Let's go. Okay."),
        ("Right. Um. Let's go.", "Right. Let's go."),
        ("Is it? Uh, yes", "Is it? Yes"),
        ("\"Um, yes,\" he said. Uh, \"no\"", "\"Yes,\" he said. \"No\""),
        ("(um, maybe) (like this, um)", "(maybe) (like this)"),
        ("Um — we left", "We left"),
        ("Um, iPhone prices. Uh, 5 people. Hm, I'm in", "iPhone prices. 5 people. I'm in"),
    ])
    func sentencesOpenCleanly(text: String, expected: String) { #expect(clean(text) == expected) }

    @Test(arguments: [
        ("I was, um, going", "I was, going"),
        ("apples, um, oranges", "apples, oranges"),
        ("apples um, oranges", "apples, oranges"),
        ("apples, um oranges", "apples, oranges"),
        ("apples, um, uh, oranges", "apples, oranges"),
        ("I think—um—we left", "I think—we left"),
        ("I think — um — we left", "I think — we left"),
        ("I think, um—we left", "I think, we left"),
        ("I was, um... going", "I was... going"),
        ("I think so, um.", "I think so."),
        ("You mean, uh?", "You mean?"),
        ("I think so, um", "I think so"),
        ("First line, um\nUh, second\n\nUm.\n\nThird um\n", "First line\nSecond\n\nThird\n"),
    ])
    func onePauseAtMostSurvives(text: String, expected: String) { #expect(clean(text) == expected) }

    @Test(arguments: ["Um", "Um.", "Uh, um...", "  um  ", "Um.\nUh"])
    func onlyFillersLeaveNothing(text: String) { #expect(clean(text) == "") }

    @Test(arguments: [
        "I like it, you know, so we mean well, right?",
        "Uh-huh, uh-oh, mhm, mm, ah, er, the ER, umbrella, hummus, human, sum",
        "She attends UM and reads HMM papers. UM won.",
        "I met Um Ki-joon and Mr. Um at Umm Qasr.",
        "5 um and 10 hm", "um's um-hum _um um_ #um um.com um/uh 'um", "Hmm? Hmm!",
        "The word \"um\" and (uh) and “um.”",
        "  Leading and\n\n  inner   spacing, stays.  ", "ümlaut, 会um議, naïve um\u{301}", "",
    ])
    func everythingElseIsKept(text: String) { #expect(clean(text) == text) }

    @Test func vocabularyPhrasesAreKept() {
        #expect(clean("Umm Kulthum sang, um, well") == "Kulthum sang, well")
        #expect(
            clean(
                "Umm Kulthum sang, um, well",
                keeping: [
                    VocabularyEntry(word: "umm"), VocabularyEntry(word: "umm kulthum", replacement: "x"),
                ]) == "Umm Kulthum sang, well")
        #expect(clean("Um, uh", keeping: [VocabularyEntry(word: "um")]) == "Um")
        #expect(clean("Hm, um yes", keeping: [VocabularyEntry(word: "um")]) == "um yes")
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
