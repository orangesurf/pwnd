import XCTest
@testable import PwndCore

final class ServerTests: XCTestCase {
    func testAddressClassification() {
        XCTAssertEqual(ServerAddress.classify("192.168.1.10"), .ipv4)
        XCTAssertEqual(ServerAddress.classify(" 10.0.0.1 "), .ipv4)
        XCTAssertEqual(ServerAddress.classify("0.0.0.0"), .ipv4)
        XCTAssertEqual(ServerAddress.classify("::1"), .ipv6)
        XCTAssertEqual(ServerAddress.classify("2001:db8::8a2e:370:7334"), .ipv6)
        XCTAssertEqual(ServerAddress.classify("[fe80::1%en0]"), .ipv6)
        XCTAssertEqual(ServerAddress.classify("::ffff:192.168.1.1"), .ipv6)
        XCTAssertEqual(ServerAddress.classify("1:2:3:4:5:6:7:8"), .ipv6)
        XCTAssertEqual(ServerAddress.classify("node.local"), .hostname)
        XCTAssertEqual(ServerAddress.classify("umbrel"), .hostname)

        for bad in ["", "   ", "256.1.1.1", "1.2.3", "01.2.3.4", "192.168.1.", "1:2:3:4:5:6:7:8:9",
                    "1::2::3", "gggg::1", "-bad.host", "has space", "under_score.lan", "1.2.3.4.5"] {
            XCTAssertNil(ServerAddress.classify(bad), bad)
        }
    }

