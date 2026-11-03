import XCTest
@testable import PwndCore

final class ClassifierTests: XCTestCase {
    let c = Classifier(.defaults)

    func testCriticalKeywordAnywhere() {
        XCTAssertEqual(c.classify(title: "v2.5.6", text: "Fixes GHSA-abcd-1234-wxyz in the PSBT parser").severity, .critical)
        XCTAssertEqual(c.classify(title: "1.0", text: "Addresses CVE-2026-12345.").severity, .critical)
        XCTAssertEqual(c.classify(title: "1.0", text: "A vulnerability was found").severity, .critical)
    }

    func testSignalInTitleIsCritical() {
        let r = c.classify(title: "BTCPay Server 2.4.4: Security Update", text: "")
        XCTAssertEqual(r.severity, .critical)
        XCTAssertEqual(r.matches, ["security"])
    }

    func testOneSignalInBodyIsOnlyImportant() {
        XCTAssertEqual(c.classify(title: "How a merchant scaled", text: "great security and uptime").severity, .important)
    }

    func testTwoSignalsInBodyAreCritical() {
        XCTAssertEqual(c.classify(title: "2.4.7", text: "addresses security issues, including one critical").severity, .critical)
    }

    func testWordStartBoundary() {
        // "fix" style keywords must not match inside another word.
        let k = Classifier(KeywordConfig(critical: ["sec"], signals: [], important: [], ignore: []))
        XCTAssertEqual(k.classify(title: "insecure", text: "").severity, .routine)
        XCTAssertEqual(k.classify(title: "security", text: "").severity, .critical)
    }

    func testPhraseMatchesAcrossWhitespace() {
        XCTAssertEqual(c.classify(title: "", text: "Please upgrade\n  immediately").severity, .critical)
    }

    func testIgnorePhrasesAreRemovedFirst() {
        XCTAssertEqual(c.classify(title: "v0.12.0", text: "• Add SECURITY.md.").severity, .routine)
    }

    func testIgnorePhraseToleratesLineBreaksAndMarkdown() {
        var k = KeywordConfig.defaults
        k.ignore.append("Emergency-exit fee API reworked")
        let c = Classifier(k)
        let notes = "## Breaking\n- **Emergency-exit**\n  fee API   reworked: `ExitFeeEstimate::fundable`"
        XCTAssertEqual(c.classify(title: "bark-0.8.0", text: notes).severity, .routine)
        // Only the phrase goes: other words in the same notes still count.
        XCTAssertEqual(c.classify(title: "bark-0.8.0", text: notes + "\nFixes a vulnerability.").severity, .critical)
    }

    func testIgnoreAcceptsRegex() {
        var k = KeywordConfig.defaults
        k.ignore.append("/emergency[- ]exit/")
        XCTAssertEqual(Classifier(k).classify(title: "", text: "Emergency exit flow").severity, .routine)
    }

    func testRoutine() {
        let r = c.classify(title: "Bitcoin Core 32.1", text: "Bitcoin Core version 32.1 is now available")
        XCTAssertEqual(r.severity, .routine)
        XCTAssertEqual(r.matches, [])
    }

    func testInvalidRegexIsReportedAndSkipped() {
        XCTAssertNotNil(Classifier.problem(with: "/[unclosed/"))
        XCTAssertNil(Classifier.problem(with: "/CVE-\\d+/"))
        let k = Classifier(KeywordConfig(critical: ["/[unclosed/"], signals: [], important: [], ignore: []))
        XCTAssertEqual(k.classify(title: "[unclosed", text: "").severity, .routine)
    }
}

