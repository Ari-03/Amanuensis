import Foundation

/// `apply` makes literal vocabulary corrections in one pass, then capitalizes the first letter. It works
/// across scripts: caseless scripts are left alone, and in scripts written without spaces, such as Chinese,
/// Japanese and Thai, a phrase matches wherever it appears. `removingFillers` is for English alone.
enum TextRules: Sendable {
    static func apply(_ text: String, vocabulary: [VocabularyEntry], capitalize: Bool) -> String {
        let rules = vocabulary.enumerated().compactMap { offset, entry -> ReplacementRule? in
            guard let replacement = entry.replacement, !entry.word.isEmpty else { return nil }
            return ReplacementRule(source: entry.word, replacement: replacement, order: offset)
        }.sorted {
            if $0.source.count != $1.source.count { return $0.source.count > $1.source.count }
            return $0.order < $1.order
        }

        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            var matchedRange: Range<String.Index>?
            var replacement = ""
            if startsWholeWord(at: cursor, in: text) {
                for rule in rules {
                    guard let range = match(rule.source, at: cursor, in: text) else { continue }
                    matchedRange = range
                    replacement = rule.replacement
                    break
                }
            }
            if let matchedRange {
                result.append(replacement)
                cursor = matchedRange.upperBound
            } else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }

        // Title case, not upper case: Georgian keeps its letters, and "ǆ" becomes "ǅ" rather than "Ǆ".
        if capitalize, let firstLetter = result.firstIndex(where: { $0.isLetter }) {
            result.replaceSubrange(firstLetter...firstLetter, with: titleCased(result[firstLetter]))
        }
        return result
    }

    /// English hesitations that are never words. "Er" (an ER), "mm" (millimetres), "mhm" and "uh-huh" (yes)
    /// are not here, nor is anything that can carry meaning, such as "like", "so" or "you know".
    private static let fillers: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "uhmm", "erm", "ermm", "hm", "hmm", "hmmm",
    ]

    /// Leaves standalone fillers out of an English transcript, with the pause around each one. Between two
    /// words, a comma or dash beside a filler stays once, so list items and clauses never run together.
    /// Anything uncertain is kept: capitals inside a sentence (names, "UM"), words joined by a hyphen or
    /// apostrophe, a filler quoted on its own, a possible unit after a number, "Hmm?", and every phrase in
    /// the vocabulary.
    static func removingFillers(from text: String, keeping vocabulary: [VocabularyEntry]) -> String {
        let kept = vocabulary.map(\.word).filter { !$0.isEmpty }
        var result = ""
        var cursor = text.startIndex
        // A capitalized filler was left out, so the next word starts its sentence.
        var capitalizeNext = false
        while cursor < text.endIndex {
            var end = text.index(after: cursor)
            if startsWholeWord(at: cursor, in: text) {
                if let phrase = kept.compactMap({ match($0, at: cursor, in: text)?.upperBound }).max() {
                    end = phrase
                    capitalizeNext = false
                } else if let next = skipFiller(at: cursor, in: text, result: &result) {
                    capitalizeNext = capitalizeNext || text[cursor].isUppercase
                    cursor = next
                    continue
                } else if text[cursor].isLetter || text[cursor].isNumber {
                    end = text[cursor...].firstIndex { !isWordCharacter($0) } ?? text.endIndex
                    // A word with its own capitals, such as "iPhone", keeps them.
                    if capitalizeNext, !text[cursor..<end].contains(where: \.isUppercase) {
                        result += titleCased(text[cursor])
                        cursor = text.index(after: cursor)
                    }
                    capitalizeNext = false
                }
            }
            result += text[cursor..<end]
            cursor = end
        }
        return result
    }

    /// Where copying resumes if a filler at `index` can be left out, after joining `result`, the text kept so
    /// far, to what follows. Nil keeps the word.
    private static func skipFiller(
        at index: String.Index, in text: String, result: inout String
    ) -> String.Index? {
        let word = text[index...].prefix(while: \.isLetter)
        guard fillers.contains(word.lowercased()), !word.dropFirst().contains(where: \.isUppercase)
        else { return nil }
        var rest = text[word.endIndex...]
        // Punctuation follows the filler directly, except a dash, which may stand apart.
        let spaced = rest.drop(while: isSpace)
        let standsApart = spaced.first.map(isDash) == true
        if standsApart { rest = spaced }
        let punctuation = rest.prefix { isPause($0) || isSentenceEnd($0) }
        rest = rest[punctuation.endIndex...]
        let opened = result.last.map(isOpening) == true
        let closed = rest.first.map(isClosing) == true
        let startsClean = result.last.map { $0.isWhitespace || isDash($0) || isOpening($0) } ?? true
        let endsClean = rest.first?.isWhitespace ?? true || closed || punctuation.last.map(isDash) == true
        guard startsClean, endsClean, !(opened && closed) else { return nil }

        let spoken = trimmed(result[...], while: isSpace)
        let isLineStart = spoken.last?.isNewline ?? true
        let startsSentence =
            isLineStart || opened
            || trimmed(spoken, while: isClosing).last.map(isSentenceEnd) == true
        if startsSentence {
            guard !punctuation.contains(where: { $0 == "?" || $0 == "!" }),
                !["Mr.", "Mrs.", "Ms.", "Dr.", "Prof."].contains(where: spoken.hasSuffix)
            else { return nil }
            // The filler opens the sentence or is all of it, so its own punctuation goes too.
            rest = rest.drop { isLineStart ? $0.isWhitespace : isSpace($0) }
            if rest.isEmpty {
                result = String(trimmed(spoken, while: \.isWhitespace))
            } else if rest.first?.isNewline == true || closed {
                result = String(spoken)
            }
            return rest.startIndex
        }
        guard word.first?.isUppercase == false, spoken.last?.isNumber == false else { return nil }
        let endsLine = rest.drop(while: isSpace).first?.isNewline ?? true
        let end = punctuation.firstIndex(where: isSentenceEnd)
        if end != nil || endsLine || closed {
            // The sentence ends here, so the pause that led into the filler goes.
            let sentence = trimmed(spoken) { isSpace($0) || isPause($0) }
            result = String(sentence) + punctuation[(end ?? punctuation.endIndex)...]
        } else if spoken.last.map(isPause) == true {
            // A dash written against the words stays against them.
            if result.last.map(isDash) == true { rest = rest.drop(while: isSpace) }
            result = String(spoken)
        } else {
            result = String(spoken) + (standsApart ? " " : "") + punctuation
        }
        // A dropped dash may have been all that separated the words.
        if let next = rest.first, isWordCharacter(next), result.last.map(isDash) != true { result += " " }
        return rest.startIndex
    }

    private static func match(
        _ phrase: String, at index: String.Index, in text: String
    ) -> Range<String.Index>? {
        guard
            let range = text.range(
                of: phrase, options: [.anchored, .caseInsensitive], range: index..<text.endIndex,
                locale: Locale(identifier: "en_US_POSIX")),
            endsWholeWord(at: range.upperBound, in: text)
        else { return nil }
        return range
    }

    private static func titleCased(_ character: Character) -> String {
        let scalars = character.unicodeScalars
        return (scalars.first?.properties.titlecaseMapping ?? "")
            + String(String.UnicodeScalarView(scalars.dropFirst()))
    }

    private static func trimmed(
        _ text: Substring, while matches: (Character) -> Bool
    ) -> Substring {
        var text = text
        while let last = text.last, matches(last) { text.removeLast() }
        return text
    }

    private static func isSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }
    private static func isDash(_ character: Character) -> Bool { "—–".contains(character) }
    private static func isPause(_ character: Character) -> Bool { ",;:—–".contains(character) }
    private static func isSentenceEnd(_ character: Character) -> Bool { ".?!…".contains(character) }
    private static func isOpening(_ character: Character) -> Bool { "\"“‘([".contains(character) }
    private static func isClosing(_ character: Character) -> Bool { "\"”)]".contains(character) }

    /// Counts letter/number runs, retaining internal apostrophes in contractions and names.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for index in text.indices {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if !inWord { count += 1 }
                inWord = true
            } else if isApostrophe(character), inWord {
                let next = text.index(after: index)
                inWord = next < text.endIndex && (text[next].isLetter || text[next].isNumber)
            } else {
                inWord = false
            }
        }
        return count
    }

    private struct ReplacementRule {
        var source: String
        var replacement: String
        var order: Int
    }

    private static func startsWholeWord(at index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text.index(before: index)
        if isUnspaced(text[previous]) || isUnspaced(text[index]) { return true }
        if isWordCharacter(text[previous]) { return false }
        if isApostrophe(text[previous]), previous > text.startIndex {
            return !isWordCharacter(text[text.index(before: previous)])
        }
        return true
    }

    private static func endsWholeWord(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        if isUnspaced(text[index]) || (index > text.startIndex && isUnspaced(text[text.index(before: index)]))
        {
            return true
        }
        if isWordCharacter(text[index]) { return false }
        let next = text.index(after: index)
        if isApostrophe(text[index]), next < text.endIndex {
            return !isWordCharacter(text[next])
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
            || character.unicodeScalars.contains {
                $0.properties.generalCategory == .nonspacingMark
                    || $0.properties.generalCategory == .spacingMark
                    || $0.properties.generalCategory == .enclosingMark
            }
    }

    /// Han, kana, Thai, Lao, Myanmar and Khmer are written without spaces between words, so a word
    /// boundary cannot be found from the characters around a match.
    private static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,  // Hiragana and Katakana
            0x0E00...0x0EFF,  // Thai and Lao
            0x1000...0x109F,  // Myanmar
            0x1780...0x17FF:  // Khmer
            return true
        default: return false
        }
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }
}

extension RecordingEntry {
    /// What cleanup and vocabulary replacements start from. Fillers are left out here rather than from a
    /// cleanup model's output, which may be in another language where "um" is a word. Detection does not
    /// say which language was spoken, so only a recording set to English qualifies.
    var transcript: String {
        guard mode.removesFillers, transcriptionLanguage == .english else { return rawText }
        return TextRules.removingFillers(from: rawText, keeping: vocabularySnapshot ?? [])
    }
}
