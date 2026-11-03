import Foundation

/// How much attention a release needs. Ordered: `routine < important < critical`.
public enum Severity: Int, Codable, Comparable, CaseIterable, Sendable {
    case routine = 0
    case important = 1
    case critical = 2

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .routine: return "ROUTINE"
        case .important: return "IMPORTANT"
        case .critical: return "CRITICAL"
        }
    }
}

/// A named folder of feeds, e.g. "Lightning" or "Hardware".
public struct FeedGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(name: String) {
        self.id = UUID()
        self.name = name
    }
}

/// A subscribed feed plus its polling state.
public struct Feed: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    /// The group this feed is filed under; nil for ungrouped.
    public var groupID: UUID?
    /// Per-feed override for alerts about releases that predate the
    /// subscription; nil follows the global setting.
    public var ignoreOldAlerts: Bool?
    /// Last check of the repository's GitHub security advisories.
    public var advisoriesCheckedAt: Date?
    public var advisoriesETag: String?
    /// Conditional-request validators from the last 200 response.
    public var etag: String?
    public var lastModified: String?
    public var lastChecked: Date?
    public var lastError: String?
    /// False until the first successful fetch. The first fetch records every
    /// existing entry as read and sends no notifications; otherwise subscribing
    /// to a feed would fire one alert per historic release.
    public var seeded: Bool

    public init(name: String, url: URL, groupID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.groupID = groupID
        self.seeded = false
    }
}

/// What kind of thing a feed entry turned out to be. GitHub's releases feed
/// also lists bare tags, which projects such as Bitcoin Core push days before
/// publishing the release; a tag entry's text is only the tag message.
public enum EntryKind: String, Codable, Sendable {
    case release
    case tagOnly
    case post
}

/// One piece of evidence beyond the feed entry itself.
public struct EvidenceItem: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The full release body from GitHub's API (the feed can be shorter).
        case releaseNotes
        /// A release-notes or changelog file the release links to.
        case linkedNotes
        /// A published GitHub security advisory that applies to this release.
        case advisory
    }

    public var kind: Kind
    /// Where it came from: a URL, or an advisory ID.
    public var source: String
    public var title: String
    public var text: String
    /// For advisories: GitHub's rating (low, medium, high, critical).
    public var rating: String?
    public var fetchedAt: Date

    public init(kind: Kind, source: String, title: String, text: String, rating: String? = nil, fetchedAt: Date) {
        self.kind = kind
        self.source = source
        self.title = title
        self.text = text
        self.rating = rating
        self.fetchedAt = fetchedAt
    }
}

/// One reason behind a severity: which rule matched, where, and the words
/// around the match.
public struct MatchDetail: Codable, Hashable, Sendable {
    /// The rule as written in the keyword list, e.g. `/CVE-\d{4}-\d+/`.
    public var keyword: String
    /// "title", "feed text", "release notes", "linked notes" or "GitHub advisory".
    public var source: String
    public var snippet: String
    /// The text the rule matched, e.g. "CVE-2026-98432". Nil for advisories
    /// and for details saved by earlier versions.
    public var matched: String?
    /// Which list the rule came from: critical, signal, important or advisory.
    public var tier: String?

    public init(keyword: String, source: String, snippet: String, matched: String? = nil, tier: String? = nil) {
        self.keyword = keyword
        self.source = source
        self.snippet = snippet
        self.matched = matched
        self.tier = tier
    }
}

/// Where automatic evidence gathering stands for an entry.
public enum EvidenceState: String, Codable, Sendable {
    /// Not a GitHub release, or seeded history that is only enriched on request.
    case notRequested
    case pending
    /// First look at the newest seeded releases when a feed is added. Like
    /// pending, but a raised severity is not shown as a rise: the user never
    /// saw the lower score.
    case initial
    case done
    case failed

    public var isQueued: Bool { self == .pending || self == .initial }
}

/// One release or post, as stored by the app.
public struct Entry: Codable, Identifiable, Hashable, Sendable {
    /// `feedID/entryKey`, unique across feeds.
    public var id: String
    public var feedID: UUID
    public var title: String
    public var link: URL?
    public var published: Date?
    public var author: String?
    /// Plain text of the feed entry body, truncated to `FeedParser.maxTextLength`.
    public var text: String
    /// Links found in the feed entry body, used to find linked release notes.
    public var links: [String]
    public var severity: Severity
    /// The keywords that set `severity`, for display ("why is this critical?").
    public var matches: [String]
    public var details: [MatchDetail]
    /// What the evidence did not cover, in words: "tag only", "notes are only links".
    public var coverage: [String]
    /// The score from the feed text alone, before any extra evidence.
    public var baseline: Severity
    public var kind: EntryKind?
    public var evidence: [EvidenceItem]
    public var evidenceState: EvidenceState
    /// Increments when the feed changes an entry already seen (a tag becoming
    /// a release, edited notes).
    public var revision: Int
    /// Highest severity already alerted on, or accepted silently at seeding.
    /// An alert fires only when severity rises above it.
    public var notifiedSeverity: Severity
    /// Set when severity rose after the entry was first seen.
    public var escalatedFrom: Severity?
    /// True for entries recorded when their feed was first subscribed.
    public var seeded: Bool
    public var firstSeen: Date
    /// True once the release has been moved to Old (the app's "read" state).
    /// New releases, and releases whose severity rises, are in New.
    public var read: Bool