    func testInstallSkipsDuplicatesAndKeepsOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        var s = Server(name: "node", address: "10.0.0.2")
        XCTAssertTrue(s.install([a, b]))
        XCTAssertFalse(s.install([b, a]))
        XCTAssertTrue(s.install([c, a]))
        XCTAssertEqual(s.feedIDs, [a, b, c])
        s.uninstall([b])
        XCTAssertEqual(s.feedIDs, [a, c])
    }

    func testSearchMatchesEveryWordInNameOrURL() {
        let f = Feed(name: "lightningnetwork/lnd", url: URL(string: "https://github.com/lightningnetwork/lnd/releases.atom")!)
        XCTAssertTrue(SoftwareSearch.matches(f, query: ""))
        XCTAssertTrue(SoftwareSearch.matches(f, query: "LND"))
        XCTAssertTrue(SoftwareSearch.matches(f, query: "lightning github"))
        XCTAssertFalse(SoftwareSearch.matches(f, query: "lnd bitcoin"))
    }

    func testSnapshotRoundTripsServersAndOldStateStillLoads() throws {
        let feed = Feed(name: "bitcoin/bitcoin", url: URL(string: "https://github.com/bitcoin/bitcoin/releases.atom")!)
        let server = Server(name: "Home node", address: "192.168.1.20", notes: "rack", feedIDs: [feed.id],
                            versions: [feed.id.uuidString: "29.4"])
        let snap = Snapshot(feeds: [feed], entries: [], settings: .defaults, servers: [server])
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(Snapshot.self, from: e.encode(snap))
        XCTAssertEqual(back.servers, [server])

        // State written before servers existed has no "servers" key.
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: e.encode(snap)) as? [String: Any])
        obj.removeValue(forKey: "servers")
        let old = try d.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(old.servers, [])
    }

    func testAddressIsOptional() {
        XCTAssertTrue(ServerAddress.isAcceptable(""))
        XCTAssertTrue(ServerAddress.isAcceptable("  "))
        XCTAssertTrue(ServerAddress.isAcceptable("node.local"))
        XCTAssertFalse(ServerAddress.isAcceptable("256.1.1.1"))
    }

    func testPruneDropsUnsubscribedSoftware() {
        let a = UUID(), b = UUID()
        var s = Server(name: "node", address: "", feedIDs: [a, b])
        XCTAssertTrue(s.prune(keeping: [b]))
        XCTAssertEqual(s.feedIDs, [b])
        XCTAssertFalse(s.prune(keeping: [b]))
    }

    private func entry(_ title: String, feed: UUID, _ severity: Severity = .routine, minutesAgo: Double = 0,
                       read: Bool = false, kind: EntryKind? = .release) -> Entry {
        Entry(id: "\(feed)/\(title)", feedID: feed, title: title, link: nil,
              published: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60), author: nil, text: "",
              severity: severity, matches: [], kind: kind, firstSeen: Date(), read: read)
    }

    func testVersionsFromRealReleaseTitles() {
        func v(_ t: String) -> SoftwareVersion? { SoftwareVersion.parse(title: t) }
        XCTAssertEqual(v("Bitcoin Core 29.5")?.numbers, [29, 5])
        XCTAssertEqual(v("v32.0: Bitcoin Core 32.0 final")?.numbers, [32, 0])
        XCTAssertEqual(v("lnd v0.21.6-beta")?.numbers, [0, 21, 6])
        XCTAssertEqual(v("lnd v0.21.6-beta")?.prerelease, false)
        XCTAssertEqual(v("lnd v0.21.0-beta.rc1")?.prerelease, true)
        XCTAssertEqual(v("v2.4.6-rc4")?.prerelease, true)
        XCTAssertEqual(v("1.0.39-beta2")?.prerelease, true)
        XCTAssertEqual(v("v3.4.0-alpha1: Merge pull request #6575")?.prerelease, true)
        XCTAssertEqual(v("v26.06.10 Quantum-Resistant Lightning Channel VII")?.numbers, [26, 6, 10])
        XCTAssertEqual(v("actor/v0.0.8: Merge pull request #11465")?.track, "actor")
        XCTAssertEqual(v("core/v2.13.0")?.track, "core")
        XCTAssertEqual(v("rust/trezor-thp/v0.1.1: feat(core/kernel)")?.track, "rust/trezor-thp")
        XCTAssertEqual(v("2026-09-30T2026-v5.6.3")?.numbers, [5, 6, 3])
        XCTAssertEqual(v("2026-09-30T2026-v5.6.3")?.track, "")
        XCTAssertEqual(v("2026-09-30T2025-v1.5.3Q")?.track, "Q")
        XCTAssertNil(v("Merge pull request #12"))
        XCTAssertEqual(SoftwareVersion.parse(typed: "29")?.numbers, [29])
        XCTAssertEqual(SoftwareVersion.parse(typed: " v29.4 ")?.numbers, [29, 4])
        XCTAssertNil(SoftwareVersion.parse(typed: "latest"))
        XCTAssertTrue(SoftwareVersion(numbers: [29, 4]) < SoftwareVersion(numbers: [29, 10]))
        XCTAssertTrue(SoftwareVersion(numbers: [2, 4, 6], prerelease: true) < SoftwareVersion(numbers: [2, 4, 6]))
        XCTAssertTrue(SoftwareVersion(numbers: [32]).sameRelease(as: SoftwareVersion(numbers: [32, 0])))
    }

    /// Bitcoin Core published 32.1, 31.2, 30.4 and 29.5 in that order within
    /// minutes; the latest is 32.1, not the last one published.
    func testLatestIsHighestVersionNotLastPublished() {
        let core = UUID()
        let entries = [entry("Bitcoin Core 29.5", feed: core, .critical, minutesAgo: 0),
                       entry("Bitcoin Core 30.4", feed: core, .critical, minutesAgo: 1),
                       entry("Bitcoin Core 31.2", feed: core, .critical, minutesAgo: 2),
                       entry("Bitcoin Core 32.1", feed: core, .critical, minutesAgo: 3),
                       entry("v32.0: Bitcoin Core 32.0 final", feed: core, minutesAgo: 9000, kind: nil),
                       entry("Bitcoin Core 32.0", feed: core, minutesAgo: 9001),
                       entry("v33.0rc1", feed: core, minutesAgo: 0)]
        let unset = SoftwareStatus(feedID: core, running: nil, entries: entries, showSeverity: true)
        XCTAssertEqual(unset.latest?.version.numbers, [32, 1])
        XCTAssertEqual(unset.known.map(\.numbers), [[32, 1], [32, 0], [31, 2], [30, 4], [29, 5]])
        XCTAssertEqual(unset.level, .security)   // no version: New critical releases

        let on294 = SoftwareStatus(feedID: core, running: "29.4", entries: entries, showSeverity: true)
        XCTAssertEqual(on294.update?.numbers, [29, 5])
        XCTAssertEqual(on294.newer.count, 5)
        XCTAssertEqual(on294.level, .security)
        XCTAssertEqual(SoftwareStatus(feedID: core, running: "29.4", entries: entries, showSeverity: false).level, .updates)

        let on295 = SoftwareStatus(feedID: core, running: "29.5", entries: entries, showSeverity: false)
        XCTAssertNil(on295.update)
        XCTAssertEqual(on295.level, .upgrade)   // only newer series remain

        let on321 = SoftwareStatus(feedID: core, running: "v32.1", entries: entries, showSeverity: true)
        XCTAssertEqual(on321.level, .upToDate)  // read state no longer matters, and rc1 is ignored
        XCTAssertTrue(SoftwareStatus(feedID: core, running: "newest", entries: entries, showSeverity: true).runningInvalid)
    }

    func testTrackedFirmwareComparesWithinItsTrack() {
        let trezor = UUID()
        let entries = [entry("core/v2.13.0", feed: trezor, minutesAgo: 0, kind: .tagOnly),
                       entry("legacy/v1.14.2", feed: trezor, minutesAgo: 1, kind: .tagOnly),
                       entry("core/v2.12.5", feed: trezor, minutesAgo: 60000, kind: .tagOnly)]
        let s = SoftwareStatus(feedID: trezor, running: "2.12.5", entries: entries, showSeverity: false)
        XCTAssertEqual(s.running?.track, "core")
        XCTAssertEqual(s.latest?.version.numbers, [2, 13, 0])
        XCTAssertEqual(s.level, .updates)
        XCTAssertEqual(SoftwareStatus(feedID: trezor, running: "legacy/v1.14.2", entries: entries, showSeverity: false).level, .upToDate)
    }

    func testServerHealthAndVersionStorage() {
        let core = UUID(), lnd = UUID()
        var server = Server(name: "node", address: "", feedIDs: [core, lnd])
        server.setVersion(" 29.4 ", for: core)
        server.setVersion("1.0", for: UUID())       // not installed: ignored
        XCTAssertEqual(server.versions, [core.uuidString: "29.4"])
        let entries = [entry("Bitcoin Core 29.5", feed: core, .critical), entry("lnd v0.21.6-beta", feed: lnd, read: true)]

        XCTAssertEqual(ServerHealth(server, entries: entries, showSeverity: true).level, .security)
        let hidden = ServerHealth(server, entries: entries, showSeverity: false)
        XCTAssertEqual(hidden.level, .updates)
        XCTAssertEqual(hidden.updateCount, 1)
        XCTAssertEqual(hidden.securityCount, 0)
        XCTAssertEqual(ServerHealth(Server(name: "e", address: ""), entries: entries, showSeverity: true).level, .empty)

        server.setVersion("", for: core)
        XCTAssertTrue(server.versions.isEmpty)
        server.setVersion("29.4", for: core)
        server.uninstall([core])
        XCTAssertTrue(server.versions.isEmpty)
        server.install([core]); server.setVersion("29.4", for: core)
        XCTAssertTrue(server.prune(keeping: [lnd]))
        XCTAssertTrue(server.versions.isEmpty)
    }

    func testColdcardModelsAndNewsFeeds() {
        let cc = UUID()
        let entries = [entry("2026-08-31T1606-v6.6.1QX", feed: cc, kind: .tagOnly),
                       entry("2026-09-30T2026-v5.6.3", feed: cc, minutesAgo: 1, kind: .tagOnly),
                       entry("2026-09-30T2025-v1.5.3Q", feed: cc, minutesAgo: 2, kind: .tagOnly)]
        XCTAssertEqual(SoftwareStatus(feedID: cc, running: nil, entries: entries, showSeverity: false).latest?.version.numbers, [5, 6, 3])
        let q = SoftwareStatus(feedID: cc, running: "1.5.2Q", entries: entries, showSeverity: false)
        XCTAssertEqual(q.update?.numbers, [1, 5, 3])

        let blog = UUID()
        let posts = [entry("Security Advisory: Update BTCPay Server to 2.4.2 Immediately", feed: blog, .critical, kind: nil)]
        let news = SoftwareStatus(feedID: blog, running: "2.4.1", entries: posts, showSeverity: true, tracksVersions: false)
        XCTAssertNil(news.latest)
        XCTAssertNil(news.running)
        XCTAssertEqual(news.level, .security)   // New critical post
        XCTAssertFalse(Feed(name: "b", url: URL(string: "https://blog.btcpayserver.org/rss.xml")!).tracksVersions)
        XCTAssertTrue(Feed(name: "g", url: URL(string: "https://gitlab.com/ark-bitcoin/bark/-/releases.atom")!).tracksVersions)
        XCTAssertTrue(Feed(name: "h", url: URL(string: "https://github.com/bitcoin/bitcoin/releases.atom")!).tracksVersions)
    }
}
