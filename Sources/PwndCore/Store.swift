import Foundation

/// User settings, persisted with the feed state.
public struct AppSettings: Codable, Equatable, Sendable {
    public var pollMinutes: Int
    public var notifyImportant: Bool
    public var keywords: KeywordConfig
    /// Do not alert when evidence found later (an advisory published months
    /// after the fix, say) raises a release that existed before the feed was
    /// subscribed. The entry still shows the change. Each feed can override it.
    public var ignoreOldAlerts: Bool
    /// Show the Critical / Important tags, their column, the severity filter,
    /// the "why" box and the highlighted matches in the notes. Off by default. Display only: releases are still scored and
    /// critical ones still notify either way.
    public var showSeverity: Bool

    public init(pollMinutes: Int, notifyImportant: Bool, keywords: KeywordConfig, ignoreOldAlerts: Bool = true,
                showSeverity: Bool = false) {
        self.pollMinutes = pollMinutes
        self.notifyImportant = notifyImportant
        self.keywords = keywords
        self.ignoreOldAlerts = ignoreOldAlerts
        self.showSeverity = showSeverity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollMinutes = try c.decodeIfPresent(Int.self, forKey: .pollMinutes) ?? 15
        notifyImportant = try c.decodeIfPresent(Bool.self, forKey: .notifyImportant) ?? false
        keywords = try c.decodeIfPresent(KeywordConfig.self, forKey: .keywords) ?? .defaults
        ignoreOldAlerts = try c.decodeIfPresent(Bool.self, forKey: .ignoreOldAlerts) ?? true
        showSeverity = try c.decodeIfPresent(Bool.self, forKey: .showSeverity) ?? false
    }

    public static let defaults = AppSettings(pollMinutes: 15, notifyImportant: false, keywords: .defaults)
}

/// Everything written to disk, as one JSON document.
public struct Snapshot: Codable, Sendable {
    /// 3: entries start in New; everything moved to New once on upgrade.
    public static let currentVersion = 3
    public var version = Snapshot.currentVersion
    public var groups: [FeedGroup]
    /// Sidebar top-level order (group and ungrouped-feed IDs); see `SidebarLayout`.
    public var order: [UUID]
    public var feeds: [Feed]
    public var entries: [Entry]
    public var settings: AppSettings
    public var budget: RequestBudget
    /// Machines and the software (feeds) installed on them.
    public var servers: [Server]

    public init(groups: [FeedGroup] = [], order: [UUID] = [], feeds: [Feed], entries: [Entry], settings: AppSettings,
                budget: RequestBudget = RequestBudget(), servers: [Server] = []) {
        self.groups = groups
        self.order = order
        self.feeds = feeds
        self.entries = entries
        self.settings = settings
        self.budget = budget
        self.servers = servers
    }

    // Written by hand so state saved before groups existed still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        groups = try c.decodeIfPresent([FeedGroup].self, forKey: .groups) ?? []
        order = try c.decodeIfPresent([UUID].self, forKey: .order) ?? []
        feeds = try c.decode([Feed].self, forKey: .feeds)
        entries = try c.decode([Entry].self, forKey: .entries)
        settings = try c.decode(AppSettings.self, forKey: .settings)
        budget = try c.decodeIfPresent(RequestBudget.self, forKey: .budget) ?? RequestBudget()
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
    }
}

public enum DefaultFeeds {
    /// Bitcoin projects whose releases have carried security fixes, filed by
    /// kind. GitHub release feeds unless they are a URL. An empty group name
    /// leaves the feed ungrouped.
    public static let inputs: [(group: String, feeds: [String])] = [
        ("", [
            "bitcoin/bitcoin",
        ]),
        ("mempool", [
            "mempool/mempool",
            "mempool/electrs",
        ]),
        ("Lightning", [
            "lightningnetwork/lnd",
            "ElementsProject/lightning",
            "ACINQ/phoenixd",
        ]),
        ("Wallets", [
            "sparrowwallet/sparrow",
            "bluewallet/bluewallet",
        ]),
        ("Hardware", [
            "Coldcard/firmware",
            "Blockstream/Jade",
            "trezor/trezor-firmware",
            "Foundation-Devices/passport-firmware",
        ]),
        ("BTCPayServer", [
            "https://blog.btcpayserver.org/rss.xml",
            "btcpayserver/btcpayserver",
        ]),
    ]

    /// The groups, feeds and sidebar order, in the order `inputs` lists them.
    public static func make() -> (groups: [FeedGroup], feeds: [Feed], order: [UUID]) {
        var groups: [FeedGroup] = []
        var feeds: [Feed] = []
        var order: [UUID] = []
        for (name, list) in inputs {
            var gid: UUID?
            if !name.isEmpty {
                let g = FeedGroup(name: name)
                groups.append(g)
                order.append(g.id)
                gid = g.id
            }
            let made = list.compactMap(FeedInput.resolve).map { Feed(name: $0.name, url: $0.url, groupID: gid) }
            if gid == nil { order += made.map(\.id) }
            feeds += made
        }
        return (groups, feeds, order)
    }
}

