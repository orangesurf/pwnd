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
        let server = Server(name: "Home node", address: "192.168.1.20", notes: "rack", feedIDs: [feed.id])
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
}
