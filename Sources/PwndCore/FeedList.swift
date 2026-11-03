import Foundation

/// A shareable list of feeds and groups, written and read as OPML 2.0, the
/// usual format for moving subscriptions between feed readers. A group is an
/// outline holding feed outlines; a feed is an outline with `xmlUrl`.
public struct FeedList: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var name: String
        public var url: URL
    }

    public enum Entry: Equatable, Sendable {
        case feed(Item)
        case group(name: String, feeds: [Item])
    }

    /// Top-level entries in order.
    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public var allFeeds: [Item] {
        entries.flatMap { e -> [Item] in
            switch e {
            case .feed(let f): return [f]
            case .group(_, let feeds): return feeds
            }
        }
    }

    // MARK: - Export

    /// The current sidebar, in order.
    public init(order: [UUID], groups: [FeedGroup], feeds: [Feed]) {
        entries = SidebarLayout.topLevel(order: order, groups: groups, feeds: feeds).compactMap { item in
            switch item {
            case .feed(let id):
                return feeds.first { $0.id == id }.map { .feed(Item(name: $0.name, url: $0.url)) }
            case .group(let id):
                guard let g = groups.first(where: { $0.id == id }) else { return nil }
                return .group(name: g.name, feeds: feeds.filter { $0.groupID == id }.map { Item(name: $0.name, url: $0.url) })
            }
        }
    }

    public func opml(title: String = "pwnd feeds") -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func feedLine(_ f: Item, indent: String) -> String {
            var attrs = "type=\"rss\" text=\"\(esc(f.name))\" title=\"\(esc(f.name))\" xmlUrl=\"\(esc(f.url.absoluteString))\""
            if let repo = GitHubRepo(feedURL: f.url) {
                attrs += " htmlUrl=\"https://github.com/\(esc(repo.owner))/\(esc(repo.name))/releases\""
            }
            return "\(indent)<outline \(attrs)/>"
        }
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head><title>\(esc(title))</title></head>",
            "  <body>",
        ]
        for e in entries {
            switch e {
            case .feed(let f):
                lines.append(feedLine(f, indent: "    "))
            case .group(let name, let feeds):
                lines.append("    <outline text=\"\(esc(name))\" title=\"\(esc(name))\">")
                lines += feeds.map { feedLine($0, indent: "      ") }
                lines.append("    </outline>")
            }
        }
        lines += ["  </body>", "</opml>", ""]
        return lines.joined(separator: "\n")
    }

    // MARK: - Import

    /// Reads OPML, or failing that one feed per line (`owner/repo` or a URL;
    /// blank lines and `#` comments ignored). Nil when nothing usable is found.
    /// Groups nested more than one level deep are flattened into their
    /// top-level group.
    public static func parse(_ text: String) -> FeedList? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            let d = OPMLDelegate()
            let parser = XMLParser(data: Data(trimmed.utf8))
            parser.delegate = d
            guard parser.parse() else { return nil }
            let list = FeedList(entries: d.entries)
            return list.allFeeds.isEmpty ? nil : list
        }
        let items = trimmed.split(whereSeparator: \.isNewline).compactMap { line -> Entry? in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#"), let (name, url) = FeedInput.resolve(l) else { return nil }
            return .feed(Item(name: name, url: url))
        }
        return items.isEmpty ? nil : FeedList(entries: items)
    }

    private final class OPMLDelegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var depth = 0
        /// The open top-level group, and the depth its outline started at.
        private var group: (name: String, depth: Int, feeds: [Item])?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name == "outline" else { return }
            depth += 1
            let label = attributes["title"] ?? attributes["text"] ?? ""
            if let raw = attributes["xmlUrl"], let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                let item = Item(name: label.isEmpty ? (url.host ?? raw) : label, url: url)
                if group != nil { group!.feeds.append(item) } else { entries.append(.feed(item)) }
            } else if group == nil {
                group = (label.isEmpty ? "Imported" : label, depth, [])
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "outline" else { return }
            if let g = group, g.depth == depth {
                entries.append(.group(name: g.name, feeds: g.feeds))
                group = nil
            }
            depth -= 1
        }
    }

    // MARK: - Applying

    public struct State: Equatable {
        public var groups: [FeedGroup]
        public var order: [UUID]
        public var feeds: [Feed]

        public init(groups: [FeedGroup], order: [UUID], feeds: [Feed]) {
            self.groups = groups
            self.order = order
            self.feeds = feeds
        }
    }

    /// Feeds in this list whose URL is not already subscribed.
    public func missing(from feeds: [Feed]) -> [Item] {
        let have = Set(feeds.map { $0.url.absoluteString.lowercased() })
        var seen = Set<String>()
        return allFeeds.filter {
            let key = $0.url.absoluteString.lowercased()
            return !have.contains(key) && seen.insert(key).inserted
        }
    }

    /// Adds the feeds not already subscribed, in a new group named "Imported"
    /// (or "Imported 2", …) at the end of the sidebar. Unchanged if none.
    public func add(to s: State) -> State {
        let new = missing(from: s.feeds)
        guard !new.isEmpty else { return s }
        let names = Set(s.groups.map(\.name))
        var name = "Imported"
        var n = 2
        while names.contains(name) { name = "Imported \(n)"; n += 1 }
        let g = FeedGroup(name: name)
        var out = s
        out.order = SidebarLayout.topLevel(order: s.order, groups: s.groups, feeds: s.feeds).map(\.id) + [g.id]
        out.groups.append(g)
        out.feeds += new.map { Feed(name: $0.name, url: $0.url, groupID: g.id) }
        return out
    }

    /// Makes this list the subscription list. A feed already subscribed (same
    /// URL) keeps its ID and polling state, so its stored releases stay; the
    /// rest are removed, and the caller should drop their releases.
    public func replace(_ s: State) -> (state: State, removed: Set<UUID>) {
        var existing: [String: Feed] = [:]
        for f in s.feeds { existing[f.url.absoluteString.lowercased()] = existing[f.url.absoluteString.lowercased()] ?? f }
        var used = Set<String>()
        var groups: [FeedGroup] = []
        var order: [UUID] = []
        var feeds: [Feed] = []

        func take(_ item: Item, group: UUID?) -> Feed? {
            let key = item.url.absoluteString.lowercased()
            guard used.insert(key).inserted else { return nil }
            var f = existing[key] ?? Feed(name: item.name, url: item.url)
            f.name = item.name
            f.groupID = group
            return f
        }
        for e in entries {
            switch e {
            case .feed(let item):
                if let f = take(item, group: nil) { feeds.append(f); order.append(f.id) }
            case .group(let name, let items):
                let g = FeedGroup(name: name)
                groups.append(g)
                order.append(g.id)
                feeds += items.compactMap { take($0, group: g.id) }
            }
        }
        let kept = Set(feeds.map(\.id))
        let removed = Set(s.feeds.map(\.id)).subtracting(kept)
        return (State(groups: groups, order: order, feeds: feeds), removed)
    }
}
