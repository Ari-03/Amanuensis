import Foundation

/// Applies literal vocabulary corrections to the original transcript in one pass, then capitalizes
/// the first letter. Works across scripts: caseless scripts are left alone, and in scripts written
/// without spaces, such as Chinese, Japanese and Thai, a phrase matches wherever it appears.
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
                    guard
                        let range = text.range(
                            of: rule.source,
                            options: [.anchored, .caseInsensitive],
                            range: cursor..<text.endIndex,
                            locale: Locale(identifier: "en_US_POSIX")
                        ), endsWholeWord(at: range.upperBound, in: text)
                    else { continue }
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
            let end = result.index(after: firstLetter)
            let scalars = result[firstLetter].unicodeScalars
            let titled =
                (scalars.first?.properties.titlecaseMapping ?? "")
                + String(String.UnicodeScalarView(scalars.dropFirst()))
            result.replaceSubrange(firstLetter..<end, with: titled)
        }
        return result
    }

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
