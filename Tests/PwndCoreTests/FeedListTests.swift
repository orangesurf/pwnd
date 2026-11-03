import XCTest
@testable import PwndCore

final class FeedListTests: XCTestCase {
    let lnd = URL(string: "https://github.com/lightningnetwork/lnd/releases.atom")!
    let core = URL(string: "https://github.com/bitcoin/bitcoin/releases.atom")!
    let blog = URL(string: "https://blog.btcpayserver.org/rss.xml")!

    func sample() -> FeedList.State {
        let g = FeedGroup(name: "Lightning & Co")
        return .init(groups: [g], order: [], feeds: [Feed(name: "lightningnetwork/lnd", url: lnd, groupID: g.id),
                                                      Feed(name: "bitcoin/bitcoin", url: core)])
    }

    func testOPMLRoundTripKeepsGroupsOrderAndEscaping() throws {
        let s = sample()
        let opml = FeedList(order: s.order, groups: s.groups, feeds: s.feeds).opml()
        XCTAssertTrue(opml.contains("Lightning &amp; Co"))
        XCTAssertTrue(opml.contains(#"htmlUrl="https://github.com/lightningnetwork/lnd/releases""#))
        let back = try XCTUnwrap(FeedList.parse(opml))
        XCTAssertEqual(back.entries, [
            .group(name: "Lightning & Co", feeds: [.init(name: "lightningnetwork/lnd", url: lnd)]),
            .feed(.init(name: "bitcoin/bitcoin", url: core)),
        ])
    }

    func testPlainLinesAndOtherReadersOPML() throws {
        let lines = try XCTUnwrap(FeedList.parse("# my list\nbitcoin/bitcoin\n\nhttps://blog.btcpayserver.org/rss.xml\nnot a feed\n"))
        XCTAssertEqual(lines.allFeeds.map(\.url), [core, blog])

        // Nested folders, as some readers export them, flatten into the top group.
        let nested = """
        <opml version="1.0"><body><outline text="Bitcoin"><outline text="Nodes">
        <outline type="rss" text="Core" xmlUrl="\(core.absoluteString)"/></outline></outline>
        <outline type="rss" text="Blog" xmlUrl="\(blog.absoluteString)"/></body></opml>
        """
        let n = try XCTUnwrap(FeedList.parse(nested))
        XCTAssertEqual(n.entries, [.group(name: "Bitcoin", feeds: [.init(name: "Core", url: core)]), .feed(.init(name: "Blog", url: blog))])
        XCTAssertNil(FeedList.parse("hello world"))
        XCTAssertNil(FeedList.parse("<opml><body></body></opml>"))
    }

    func testAddPutsOnlyMissingFeedsInImportedGroup() {
        let s = sample()
        let list = FeedList(entries: [.feed(.init(name: "lnd", url: lnd)), .feed(.init(name: "blog", url: blog))])
        let out = list.add(to: s)
        XCTAssertEqual(out.feeds.count, 3)
        let imported = out.groups.first { $0.name == "Imported" }
        XCTAssertEqual(out.feeds.filter { $0.groupID == imported?.id }.map(\.url), [blog])
        XCTAssertEqual(out.order.last, imported?.id)
        // A second import gets its own section; nothing new means no change.
        XCTAssertEqual(FeedList(entries: [.feed(.init(name: "x", url: URL(string: "https://e.example/f.xml")!))]).add(to: out)
                        .groups.last?.name, "Imported 2")
        XCTAssertEqual(list.add(to: out), out)
    }

    func testReplaceKeepsExistingFeedStateAndReportsRemoved() {
        var s = sample()
        s.feeds[0].etag = "kept"
        let list = FeedList(entries: [.group(name: "LN", feeds: [.init(name: "lnd", url: lnd)]), .feed(.init(name: "blog", url: blog))])
        let (out, removed) = list.replace(s)
        XCTAssertEqual(out.groups.map(\.name), ["LN"])
        XCTAssertEqual(out.feeds.first { $0.url == lnd }?.id, s.feeds[0].id)
        XCTAssertEqual(out.feeds.first { $0.url == lnd }?.etag, "kept")
        XCTAssertEqual(removed, [s.feeds[1].id])
        XCTAssertEqual(SidebarLayout.topLevel(order: out.order, groups: out.groups, feeds: out.feeds).count, 2)
    }
}
