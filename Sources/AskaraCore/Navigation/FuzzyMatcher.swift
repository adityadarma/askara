import Foundation

/// Scores how well typed text matches a label, for the command palette.
/// Every typed word must match: as a prefix of the label, at the start of a word, anywhere,
/// or as an in-order subsequence ("cpa" → "Copy Page Address"). Higher is better.
public enum FuzzyMatcher {
    /// `allowsSubsequence: false` for long text such as URLs, where a few scattered letters match almost anything.
    public static func score(_ rawQuery: String, in text: String, allowsSubsequence: Bool = true) -> Int? {
        let words = rawQuery.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        let haystack = text.lowercased()
        var total = 0
        for word in words {
            guard let score = wordScore(word, in: haystack, allowsSubsequence: allowsSubsequence) else { return nil }
            total += score
        }
        // Among equal matches, shorter labels are closer to what was typed.
        return total * 100 - min(99, haystack.count)
    }

    static func wordScore(_ word: String, in haystack: String, allowsSubsequence: Bool = true) -> Int? {
        if haystack.hasPrefix(word) { return 100 }
        if let range = haystack.range(of: word) {
            let before = haystack[..<range.lowerBound].last
            let atWordStart = before.map { !$0.isLetter && !$0.isNumber } ?? true
            return atWordStart ? 80 : 50
        }
        return allowsSubsequence ? subsequenceScore(word, in: haystack) : nil
    }

    /// Letters in order. Word initials ("cpa" → "Copy Page Address") score higher than letters
    /// scattered through the text. nil when the letters don't all appear in order.
    static func subsequenceScore(_ word: String, in haystack: String) -> Int? {
        guard word.count >= 2 else { return nil }
        var initials = ""
        var previous: Character?
        for char in haystack {
            if char.isLetter || char.isNumber, previous.map({ !$0.isLetter && !$0.isNumber }) ?? true {
                initials.append(char)
            }
            previous = char
        }
        if isSubsequence(word, of: initials) { return 40 }
        return isSubsequence(word, of: haystack) ? 15 : nil
    }

    private static func isSubsequence(_ needle: String, of text: String) -> Bool {
        var remaining = needle[...]
        for char in text where char == remaining.first {
            remaining.removeFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
