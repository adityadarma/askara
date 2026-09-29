import Foundation
import Testing
@testable import HematCore

@Suite struct BlockListParserTests {
    @Test func parsesHostsPlainAndAdblockFormats() {
        let text = """
        # comment
        ! adblock comment
        [Adblock Plus 2.0]
        0.0.0.0 ads.example.com
        127.0.0.1   tracker.example.net  # trailing comment
        plain-domain.org
        ||adblock.example.io^
        ||path.example.io/ads.js
        ||option.example.io^$third-party
        """
        #expect(BlockListParser.parseDomains(text) ==
                ["ads.example.com", "tracker.example.net", "plain-domain.org", "adblock.example.io"])
    }

    @Test func rejectsInvalidAndProtectedEntries() {
        let text = """
        127.0.0.1 localhost
        0.0.0.0 0.0.0.0
        0.0.0.0 google.com
        0.0.0.0 bad_domain.com
        0.0.0.0 -bad.com
        0.0.0.0 nodot
        0.0.0.0 evil.com"]},{"action
        0.0.0.0 GOOD.Example.COM
        0.0.0.0 good.example.com
        """
        #expect(BlockListParser.parseDomains(text) == ["good.example.com"])
    }

    @Test func respectsMaximum() {
        let text = (0..<(BlockListParser.maxDomains + 10)).map { "d\($0).com" }.joined(separator: "\n")
        #expect(BlockListParser.parseDomains(text).count == BlockListParser.maxDomains)
    }

    @Test func mergedDedupesAndSorts() {
        let merged = BlockList.merged(with: ["zzz.com", "doubleclick.net", "aaa.com"])
        #expect(merged.first == "aaa.com")
        #expect(merged.filter { $0 == "doubleclick.net" }.count == 1)
        #expect(merged == merged.sorted())
    }

    @Test func checkIntervalIsDaily() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(BlockListMetadata().needsCheck(now: now))
        #expect(!BlockListMetadata(lastChecked: now.addingTimeInterval(-3_600)).needsCheck(now: now))
        #expect(BlockListMetadata(lastChecked: now.addingTimeInterval(-90_000)).needsCheck(now: now))
        // System clock went backwards: check again.
        #expect(BlockListMetadata(lastChecked: now.addingTimeInterval(3_600)).needsCheck(now: now))
    }
}