final class ParserTests: XCTestCase {
    func testGitHubAtom() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <id>tag:github.com,2008:https://github.com/x/y/releases</id>
          <title>Release notes from y</title>
          <entry>
            <id>tag:github.com,2008:Repository/1/v1.2</id>
            <updated>2026-10-28T14:23:53Z</updated>
            <link rel="alternate" type="text/html" href="https://github.com/x/y/releases/tag/v1.2"/>
            <title>y 1.2 &amp; friends</title>
            <content type="html">&lt;p&gt;Fixes &lt;b&gt;CVE-2026-1&lt;/b&gt;&lt;/p&gt;&lt;ul&gt;&lt;li&gt;one&lt;/li&gt;&lt;/ul&gt;</content>
            <author><name>alice</name></author>
          </entry>
        </feed>
        """
        let entries = try FeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(entries.count, 1)
        let e = entries[0]
        XCTAssertEqual(e.key, "tag:github.com,2008:Repository/1/v1.2")
        XCTAssertEqual(e.title, "y 1.2 & friends")
        XCTAssertEqual(e.link?.absoluteString, "https://github.com/x/y/releases/tag/v1.2")
        XCTAssertEqual(e.author, "alice")
        XCTAssertEqual(e.text, "Fixes CVE-2026-1\n• one")
        XCTAssertEqual(e.published, ISO8601DateFormatter().date(from: "2026-10-28T14:23:53Z"))
    }

    func testRSS() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Blog</title>
          <link>https://blog.example</link>
          <item>
            <title>Security Advisory</title>
            <link>https://blog.example/advisory</link>
            <guid>https://blog.example/advisory</guid>
            <pubDate>Fri, 07 Aug 2026 10:00:00 +0000</pubDate>
            <description><![CDATA[<p>Update <em>now</em>.</p>]]></description>
          </item>
        </channel></rss>
        """
        let entries = try FeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Security Advisory")
        XCTAssertEqual(entries[0].link?.absoluteString, "https://blog.example/advisory")
        XCTAssertEqual(entries[0].text, "Update now.")
        XCTAssertNotNil(entries[0].published)
    }

    func testRejectsNonFeed() {
        XCTAssertThrowsError(try FeedParser.parse(Data("<html><body>hi</body></html>".utf8)))
        XCTAssertThrowsError(try FeedParser.parse(Data("not xml".utf8)))
    }

    func testEntities() {
        XCTAssertEqual(HTMLText.decodeEntities("a &lt;b&gt; &#39;c&#x27; &amp;amp; &bogus;"), "a <b> 'c' &amp; &bogus;")
    }
}

final class FeedInputTests: XCTestCase {
    func testOwnerRepo() {
        let r = FeedInput.resolve("bitcoin/bitcoin")
        XCTAssertEqual(r?.name, "bitcoin/bitcoin")
        XCTAssertEqual(r?.url.absoluteString, "https://github.com/bitcoin/bitcoin/releases.atom")
    }

    func testGitHubURLs() {
        XCTAssertEqual(FeedInput.resolve("https://github.com/lightningnetwork/lnd/releases")?.url.absoluteString,
                       "https://github.com/lightningnetwork/lnd/releases.atom")
        XCTAssertEqual(FeedInput.resolve("https://github.com/x/y.git")?.url.absoluteString,
                       "https://github.com/x/y/releases.atom")
        XCTAssertEqual(FeedInput.resolve("https://github.com/x/y/tags.atom")?.url.absoluteString,
                       "https://github.com/x/y/tags.atom")
    }

    func testGitLabURLs() {
        let r = FeedInput.resolve("https://gitlab.com/ark-bitcoin/bark")
        XCTAssertEqual(r?.name, "ark-bitcoin/bark")
        XCTAssertEqual(r?.url.absoluteString, "https://gitlab.com/ark-bitcoin/bark/-/releases.atom")
        XCTAssertEqual(FeedInput.resolve("gitlab.com/ark-bitcoin/bark/-/releases")?.url.absoluteString,
                       "https://gitlab.com/ark-bitcoin/bark/-/releases.atom")
        XCTAssertEqual(FeedInput.resolve("https://gitlab.com/group/sub/project.git")?.name, "group/sub/project")
        XCTAssertEqual(FeedInput.resolve("https://gitlab.com/x/y/-/tags?format=atom")?.url.absoluteString,
                       "https://gitlab.com/x/y/-/releases.atom")
        XCTAssertEqual(FeedInput.resolve("https://gitlab.com/x/y/-/releases.atom")?.url.absoluteString,
                       "https://gitlab.com/x/y/-/releases.atom")
        XCTAssertNil(FeedInput.resolve("https://gitlab.com/justagroup"))
        XCTAssertEqual(FeedInput.resolve("github.com/bitcoin/bitcoin")?.name, "bitcoin/bitcoin")
    }

    func testOtherURLsAndJunk() {
        XCTAssertEqual(FeedInput.resolve("https://www.blog.example/rss.xml")?.name, "blog.example")
        XCTAssertNil(FeedInput.resolve("ftp://x/y.xml"))
        XCTAssertNil(FeedInput.resolve("   "))
        XCTAssertNil(FeedInput.resolve("not a url"))
    }
}

final class MergeTests: XCTestCase {
    let classifier = Classifier(.defaults)
    let feed = Feed(name: "x/y", url: URL(string: "https://github.com/x/y/releases.atom")!)

