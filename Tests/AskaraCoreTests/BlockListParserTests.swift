import Foundation
import Testing
@testable import AskaraCore

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

    @Test func parsesManualEntries() {
        let text = """
        Ads.Example.com
        https://www.tracker.net:8080/path/x.js?a=1
        ||adblock.example.io^, *.wild.example.org
        google.com 127.0.0.1 nodot bad_domain.com
        ads.example.com
        """
        #expect(BlockListParser.parseManual(text) ==
                ["adblock.example.io", "ads.example.com", "wild.example.org", "www.tracker.net"])
    }

    @Test func wasmArcadeAdsAreSeededAsManualNotAutomatic() {
        #expect(BlockList.initialCustomDomains.count == 9)
        for domain in BlockList.initialCustomDomains {
            #expect(BlockListParser.normalizeManualEntry(domain) == domain)
            #expect(!BlockList.domains.contains(domain))
        }
    }
}

@Suite struct ElementHideRuleTests {
    @Test func parsesSiteAndSelector() throws {
        let rule = try #require(ElementHideRule.parse("https://Z2.IdlixKu.com/series/x ## a[href*=\"rebrand.ly\"]"))
        #expect(rule.site == "z2.idlixku.com")
        #expect(rule.selector == "a[href*=\"rebrand.ly\"]")
        #expect(rule.text == "z2.idlixku.com##a[href*=\"rebrand.ly\"]")
    }

    @Test func rejectsInvalidRules() {
        #expect(ElementHideRule.parse("no-separator") == nil)
        #expect(ElementHideRule.parse("##a.ad") == nil)
        #expect(ElementHideRule.parse("localhost##a.ad") == nil)
        #expect(ElementHideRule.parse("example.com##") == nil)
        #expect(ElementHideRule.parse("example.com##a{color:red}") == nil)
        #expect(ElementHideRule.parse("example.com##a[href") == nil)
        #expect(ElementHideRule.parse("example.com##a\\b") == nil)
    }

    @Test func parseAllSkipsInvalidDeduplicatesAndSorts() {
        let text = """
        b.com##.ad
        bad line
        a.com##.ad
        b.com##.ad
        """
        #expect(ElementHideRule.parseAll(text).map(\.text) == ["a.com##.ad", "b.com##.ad"])
    }

    @Test func jsonContainsHideRuleForSiteAndSubdomains() throws {
        let rule = try #require(ElementHideRule.parse("example.com##a[href*=\"ads\"]"))
        let data = Data(BlockList.contentRuleListJSON(domains: [], hiding: [rule]).utf8)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(parsed.count == YouTubeAdRules.selectors.count + 1)
        let last = try #require(parsed.last)
        let action = try #require(last["action"] as? [String: Any])
        #expect(action["type"] as? String == "css-display-none")
        #expect(action["selector"] as? String == "a[href*=\"ads\"]")
        let pattern = try #require((last["trigger"] as? [String: Any])?["url-filter"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        #expect(matches("https://example.com/a"))
        #expect(matches("https://www.example.com/"))
        #expect(!matches("https://notexample.com/"))
        #expect(!matches("https://example.com.evil.org/"))
    }
}
