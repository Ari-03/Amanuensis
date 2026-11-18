import Testing

@testable import AmanuensisCore

struct TextRulesTests {
    @Test func capitalizationFollowsEachScriptsOwnRules() {
        #expect(TextRules.apply("привет, мир", vocabulary: [], capitalize: true) == "Привет, мир")
        #expect(TextRules.apply("ελάτε αύριο", vocabulary: [], capitalize: true) == "Ελάτε αύριο")
        // Georgian has no sentence capitals; upper-casing would switch to the Mtavruli alphabet.
        #expect(TextRules.apply("გამარჯობა", vocabulary: [], capitalize: true) == "გამარჯობა")
        // Caseless scripts pass through unchanged.
        #expect(TextRules.apply("مرحبا بالعالم", vocabulary: [], capitalize: true) == "مرحبا بالعالم")
        #expect(TextRules.apply("「会議は木曜です」", vocabulary: [], capitalize: true) == "「会議は木曜です」")
        // A digraph letter takes its title form.
        #expect(TextRules.apply("ǆungla", vocabulary: [], capitalize: true) == "ǅungla")
    }

    @Test func phrasesMatchInsideScriptsWrittenWithoutSpaces() {
        let vocabulary = [
            VocabularyEntry(word: "东京", replacement: "Tokyo"),
            VocabularyEntry(word: "さら", replacement: "サラ"),
        ]
        #expect(TextRules.apply("我在东京工作。", vocabulary: vocabulary, capitalize: true) == "我在Tokyo工作。")
        #expect(
            TextRules.apply("メモをさらさんに送って", vocabulary: vocabulary, capitalize: false)
                == "メモをサラさんに送って")
    }

    @Test func spacedNonLatinScriptsKeepWholeWordMatching() {
        let vocabulary = [
            VocabularyEntry(word: "мир", replacement: "Mir"),
            VocabularyEntry(word: "नमस्ते", replacement: "Namaste"),
        ]
        #expect(
            TextRules.apply("Мир и мирный мир", vocabulary: vocabulary, capitalize: false)
                == "Mir и мирный Mir")
        // Devanagari vowel signs are part of the word, so a longer word is not split.
        #expect(
            TextRules.apply("नमस्ते नमस्तेजी", vocabulary: vocabulary, capitalize: false) == "Namaste नमस्तेजी")
    }

    @Test func replacementsUseLongestPhraseAndDoNotCascade() {
        let vocabulary = [
            VocabularyEntry(word: "super", replacement: "great"),
            VocabularyEntry(word: "super whisper", replacement: "Superwhisper"),
            VocabularyEntry(word: "Superwhisper", replacement: "another app"),
        ]
        #expect(
            TextRules.apply("super whisper is super", vocabulary: vocabulary, capitalize: false)
                == "Superwhisper is great")
    }

    @Test func equalLengthDuplicatesUseFirstEntry() {
        let vocabulary = [
            VocabularyEntry(word: "hello", replacement: "first"),
            VocabularyEntry(word: "HELLO", replacement: "second"),
        ]
        #expect(TextRules.apply("Hello", vocabulary: vocabulary, capitalize: false) == "first")
    }

    @Test func literalMatchingPreservesPunctuationAndWhitespace() {
        let vocabulary = [VocabularyEntry(word: "c++", replacement: "$Swift\\code")]
        #expect(
            TextRules.apply("  C++, (c++).\nc++20 xc++", vocabulary: vocabulary, capitalize: false)
                == "  $Swift\\code, ($Swift\\code).\nc++20 xc++")
    }

    @Test func wordBoundariesProtectContractionsAndNames() {
        let vocabulary = [
            VocabularyEntry(word: "can", replacement: "could"),
            VocabularyEntry(word: "Neil", replacement: "Niall"),
        ]
        #expect(
            TextRules.apply(
                "can can't can’t candy _can can2 'can' ‘can’ O'Neil O’Neil Neil!",
                vocabulary: vocabulary, capitalize: false
            ) == "could can't can’t candy _can can2 'could' ‘could’ O'Neil O’Neil Niall!")
    }

    @Test func unicodeNamesMatchWithoutRemovingAccents() {
        let vocabulary = [VocabularyEntry(word: "josé", replacement: "José García")]
        #expect(
            TextRules.apply("JOSÉ, josé, jose, joséphine", vocabulary: vocabulary, capitalize: false)
                == "José García, José García, jose, joséphine")
    }

    @Test func hintsAndEmptySourcesDoNotChangeText() {
        let vocabulary = [
            VocabularyEntry(word: "Aritra"),
            VocabularyEntry(word: "", replacement: "unexpected"),
        ]
        #expect(TextRules.apply("  aritra\n", vocabulary: vocabulary, capitalize: false) == "  aritra\n")
        #expect(TextRules.apply("", vocabulary: vocabulary, capitalize: true) == "")
    }

    @Test func emptyReplacementDeletesOnlyMatchedText() {
        let vocabulary = [VocabularyEntry(word: "um", replacement: "")]
        #expect(
            TextRules.apply("um, hello umbrella", vocabulary: vocabulary, capitalize: false)
                == ", hello umbrella")
    }

    @Test func capitalizationFindsFirstLetterAndPreservesRest() {
        #expect(
            TextRules.apply("  \"éclair and NASA\"", vocabulary: [], capitalize: true)
                == "  \"Éclair and NASA\"")
        // Title case: a word-initial ß becomes "Ss", not the all-caps "SS".
        #expect(TextRules.apply("123... ßeta", vocabulary: [], capitalize: true) == "123... Sseta")
        #expect(TextRules.apply("42 🎉", vocabulary: [], capitalize: true) == "42 🎉")
    }

    @Test func countsWordsAcrossPunctuationAndUnicode() {
        #expect(TextRules.wordCount("Hello, world!\nDon't split O’Neil. José has 42 notes.") == 9)
        #expect(TextRules.wordCount("   ... 🎉  ") == 0)
        #expect(TextRules.wordCount("") == 0)
        #expect(TextRules.wordCount("'hello' well-known") == 3)
    }
}
