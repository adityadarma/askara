import Foundation
import Testing
@testable import AskaraCore

@Suite("Performance regressions")
struct PerformanceRegressionTests {
    @Test("Unchanged history titles do not trigger a mutation")
    func historyTitleNoOpDetection() throws {
        let url = try #require(URL(string: "https://example.com"))
        var history = HistoryStore()

        let missingChanged = history.updateTitle("Missing", for: url)
        #expect(!missingChanged)
        history.record(url: url, title: "Original", at: Date(timeIntervalSince1970: 1))
        let sameChanged = history.updateTitle(" Original ", for: url)
        #expect(!sameChanged)
        let updated = history.updateTitle("Updated", for: url)
        #expect(updated)
        #expect(history.entries.first?.title == "Updated")
    }

    @Test("Address suggestions handle a full history with a bounded result")
    func fullHistorySuggestionRanking() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let history = try (0..<5_000).map { index in
            HistoryEntry(url: try #require(URL(string: "https://example\(index).test/page")),
                         title: "Example page \(index)",
                         lastVisited: now.addingTimeInterval(TimeInterval(-(index / 10))),
                         visitCount: index % 7 + 1)
        }

        let suggestions = AddressSuggester.suggestions(
            for: "example", history: history, bookmarks: [], now: now, limit: 6)

        #expect(suggestions.count == 6)
        #expect(Set(suggestions.map(\.url)).count == 6)
        #expect(suggestions.allSatisfy { $0.url.host?.hasPrefix("example") == true })

        let reference = history.compactMap { entry -> (suggestion: AddressSuggestion, score: Double, date: Date)? in
            let query = "example"
            guard let match = AddressSuggester.matchScore(words: [query], query: query,
                                                          url: entry.url, title: entry.title) else { return nil }
            let days = max(0, now.timeIntervalSince(entry.lastVisited)) / 86_400
            let recency: Double = days < 1 ? 10 : days < 7 ? 6 : days < 30 ? 3 : 0
            return (AddressSuggestion(kind: .history, url: entry.url, title: entry.title),
                    match + log2(Double(entry.visitCount) + 1) * 8 + recency, entry.lastVisited)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.suggestion.url.absoluteString < $1.suggestion.url.absoluteString
        }.prefix(6).map(\.suggestion)
        #expect(suggestions == reference)

        var cancellationChecks = 0
        let cancelled = AddressSuggester.suggestions(
            for: "example", history: history, bookmarks: [], now: now, limit: 6,
            isCancelled: {
                cancellationChecks += 1
                return cancellationChecks >= 3
            })
        #expect(cancelled.isEmpty)
        #expect(cancellationChecks == 3)
    }
}
