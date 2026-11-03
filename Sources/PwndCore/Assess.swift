import Foundation

/// A GitHub repository behind a `github.com/<owner>/<repo>/releases.atom` feed.
public struct GitHubRepo: Hashable, Sendable {
    public var owner: String
    public var name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public init?(feedURL: URL) {
        guard let host = feedURL.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = feedURL.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[2] == "releases.atom" else { return nil }
        self.init(owner: parts[0], name: parts[1])
    }

    /// The tag in a release link: `https://github.com/o/r/releases/tag/<tag>`.
    public func tag(fromReleaseLink url: URL?) -> String? {
        guard let url else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 5, parts[0].caseInsensitiveCompare(owner) == .orderedSame,
              parts[1].caseInsensitiveCompare(name) == .orderedSame,
              parts[2] == "releases", parts[3] == "tag" else { return nil }
        // Tags can contain slashes; everything after /tag/ is the tag.
        return parts[4...].joined(separator: "/").removingPercentEncoding
    }

    /// The first link to a release-notes or changelog Markdown file in this
    /// same repository, as a raw-content URL. Only this repository's files are
    /// followed, one hop, so a release cannot point pwnd at arbitrary hosts.
    public func notesFile(in links: [String]) -> URL? {
        for raw in links {
            guard let url = URL(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: ").,>"))),
                  url.scheme == "https", let host = url.host?.lowercased() else { continue }
            var parts = url.path.split(separator: "/").map(String.init)
            if host == "github.com", parts.count >= 5, parts[2] == "blob" {
                parts.remove(at: 2)                      // owner/repo/ref/path…
            } else if host != "raw.githubusercontent.com" || parts.count < 4 {
                continue
            }
            guard parts[0].caseInsensitiveCompare(owner) == .orderedSame,
                  parts[1].caseInsensitiveCompare(name) == .orderedSame else { continue }
            let path = parts[3...].joined(separator: "/").lowercased()
            guard path.hasSuffix(".md"),
                  ["release-notes", "release_notes", "releasenotes", "changelog", "changes"].contains(where: path.contains)
            else { continue }
            return URL(string: "https://raw.githubusercontent.com/" + parts.joined(separator: "/"))
        }
        return nil
    }
}

/// A published GitHub security advisory for a repository.
public struct Advisory: Codable, Hashable, Sendable {
    public var ghsa: String
    public var cve: String?
    /// GitHub's rating: low, medium, high, critical (or nil).
    public var severity: String?
    public var summary: String
    public var url: String
    public var patched: [String]
    public var vulnerable: [String]

    public init(ghsa: String, cve: String?, severity: String?, summary: String, url: String,
                patched: [String], vulnerable: [String]) {
        self.ghsa = ghsa
        self.cve = cve
        self.severity = severity
        self.summary = summary
        self.url = url
        self.patched = patched
        self.vulnerable = vulnerable
    }

    /// True if this advisory names `tag` as a patched version, or the entry's
    /// text cites the advisory's GHSA or CVE id.
    public func applies(toTag tag: String?, text: String) -> Bool {
        if let tag {
            let t = Advisory.normalize(tag)
            // patched_versions can list several, comma-separated.
            let versions = patched.flatMap { $0.split(separator: ",").map { Advisory.normalize(String($0)) } }
            if versions.contains(t) { return true }
        }
        if text.range(of: ghsa, options: .caseInsensitive) != nil { return true }
        if let cve, text.range(of: cve, options: .caseInsensitive) != nil { return true }
        return false
    }

    static func normalize(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in [">=", "="] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        if s.hasPrefix("v") { s.removeFirst() }
        return s
    }

    /// High and critical advisories make a release critical; others important.
    public var level: Severity {
        switch severity?.lowercased() {
        case "critical", "high": return .critical
        default: return .important
        }
    }

    public func evidence(at date: Date) -> EvidenceItem {
        EvidenceItem(kind: .advisory, source: ghsa, title: summary,
                     text: [cve, url].compactMap { $0 }.joined(separator: "\n"),
                     rating: severity, fetchedAt: date)
    }
}

/// Combines the feed text and any extra evidence into one severity.
public enum Assessor {
    /// Below this, a feed body that also contains links probably points to
    /// notes elsewhere ("now available from: <link>").
    static let sparseLength = 400

    public static func assess(_ e: inout Entry, classifier: Classifier) {
        let base = classifier.classify(title: e.title, text: e.text, source: "feed text")
        var severity = base.severity
        var matches = base.matches
        var details = base.details

        func add(_ c: Classification) {
            severity = max(severity, c.severity)
            for m in c.matches where !matches.contains(m) { matches.append(m) }
            for d in c.details where !details.contains(where: { $0.keyword == d.keyword && $0.source == d.source }) {
                details.append(d)
            }
        }
        for item in e.evidence {
            switch item.kind {
            case .releaseNotes: add(classifier.classify(title: "", text: item.text, source: "release notes"))
            case .linkedNotes: add(classifier.classify(title: "", text: item.text, source: "linked notes"))
            case .advisory:
                let level: Severity = ["critical", "high"].contains(item.rating?.lowercased() ?? "") ? .critical : .important
                let label = item.source + (item.rating.map { " (\($0))" } ?? "")
                add(Classification(severity: level, matches: [label],
                                   details: [MatchDetail(keyword: label, source: "GitHub advisory", snippet: item.title,
                                                         matched: label, tier: "advisory")]))
            }
        }

        e.baseline = base.severity
        e.severity = severity
        e.matches = matches
        e.details = details
        e.coverage = coverage(e)
    }

    static func coverage(_ e: Entry) -> [String] {
        var out: [String] = []
        if e.kind == .tagOnly {
            out.append("Tag only: no GitHub release has been published for this tag yet. The text is the tag message.")
        }
        let hasNotes = e.evidence.contains { $0.kind == .releaseNotes || $0.kind == .linkedNotes }
        if !hasNotes, e.kind != .tagOnly, e.text.count < sparseLength, !e.links.isEmpty {
            out.append("The feed text is short and mostly links, so little was checked.")
        }
        // Whether fetching is queued, running or paused is live state, shown by
        // the app; stored coverage only describes the evidence in hand.
        if e.evidenceState == .failed {
            out.append("Could not fetch extra evidence; only the feed text was checked.")
        }
        if e.severity == .routine, !out.isEmpty {
            out.append("Routine means nothing was found in this evidence, not that the release is safe.")
        }
        return out
    }
}

/// Decides when a severity change should notify.
public enum Alerts {
    /// Call after `entry` has been re-assessed. `previous` is its severity
    /// before. Returns true when a notification should be posted.
    ///
    /// - A rise after first sight is recorded in `escalatedFrom`.
    /// - An alert fires once per level: only when severity exceeds
    ///   `notifiedSeverity` and reaches `threshold`.
    /// - Seeded history with `ignoreOld` stays quiet but still records the
    ///   level, so turning the setting off later does not replay old alerts.
    /// - An alerted escalation marks the entry unread again.
    public static func evaluate(_ e: inout Entry, previous: Severity?, threshold: Severity, ignoreOld: Bool) -> Bool {
        if let previous, e.severity > previous {
            e.escalatedFrom = min(e.escalatedFrom ?? previous, previous)
        }
        guard e.severity > e.notifiedSeverity else { return false }
        let quiet = e.seeded && ignoreOld
        if quiet {
            e.notifiedSeverity = e.severity
            return false
        }
        guard e.severity >= threshold else { return false }
        e.notifiedSeverity = e.severity
        if previous != nil { e.read = false }
        return true
    }
}
