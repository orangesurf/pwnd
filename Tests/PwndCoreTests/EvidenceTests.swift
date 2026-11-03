import XCTest
@testable import PwndCore

final class NegationAndDetailTests: XCTestCase {
    let c = Classifier(.defaults)

    func testNegatedSignalIsDropped() {
        XCTAssertEqual(c.classify(title: "Maintenance release", text: "This release has no security impact.").severity, .routine)
        XCTAssertEqual(c.classify(title: "Not a security fix", text: "").severity, .routine)
    }

    func testNegationNeverSuppressesCriticalKeywords() {
        XCTAssertEqual(c.classify(title: "1.2", text: "No security impact for most users; fixes CVE-2026-1234.").severity, .critical)
    }

    func testOtherSignalsStillCount() {
        // "security" is negated, "critical" is not: one signal in the body → important.
        XCTAssertEqual(c.classify(title: "1.2", text: "No security impact. Fixes a critical display bug.").severity, .important)
    }

    func testDetailsNameSourceAndSnippet() {
        let r = c.classify(title: "Security update", text: "Fixes CVE-2026-1 in the parser.", source: "feed text")
        let cve = r.details.first { $0.keyword.contains("CVE") }
        XCTAssertEqual(cve?.source, "feed text")
        XCTAssertEqual(cve?.snippet.contains("CVE-2026-1"), true)
        XCTAssertEqual(r.details.first { $0.keyword == "security" }?.source, "title")
    }
}

final class AssessorTests: XCTestCase {
    let classifier = Classifier(.defaults)

    func entry(_ text: String = "Bitcoin Core 32.1 is now available from: https://bitcoincore.org/bin/",
               links: [String] = ["https://bitcoincore.org/bin/"]) -> Entry {
        Entry(id: "f/1", feedID: UUID(), title: "Bitcoin Core 32.1", link: nil, published: nil, author: nil,
              text: text, links: links, severity: .routine, matches: [], firstSeen: Date(), read: false)
    }

    func testLinkedNotesRaiseSparseRelease() {
        var e = entry()
        Assessor.assess(&e, classifier: classifier)
        XCTAssertEqual(e.severity, .routine)
        XCTAssertTrue(e.coverage.contains { $0.contains("short and mostly links") })

        e.evidence = [EvidenceItem(kind: .linkedNotes, source: "https://raw.githubusercontent.com/x", title: "notes.md",
                                   text: "Fixes CVE-2026-117349, a remote crash.", fetchedAt: Date())]
        e.evidenceState = .done
        Assessor.assess(&e, classifier: classifier)
        XCTAssertEqual(e.severity, .critical)
        XCTAssertEqual(e.baseline, .routine)
        XCTAssertEqual(e.details.first?.source, "linked notes")
        XCTAssertFalse(e.coverage.contains { $0.contains("short and mostly links") })
    }

    func testAdvisoryRating() {
        var e = entry("plain release", links: [])
        e.evidence = [EvidenceItem(kind: .advisory, source: "GHSA-aaaa-bbbb-cccc", title: "Onion bomb", text: "",
                                   rating: "high", fetchedAt: Date())]
        Assessor.assess(&e, classifier: classifier)
        XCTAssertEqual(e.severity, .critical)
        XCTAssertEqual(e.matches, ["GHSA-aaaa-bbbb-cccc (high)"])
        e.evidence[0].rating = "medium"
        Assessor.assess(&e, classifier: classifier)
        XCTAssertEqual(e.severity, .important)
    }

    func testTagOnlyCoverage() {
        var e = entry("Tree-SHA512: abc", links: [])
        e.kind = .tagOnly
        Assessor.assess(&e, classifier: classifier)
        XCTAssertTrue(e.coverage.first?.hasPrefix("Tag only") ?? false)
    }
}

final class AlertTests: XCTestCase {
    func entry(_ s: Severity, notified: Severity = .routine, seeded: Bool = false, read: Bool = false) -> Entry {
        Entry(id: "f/1", feedID: UUID(), title: "t", link: nil, published: nil, author: nil, text: "",
              severity: s, matches: [], notifiedSeverity: notified, seeded: seeded, firstSeen: Date(), read: read)
    }

    func testNewCriticalAlertsOnce() {
        var e = entry(.critical)
        XCTAssertTrue(Alerts.evaluate(&e, previous: nil, threshold: .critical, ignoreOld: true))
        XCTAssertFalse(Alerts.evaluate(&e, previous: .critical, threshold: .critical, ignoreOld: true))
        XCTAssertNil(e.escalatedFrom)
    }

    func testEscalationAlertsAndMarksUnread() {
        var e = entry(.critical, read: true)
        XCTAssertTrue(Alerts.evaluate(&e, previous: .routine, threshold: .critical, ignoreOld: true))
        XCTAssertEqual(e.escalatedFrom, .routine)
        XCTAssertFalse(e.read)
    }

