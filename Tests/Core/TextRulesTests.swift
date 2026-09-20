import Testing

@testable import AmanuensisCore

struct TextRulesTests {
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
        #expect(TextRules.apply("123... ßeta", vocabulary: [], capitalize: true) == "123... SSeta")
        #expect(TextRules.apply("42 🎉", vocabulary: [], capitalize: true) == "42 🎉")
    }

    @Test func countsWordsAcrossPunctuationAndUnicode() {
        #expect(TextRules.wordCount("Hello, world!\nDon't split O’Neil. José has 42 notes.") == 9)
        #expect(TextRules.wordCount("   ... 🎉  ") == 0)
        #expect(TextRules.wordCount("") == 0)
        #expect(TextRules.wordCount("'hello' well-known") == 3)
    }
}
