import Foundation
import Testing
@testable import AskaraCore

@Suite struct DownloadHistoryTests {
    @Test func terminalRecordRoundTrips() throws {
        let record = DownloadHistory.Record(
            id: UUID(), filename: "archive.zip", destination: URL(fileURLWithPath: "/tmp/archive.zip"),
            sourceURL: URL(string: "https://example.com/archive.zip"), endedAt: Date(timeIntervalSince1970: 123),
            outcome: .finished, scanOutcome: .complete, sha256: "abc", risks: [.archive], fileSize: 42)
        let history = DownloadHistory(records: [record])
        let decoded = try JSONDecoder().decode(DownloadHistory.self, from: JSONEncoder().encode(history))

        #expect(decoded == history)
    }
}