    func testBelowThresholdWaits() {
        var e = entry(.important)
        XCTAssertFalse(Alerts.evaluate(&e, previous: .routine, threshold: .critical, ignoreOld: true))
        XCTAssertEqual(e.notifiedSeverity, .routine)      // so a later rise to critical still alerts
        e.severity = .critical
        XCTAssertTrue(Alerts.evaluate(&e, previous: .important, threshold: .critical, ignoreOld: true))
        XCTAssertEqual(e.escalatedFrom, .routine)
    }

    func testSeededHistoryQuietByDefaultButAlertsWhenAllowed() {
        var quiet = entry(.critical, seeded: true, read: true)
        XCTAssertFalse(Alerts.evaluate(&quiet, previous: .routine, threshold: .critical, ignoreOld: true))
        XCTAssertEqual(quiet.escalatedFrom, .routine)     // still marked in the list
        XCTAssertTrue(quiet.read)
        XCTAssertEqual(quiet.notifiedSeverity, .critical) // no replay if the setting changes later

        var loud = entry(.critical, seeded: true, read: true)
        XCTAssertTrue(Alerts.evaluate(&loud, previous: .routine, threshold: .critical, ignoreOld: false))
    }
}

final class MergeUpdateTests: XCTestCase {
    let classifier = Classifier(.defaults)
    let feed = Feed(name: "bitcoin/bitcoin", url: URL(string: "https://github.com/bitcoin/bitcoin/releases.atom")!)

    func parsed(_ text: String, links: [String] = []) -> ParsedEntry {
        ParsedEntry(key: "tag:v32.1", title: "Bitcoin Core 32.1", link: URL(string: "https://github.com/bitcoin/bitcoin/releases/tag/v32.1"),
                    published: Date(timeIntervalSince1970: 1_800_000_000), author: nil, text: text, links: links)
    }

    func testTagBecomingReleaseIsAnUpdate() {
        let seeded = Merge.apply([parsed("Tree-SHA512: abc")], feed: feed, into: [], classifier: classifier, seeding: false)
        XCTAssertEqual(seeded.new.count, 1)
        let r = Merge.apply([parsed("Fixes CVE-2026-1. Upgrade.")], feed: feed, into: seeded.entries,
                            classifier: classifier, seeding: false)
        XCTAssertTrue(r.new.isEmpty)
        XCTAssertEqual(r.updated.count, 1)
        XCTAssertEqual(r.updated.first?.previous, .routine)
        XCTAssertEqual(r.entries.first?.severity, .critical)
        XCTAssertEqual(r.entries.first?.revision, 1)
    }

    func testLegacyEntriesGainLinksQuietly() {
        var legacy = Merge.apply([parsed("Now available")], feed: feed, into: [], classifier: classifier, seeding: true).entries
        legacy[0].links = []
        let r = Merge.apply([parsed("Now available", links: ["https://bitcoincore.org/bin/"])], feed: feed, into: legacy,
                            classifier: classifier, seeding: false)
        XCTAssertTrue(r.updated.isEmpty)
        XCTAssertEqual(r.entries.first?.links, ["https://bitcoincore.org/bin/"])
        XCTAssertEqual(r.entries.first?.revision, 0)
    }

    func testSeedingRecordsSeverityAsSeen() {
        let r = Merge.apply([parsed("Fixes CVE-2026-1")], feed: feed, into: [], classifier: classifier, seeding: true)
        XCTAssertEqual(r.entries.first?.notifiedSeverity, .critical)
        XCTAssertEqual(r.entries.first?.seeded, true)
    }

