import Foundation

/// A machine the user runs some of the followed software on, e.g. a home
/// node at 192.168.1.20 with Bitcoin Core and lnd. Software is a list of feed
/// IDs, so a server's status comes from the releases of what it runs.
public struct Server: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// IPv4, IPv6 or a hostname, as typed (trimmed).
    public var address: String
    public var notes: String
    /// Installed software, in the order it was added.
    public var feedIDs: [UUID]
    /// The version each piece of software runs, as typed, keyed by feed ID
    /// string. Missing means not set.
    public var versions: [String: String]

    public init(name: String, address: String, notes: String = "", feedIDs: [UUID] = [], versions: [String: String] = [:]) {
        self.id = UUID()
        self.name = name
        self.address = address
        self.notes = notes
        self.feedIDs = feedIDs
        self.versions = versions
    }

    public func version(of feed: UUID) -> String? { versions[feed.uuidString] }

    /// Sets or, when blank, clears the running version of installed software.
    public mutating func setVersion(_ version: String?, for feed: UUID) {
        let v = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard feedIDs.contains(feed) else { return }
        versions[feed.uuidString] = v.isEmpty ? nil : v
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        feedIDs = try c.decodeIfPresent([UUID].self, forKey: .feedIDs) ?? []
        versions = try c.decodeIfPresent([String: String].self, forKey: .versions) ?? [:]
    }

    /// Adds software not already installed; returns true if anything changed.
    @discardableResult
    public mutating func install(_ ids: [UUID]) -> Bool {
        let before = feedIDs.count
        for id in ids where !feedIDs.contains(id) { feedIDs.append(id) }
        return feedIDs.count != before
    }

    public mutating func uninstall(_ ids: Set<UUID>) {
        feedIDs.removeAll { ids.contains($0) }
        for id in ids { versions[id.uuidString] = nil }
    }

    /// Drops software whose feed is no longer subscribed; returns true if anything changed.
    @discardableResult
    public mutating func prune(keeping known: Set<UUID>) -> Bool {
        let before = (feedIDs.count, versions.count)
        feedIDs.removeAll { !known.contains($0) }
        let kept = Set(feedIDs.map(\.uuidString))
        versions = versions.filter { kept.contains($0.key) }
        return (feedIDs.count, versions.count) != before
    }
}

/// Where a server stands: the most urgent status of its software.
public struct ServerHealth: Sendable {
    public enum Level: Equatable, Sendable { case empty, upToDate, upgrade, updates, security }
    public let level: Level
    /// Status of each installed piece of software, in install order.
    public let software: [(feedID: UUID, status: SoftwareStatus)]
    /// Software with a security update (only when severity tags are shown).
    public var securityCount: Int { software.filter { $0.status.level == .security }.count }
    /// Software with an update or, without a version set, New releases.
    public var updateCount: Int { software.filter { $0.status.level >= .updates }.count }

    /// `showSeverity` follows Settings → Display.
    /// `feeds` tells release feeds from blogs (`Feed.tracksVersions`); software
    /// whose feed is missing is treated as a release feed.
    public init(_ server: Server, entries: [Entry], feeds: [Feed] = [], showSeverity: Bool) {
        let blogs = Set(feeds.filter { !$0.tracksVersions }.map(\.id))
        software = server.feedIDs.map { id in
            (id, SoftwareStatus(feedID: id, running: server.version(of: id), entries: entries,
                                showSeverity: showSeverity, tracksVersions: !blogs.contains(id)))
        }
        switch software.map(\.status.level).max() {
        case nil: level = .empty
        case .upToDate?: level = .upToDate
        case .upgrade?: level = .upgrade
        case .updates?: level = .updates
        case .security?: level = .security
        }
    }
}

/// Checks what the user typed as a server's address.
public enum ServerAddress {
    public enum Kind: Equatable, Sendable { case ipv4, ipv6, hostname }

    /// The kind of address, or nil if it is none of them. Blank is nil.
    public static func classify(_ raw: String) -> Kind? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if isIPv4(s) { return .ipv4 }
        if isIPv6(s) { return .ipv6 }
        // Digits and dots only, but not a valid IPv4: a mistyped IP, not a host.
        if s.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        if isHostname(s) { return .hostname }
        return nil
    }

    public static func isValid(_ raw: String) -> Bool { classify(raw) != nil }

    /// The address is optional: blank is acceptable, anything else must be valid.
    public static func isAcceptable(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValid(raw)
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard (1...3).contains(p.count), p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber),
                  let n = Int(p), n <= 255 else { return false }
            return p == "0" || !p.hasPrefix("0")
        }
    }

    static func isIPv6(_ raw: String) -> Bool {
        var s = raw
        if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }   // zone id, e.g. fe80::1%en0
        guard s.contains(":") else { return false }
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        var groups = 0
        for (i, half) in halves.enumerated() where !half.isEmpty {
            let parts = half.split(separator: ":", omittingEmptySubsequences: false)
            for (j, p) in parts.enumerated() {
                // An embedded IPv4 is allowed as the very last group.
                if i == halves.count - 1, j == parts.count - 1, p.contains(".") {
                    guard isIPv4(String(p)) else { return false }
                    groups += 2
                    continue
                }
                guard (1...4).contains(p.count), p.allSatisfy(\.isHexDigit) else { return false }
                groups += 1
            }
        }
        return halves.count == 2 ? groups < 8 : groups == 8
    }

    static func isHostname(_ s: String) -> Bool {
        let host = s.hasSuffix(".") ? String(s.dropLast()) : s
        guard !host.isEmpty, host.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// Matches software in the catalog against a search query: every word must
/// appear in the name or URL, ignoring case.
public enum SoftwareSearch {
    public static func matches(_ feed: Feed, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = (feed.name + " " + feed.url.absoluteString).lowercased()
        return words.allSatisfy { hay.contains($0) }
    }
}
