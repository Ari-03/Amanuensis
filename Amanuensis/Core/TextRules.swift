import Foundation

/// Applies literal vocabulary corrections to the original transcript in one pass.
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

        if capitalize, let firstLetter = result.firstIndex(where: { $0.isLetter }) {
            let end = result.index(after: firstLetter)
            result.replaceSubrange(firstLetter..<end, with: result[firstLetter].uppercased())
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
        if isWordCharacter(text[previous]) { return false }
        if isApostrophe(text[previous]), previous > text.startIndex {
            return !isWordCharacter(text[text.index(before: previous)])
        }
        return true
    }

    private static func endsWholeWord(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
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

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }
}