    func parsed(_ key: String, _ title: String = "release", days: Double = 0) -> ParsedEntry {
        ParsedEntry(key: key, title: title, link: nil, published: Date(timeIntervalSince1970: 1_800_000_000 + days * 86400),
                    author: nil, text: "")
    }

    func testSeedingStartsInNewAndReportsNothing() {
        let r = Merge.apply([parsed("a"), parsed("b", "Security fix")], feed: feed, into: [], classifier: classifier, seeding: true)
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertTrue(r.entries.allSatisfy { !$0.read && $0.seeded })
        XCTAssertTrue(r.new.isEmpty)
    }

    func testOnlyUnknownEntriesAreNew() {
        let seeded = Merge.apply([parsed("a")], feed: feed, into: [], classifier: classifier, seeding: true).entries
        let r = Merge.apply([parsed("b", "Security fix"), parsed("a")], feed: feed, into: seeded, classifier: classifier, seeding: false)
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.new.map(\.title), ["Security fix"])
        XCTAssertEqual(r.new.first?.severity, .critical)
        XCTAssertEqual(r.new.first?.read, false)
    }

    func testCapsEntriesPerFeedKeepingNewest() {
        let many = (0..<(Merge.maxEntriesPerFeed + 10)).map { parsed("k\($0)", days: Double($0)) }
        let r = Merge.apply(many, feed: feed, into: [], classifier: classifier, seeding: true)
        XCTAssertEqual(r.entries.count, Merge.maxEntriesPerFeed)
        XCTAssertFalse(r.entries.contains { $0.id.hasSuffix("/k0") })
        XCTAssertTrue(r.entries.contains { $0.id.hasSuffix("/k209") })
    }

    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Persistence(url: dir.appendingPathComponent("state.json"))
        let entries = Merge.apply([parsed("a")], feed: feed, into: [], classifier: classifier, seeding: true,
                                  now: Date(timeIntervalSince1970: 1_800_000_000)).entries  // ISO-8601 keeps whole seconds
        try p.save(Snapshot(groups: [FeedGroup(name: "Lightning")], feeds: [feed], entries: entries, settings: .defaults))
        guard case .loaded(let back) = p.load() else { return XCTFail("did not load") }
        XCTAssertEqual(back.feeds, [feed])
        XCTAssertEqual(back.entries, entries)
        XCTAssertEqual(back.settings, AppSettings.defaults)
    }

    func testUnreadableStateIsMovedAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.json")
        try Data("{ not json".utf8).write(to: url)
        guard case .unreadable(_, let movedTo) = Persistence(url: url).load() else { return XCTFail("expected unreadable") }
        let aside = try XCTUnwrap(movedTo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ not json")
    }

    func testSnapshotWithoutGroupsStillLoads() throws {
        // State saved before groups existed: no "groups" key, no "groupID" on feeds.
        let json = """
        {"version":1,"feeds":[{"id":"\(feed.id.uuidString)","name":"x/y","url":"https://github.com/x/y/releases.atom","seeded":true}],
         "entries":[],"settings":{"pollMinutes":15,"notifyImportant":false,
         "keywords":{"critical":[],"signals":[],"important":[],"ignore":[]}}}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let snap = try d.decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.groups, [])
        XCTAssertEqual(snap.feeds.count, 1)
        XCTAssertNil(snap.feeds[0].groupID)
    }

    func testSeverityTagsDefaultOffIncludingOlderSettings() throws {
        XCTAssertFalse(AppSettings.defaults.showSeverity)
        let old = #"{"pollMinutes": 30, "notifyImportant": true}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertFalse(s.showSeverity)
        XCTAssertEqual(s.pollMinutes, 30)
    }

    func testDefaultFeedsAreFiledInGroups() {
        let (groups, feeds, order) = DefaultFeeds.make()
        XCTAssertEqual(groups.map(\.name), ["mempool", "Lightning", "Wallets", "Hardware", "BTCPayServer"])
        let lightning = groups[1].id
        XCTAssertEqual(feeds.filter { $0.groupID == lightning }.map(\.name),
                       ["lightningnetwork/lnd", "ElementsProject/lightning", "ACINQ/phoenixd"])
        XCTAssertNil(feeds.first { $0.name == "bitcoin/bitcoin" }?.groupID)
        XCTAssertEqual(feeds.count, 14)
        // The sidebar order matches the shared OPML list: bitcoin/bitcoin, then the groups.
        let list = FeedList(order: order, groups: groups, feeds: feeds)
        XCTAssertEqual(list.allFeeds.first?.name, "bitcoin/bitcoin")
        XCTAssertEqual(list.allFeeds.last?.name, "btcpayserver/btcpayserver")
    }
}