/// What a poll found worth telling the user about.
public struct NewArrival: Sendable {
    public var entry: Entry
    public var feedName: String
}

/// Merges fetched entries into stored state. Pure, so it can be tested
/// without the network.
public enum Merge {
    public static let maxEntriesPerFeed = 200
    /// The text cap before version 2 of the state file.
    static let legacyTextLength = 6000

    public struct Result {
        public var entries: [Entry]
        /// Entries new to us, already scored. Empty when seeding.
        public var new: [Entry]
        /// Known entries whose feed content changed, with their severity
        /// before the change. A tag that became a release lands here.
        public var updated: [(id: String, previous: Severity)]
    }

    /// On a feed's first successful fetch (`seeding`) entries are stored as
    /// seeded history, in New, with their current severity counted as already
    /// alerted on, and nothing is reported as a new arrival.
    public static func apply(_ parsed: [ParsedEntry], feed: Feed, into entries: [Entry],
                             classifier: Classifier, seeding: Bool, now: Date = Date()) -> Result {
        var result = entries
        var index: [String: Int] = [:]
        for (i, e) in result.enumerated() where e.feedID == feed.id { index[e.id] = i }
        var fresh: [Entry] = []
        var updated: [(id: String, previous: Severity)] = []

        for p in parsed {
            let id = "\(feed.id.uuidString)/\(p.key)"
            let text = String(p.text.prefix(FeedParser.maxTextLength))
            if let i = index[id] {
                var e = result[i]
                // Entries saved by earlier versions have no links and text cut
                // at 6,000 characters. Fill those in quietly; treating them as
                // edits would refetch evidence for the whole history.
                if e.title == p.title, e.link == p.link,
                   e.text == text || (e.text.count >= legacyTextLength && text.hasPrefix(e.text)),
                   e.links.isEmpty || e.links == p.links {
                    if e.links != p.links || e.text != text {
                        e.links = p.links
                        e.text = text
                        result[i] = e
                    }
                    continue
                }
                let previous = e.severity
                e.title = p.title
                e.text = text
                e.links = p.links
                e.link = p.link
                e.published = p.published ?? e.published
                e.revision += 1
                // The body changed, so notes fetched for the old body are stale.
                // Advisories describe the release, not its text, and stay.
                e.evidence.removeAll { $0.kind != .advisory }
                e.kind = nil
                Assessor.assess(&e, classifier: classifier)
                result[i] = e
                updated.append((id, previous))
                continue
            }
            var e = Entry(id: id, feedID: feed.id, title: p.title, link: p.link, published: p.published,
                          author: p.author, text: text, links: p.links, severity: .routine, matches: [],
                          seeded: seeding, firstSeen: now, read: false)
            Assessor.assess(&e, classifier: classifier)
            if seeding { e.notifiedSeverity = e.severity }
            fresh.append(e)
        }
        result.append(contentsOf: fresh)

        // Keep the newest N per feed so the state file stays small.
        let mine = result.filter { $0.feedID == feed.id }
        if mine.count > maxEntriesPerFeed {
            let keep = Set(mine.sorted(by: Entry.newestFirst).prefix(maxEntriesPerFeed).map(\.id))
            result.removeAll { $0.feedID == feed.id && !keep.contains($0.id) }
        }
        return Result(entries: result, new: seeding ? [] : fresh, updated: updated)
    }
}

extension Entry {
    public var sortDate: Date { published ?? firstSeen }

    public static func newestFirst(_ a: Entry, _ b: Entry) -> Bool { a.sortDate > b.sortDate }
}

/// Reads and writes the snapshot atomically.
public struct Persistence: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var standard: Persistence {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("pwnd", isDirectory: true)
        // Earlier builds used "Pwnd". On the usual case-insensitive volume that
        // is the same folder; on a case-sensitive one, move it across once.
        let old = base.appendingPathComponent("Pwnd", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        return Persistence(url: dir.appendingPathComponent("state.json"))
    }

    public enum LoadResult {
        case missing
        case loaded(Snapshot)
        /// The file exists but could not be read. It was moved aside to
        /// `movedTo` so the next save does not overwrite it.
        case unreadable(error: String, movedTo: URL?)
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return .loaded(try d.decode(Snapshot.self, from: data))
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = url.deletingLastPathComponent().appendingPathComponent("state.unreadable-\(stamp).json")
            let moved = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
            return .unreadable(error: String(describing: error), movedTo: moved ? aside : nil)
        }
    }

    public func save(_ s: Snapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(s).write(to: url, options: .atomic)
    }
}