    public init(id: String, feedID: UUID, title: String, link: URL?, published: Date?, author: String?,
                text: String, links: [String] = [], severity: Severity, matches: [String],
                details: [MatchDetail] = [], coverage: [String] = [], baseline: Severity? = nil,
                kind: EntryKind? = nil, evidence: [EvidenceItem] = [], evidenceState: EvidenceState = .notRequested,
                revision: Int = 0, notifiedSeverity: Severity = .routine, escalatedFrom: Severity? = nil,
                seeded: Bool = false, firstSeen: Date, read: Bool) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.link = link
        self.published = published
        self.author = author
        self.text = text
        self.links = links
        self.severity = severity
        self.matches = matches
        self.details = details
        self.coverage = coverage
        self.baseline = baseline ?? severity
        self.kind = kind
        self.evidence = evidence
        self.evidenceState = evidenceState
        self.revision = revision
        self.notifiedSeverity = notifiedSeverity
        self.escalatedFrom = escalatedFrom
        self.seeded = seeded
        self.firstSeen = firstSeen
        self.read = read
    }

    // Written by hand so entries saved by earlier versions still load. Those
    // are treated as seeded history whose current severity was already seen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        feedID = try c.decode(UUID.self, forKey: .feedID)
        title = try c.decode(String.self, forKey: .title)
        link = try c.decodeIfPresent(URL.self, forKey: .link)
        published = try c.decodeIfPresent(Date.self, forKey: .published)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        text = try c.decode(String.self, forKey: .text)
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        severity = try c.decode(Severity.self, forKey: .severity)
        matches = try c.decodeIfPresent([String].self, forKey: .matches) ?? []
        details = try c.decodeIfPresent([MatchDetail].self, forKey: .details) ?? []
        coverage = try c.decodeIfPresent([String].self, forKey: .coverage) ?? []
        baseline = try c.decodeIfPresent(Severity.self, forKey: .baseline) ?? severity
        kind = try c.decodeIfPresent(EntryKind.self, forKey: .kind)
        evidence = try c.decodeIfPresent([EvidenceItem].self, forKey: .evidence) ?? []
        evidenceState = try c.decodeIfPresent(EvidenceState.self, forKey: .evidenceState) ?? .notRequested
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        notifiedSeverity = try c.decodeIfPresent(Severity.self, forKey: .notifiedSeverity) ?? severity
        escalatedFrom = try c.decodeIfPresent(Severity.self, forKey: .escalatedFrom)
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? true
        firstSeen = try c.decode(Date.self, forKey: .firstSeen)
        read = try c.decode(Bool.self, forKey: .read)
    }
}

/// What a feed parser produces, before scoring.
public struct ParsedEntry: Hashable, Sendable {
    public var key: String
    public var title: String
    public var link: URL?
    public var published: Date?
    public var author: String?
    public var text: String
    /// href values from the body's HTML, in order, de-duplicated, at most 30.
    public var links: [String]

    public init(key: String, title: String, link: URL?, published: Date?, author: String?, text: String,
                links: [String] = []) {
        self.key = key
        self.title = title
        self.link = link
        self.published = published
        self.author = author
        self.text = text
        self.links = links
    }
}

/// Turns what the user typed into a feed URL and a display name.
///
/// Accepts `owner/repo`, a GitHub or GitLab project URL (with or without
/// `/releases`, and with or without `https://`), or any other http(s) feed
/// URL, which is used as given.
public enum FeedInput {
    public static func resolve(_ raw: String) -> (name: String, url: URL)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for host in ["github.com/", "www.github.com/", "gitlab.com/", "www.gitlab.com/"] where s.lowercased().hasPrefix(host) {
            s = "https://" + s
        }

        let ownerRepo = #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#
        if s.range(of: ownerRepo, options: .regularExpression) != nil {
            return github(s)
        }

        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host?.lowercased()
        else { return nil }

        if host == "github.com" || host == "www.github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 2, !url.path.hasSuffix(".atom") {
                return github("\(parts[0])/\(parts[1])")
            }
        }
        if host == "gitlab.com" || host == "www.gitlab.com", !url.path.hasSuffix(".atom") {
            return gitlab(url)
        }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return (name, url)
    }

    /// GitLab projects can sit in nested groups (`group/sub/project`); the
    /// project path is everything before GitLab's `/-/` separator.
    private static func gitlab(_ url: URL) -> (name: String, url: URL)? {
        var parts = url.path.split(separator: "/").map(String.init)
        if let dash = parts.firstIndex(of: "-") { parts = Array(parts[..<dash]) }
        if let last = parts.last, last.hasSuffix(".git") { parts[parts.count - 1] = String(last.dropLast(4)) }
        guard parts.count >= 2 else { return nil }
        let project = parts.joined(separator: "/")
        guard let feed = URL(string: "https://gitlab.com/\(project)/-/releases.atom") else { return nil }
        return (project, feed)
    }

    private static func github(_ ownerRepo: String) -> (name: String, url: URL)? {
        let repo = ownerRepo.hasSuffix(".git") ? String(ownerRepo.dropLast(4)) : ownerRepo
        guard let url = URL(string: "https://github.com/\(repo)/releases.atom") else { return nil }
        return (repo, url)
    }
}
