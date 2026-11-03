import XCTest
@testable import PwndCore

final class LayoutTests: XCTestCase {
    func make() -> (FeedGroup, [Feed]) {
        let g = FeedGroup(name: "Lightning")
        let url = URL(string: "https://github.com/x/y/releases.atom")!
        return (g, [Feed(name: "lnd", url: url, groupID: g.id), Feed(name: "cln", url: url, groupID: g.id),
                    Feed(name: "core", url: url), Feed(name: "btcpay", url: url)])
    }

    func testDefaultOrderIsGroupsThenFeeds() {
        let (g, feeds) = make()
        XCTAssertEqual(SidebarLayout.topLevel(order: [], groups: [g], feeds: feeds), [.group(g.id), .feed(feeds[2].id), .feed(feeds[3].id)])
    }

    func testReorderTopLevelFeedBeforeGroup() {
        let (g, feeds) = make()
        let r = SidebarLayout.move(feed: feeds[3].id, to: .top(before: g.id), order: [], groups: [g], feeds: feeds)
        XCTAssertEqual(SidebarLayout.topLevel(order: r.order, groups: [g], feeds: r.feeds),
                       [.feed(feeds[3].id), .group(g.id), .feed(feeds[2].id)])
    }

    func testMoveIntoGroupAtPositionAndOutAgain() {
        let (g, feeds) = make()
        let into = SidebarLayout.move(feed: feeds[2].id, to: .group(g.id, before: feeds[1].id), order: [], groups: [g], feeds: feeds)
        XCTAssertEqual(into.feeds.filter { $0.groupID == g.id }.map(\.name), ["lnd", "core", "cln"])
        XCTAssertEqual(SidebarLayout.topLevel(order: into.order, groups: [g], feeds: into.feeds), [.group(g.id), .feed(feeds[3].id)])

        let out = SidebarLayout.move(feed: feeds[0].id, to: .top(before: nil), order: into.order, groups: [g], feeds: into.feeds)
        XCTAssertNil(out.feeds.first { $0.name == "lnd" }?.groupID)
        XCTAssertEqual(SidebarLayout.topLevel(order: out.order, groups: [g], feeds: out.feeds).last, .feed(feeds[0].id))
    }

    func testReorderWithinGroupToEnd() {
        let (g, feeds) = make()
        let r = SidebarLayout.move(feed: feeds[0].id, to: .group(g.id, before: nil), order: [], groups: [g], feeds: feeds)
        XCTAssertEqual(r.feeds.filter { $0.groupID == g.id }.map(\.name), ["cln", "lnd"])
    }

    func testMoveGroup() {
        let (g, feeds) = make()
        let order = SidebarLayout.move(group: g.id, before: nil, order: [], groups: [g], feeds: feeds)
        XCTAssertEqual(order, [feeds[2].id, feeds[3].id, g.id])
    }
}