    func testVersion1EntryDecodesAsSeededHistory() throws {
        let json = """
        {"id":"x/1","feedID":"\(UUID().uuidString)","title":"t","text":"","severity":2,"matches":["security"],
         "firstSeen":"2026-11-03T15:00:00Z","read":true}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let e = try d.decode(Entry.self, from: Data(json.utf8))
        XCTAssertTrue(e.seeded)
        XCTAssertEqual(e.notifiedSeverity, .critical)
        XCTAssertEqual(e.baseline, .critical)
        XCTAssertEqual(e.evidenceState, .notRequested)
    }
}

final class GitHubTests: XCTestCase {
    let repo = GitHubRepo(feedURL: URL(string: "https://github.com/bitcoin/bitcoin/releases.atom")!)!

    func testRepoAndTag() {
        XCTAssertEqual(repo, GitHubRepo(owner: "bitcoin", name: "bitcoin"))
        XCTAssertNil(GitHubRepo(feedURL: URL(string: "https://blog.btcpayserver.org/rss.xml")!))
        XCTAssertEqual(repo.tag(fromReleaseLink: URL(string: "https://github.com/bitcoin/bitcoin/releases/tag/v32.1")), "v32.1")
        XCTAssertEqual(repo.tag(fromReleaseLink: URL(string: "https://github.com/bitcoin/bitcoin/releases/tag/core/v1")), "core/v1")
        XCTAssertNil(repo.tag(fromReleaseLink: URL(string: "https://github.com/other/repo/releases/tag/v1")))
    }

    func testNotesFileOnlyFromSameRepo() {
        let links = [
            "https://bitcoincore.org/bin/bitcoin-core-32.1/",
            "https://github.com/evil/bitcoin/blob/master/doc/release-notes/release-notes-32.1.md",
            "https://github.com/bitcoin/bitcoin/blob/master/doc/release-notes/release-notes-32.1.md",
        ]
        XCTAssertEqual(repo.notesFile(in: links)?.absoluteString,
                       "https://raw.githubusercontent.com/bitcoin/bitcoin/master/doc/release-notes/release-notes-32.1.md")
        XCTAssertNil(repo.notesFile(in: ["https://github.com/bitcoin/bitcoin/blob/master/src/main.cpp"]))
    }

    func testAdvisoryMatching() {
        let a = Advisory(ghsa: "GHSA-9gxx-58q6-42p7", cve: "CVE-2024-38359", severity: "high", summary: "LND Onion Bomb",
                         url: "https://github.com/advisories/GHSA-9gxx-58q6-42p7", patched: ["0.17.0-beta"], vulnerable: ["< 0.17.0-beta"])
        XCTAssertTrue(a.applies(toTag: "v0.17.0-beta", text: ""))
        XCTAssertFalse(a.applies(toTag: "v0.18.0-beta", text: ""))
        XCTAssertTrue(a.applies(toTag: "v0.18.0-beta", text: "Includes the fix for CVE-2024-38359."))
        let multi = Advisory(ghsa: "GHSA-x", cve: nil, severity: "medium", summary: "", url: "", patched: ["1.2.3, 2.0.1"], vulnerable: [])
        XCTAssertTrue(multi.applies(toTag: "v2.0.1", text: ""))
        XCTAssertEqual(multi.level, .important)
    }

    func testBudget() {
        var b = RequestBudget()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<RequestBudget.limit { b.record(at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(b.available(at: t0.addingTimeInterval(60)), 0)
        XCTAssertEqual(b.available(at: t0.addingTimeInterval(3600.5)), 1)  // only the first stamp has aged out
        b.observe(status: 200, headers: ["x-ratelimit-remaining": "2", "x-ratelimit-reset": "\(Int(t0.timeIntervalSince1970) + 900)"], at: t0)
        XCTAssertEqual(b.available(at: t0.addingTimeInterval(4000)), RequestBudget.limit)
        var c = RequestBudget()
        c.observe(status: 200, headers: ["X-RateLimit-Remaining": "1", "X-RateLimit-Reset": "\(Int(t0.timeIntervalSince1970) + 900)"], at: t0)
        XCTAssertEqual(c.available(at: t0.addingTimeInterval(899)), 0)
        XCTAssertEqual(c.available(at: t0.addingTimeInterval(901)), RequestBudget.limit)
    }

    func testTokenLimitAndResumeTime() {
        var b = RequestBudget()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<RequestBudget.limit { b.record(at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(b.available(at: t0.addingTimeInterval(60)), 0)
        XCTAssertEqual(b.available(at: t0.addingTimeInterval(60), limit: RequestBudget.tokenLimit),
                       RequestBudget.tokenLimit - RequestBudget.limit)
        XCTAssertEqual(b.resumesAt(now: t0.addingTimeInterval(60)), t0.addingTimeInterval(3600))
        XCTAssertNil(b.resumesAt(now: t0.addingTimeInterval(60), limit: RequestBudget.tokenLimit))
        b.blockedUntil = t0.addingTimeInterval(120)
        b.blockedWithToken = true
        XCTAssertEqual(b.resumesAt(now: t0.addingTimeInterval(60), limit: RequestBudget.tokenLimit), t0.addingTimeInterval(120))
    }

    func testAnonymousPauseDoesNotBindToken() {
        var b = RequestBudget()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        b.observe(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(Int(t0.timeIntervalSince1970) + 900)"], at: t0)
        XCTAssertEqual(b.available(at: t0.addingTimeInterval(1)), 0)
        XCTAssertEqual(b.available(at: t0.addingTimeInterval(1), limit: RequestBudget.tokenLimit), RequestBudget.tokenLimit)
        b.observe(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(Int(t0.timeIntervalSince1970) + 1800)"],
                  at: t0, withToken: true)
        XCTAssertEqual(b.available(at: t0.addingTimeInterval(1), limit: RequestBudget.tokenLimit), 0)
    }

    func testFeedLinksExtracted() {
        XCTAssertEqual(HTMLText.links(#"<a href="https://a.example/x?a=1&amp;b=2">x</a> <a href='/rel'>r</a> <a href="https://a.example/x?a=1&amp;b=2">dup</a>"#),
                       ["https://a.example/x?a=1&b=2"])
    }
}
