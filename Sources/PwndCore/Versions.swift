import Foundation

/// A version number found in a release title or typed by the user, e.g.
/// "Bitcoin Core 29.5" → 29.5, "lnd v0.21.6-beta" → 0.21.6, "core/v2.13.0" →
/// 2.13.0 on the "core" track.
public struct SoftwareVersion: Hashable, Comparable, Sendable {
    public let numbers: [Int]
    /// rc, alpha, pre, dev or a numbered beta ("beta2"). A bare "-beta" is not
    /// one: lnd tags every stable release that way.
    public let prerelease: Bool
    /// Which line of releases this belongs to, for repos that ship several:
    /// a tag path ("core", "legacy" in trezor-firmware) and a trailing model
    /// letter ("Q", "X" in Coldcard firmware). "" is the main line.
    public let track: String
    /// The version as written, e.g. "v0.21.6-beta" or "core/v2.13.0".
    public let text: String

    /// Major series: the first number, or the first two for 0.x versions.
    /// 29.4 → 29.5 is an update in the same series; 29.4 → 32.1 is a new series.
    public var series: [Int] { numbers.first == 0 ? Array(numbers.prefix(2)) : Array(numbers.prefix(1)) }

    // path/ v 1.2.3 suffix; not preceded by a digit or dot.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w.])(?:([A-Za-z][\w.-]*(?:/[\w.-]+)*)/)?[vV]?(\d+(?:\.\d+)+)((?:[-.+]?[A-Za-z]+\d*(?:\.\d+)?)*)"#)
    private static let lenientPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:([A-Za-z][\w.-]*(?:/[\w.-]+)*)/)?[vV]?(\d+(?:\.\d+)*)((?:[-.+]?[A-Za-z]+\d*(?:\.\d+)?)*)\s*$"#)

    /// The first version in a release title. Needs at least one dot, so dates
    /// and PR numbers don't count.
    public static func parse(title: String) -> SoftwareVersion? { parse(title, with: pattern) }

    /// A version the user typed: the whole string, and "29" alone is allowed.
    public static func parse(typed: String) -> SoftwareVersion? { parse(typed, with: lenientPattern) }

    private static func parse(_ s: String, with re: NSRegularExpression) -> SoftwareVersion? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        let numbers = group(2).split(separator: ".").compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        let suffix = group(3)
        let lower = suffix.lowercased()
        let prerelease = ["rc", "alpha", "pre", "dev", "snapshot"].contains { lower.contains($0) }
            || lower.range(of: #"beta[.]?\d"#, options: .regularExpression) != nil
        var track = group(1)
        // A model suffix such as Coldcard's Q, X or QX marks its own line of releases.
        if (1...3).contains(suffix.count), suffix.allSatisfy({ $0.isUppercase && $0.isASCII }) {
            track += track.isEmpty ? suffix : ":" + suffix
        }
        let text = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
        return SoftwareVersion(numbers: numbers, prerelease: prerelease, track: track, text: text)
    }

    public init(numbers: [Int], prerelease: Bool = false, track: String = "", text: String? = nil) {
        self.numbers = numbers
        self.prerelease = prerelease
        self.track = track
        self.text = text ?? numbers.map(String.init).joined(separator: ".")
    }

    /// The same version on another track, used when the user types "2.12.5"
    /// for software whose releases are all on one named track.
    func on(track: String) -> SoftwareVersion {
        SoftwareVersion(numbers: numbers, prerelease: prerelease, track: track, text: text)
    }

    /// Compares numbers (missing parts count as 0), then a prerelease sorts
    /// before its final release. Track and text are ignored.
    public static func < (a: SoftwareVersion, b: SoftwareVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        return a.prerelease && !b.prerelease
    }

    /// Same version number and prerelease state, whatever the spelling.
    public func sameRelease(as other: SoftwareVersion) -> Bool { !(self < other) && !(other < self) }
}

/// Where one piece of software on a server stands.
///
/// With the running version set, it compares versions: an update is a newer
/// release in the same series (29.4 → 29.5); a newer series alone (29.4 →
/// 32.1) is an upgrade. Without a version, it falls back to New releases.
public struct SoftwareStatus: Sendable {
    public enum Level: Int, Comparable, Sendable {
        case upToDate, upgrade, updates, security
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public let level: Level
    /// The running version as parsed; nil when not set or not understood.
    public let running: SoftwareVersion?
    /// True when the user typed something that is not a version.
    public let runningInvalid: Bool
    /// The highest final release on the running (or main) track, by version
    /// number rather than publish date, with its entry.
    public let latest: (entry: Entry, version: SoftwareVersion)?
    /// The newest release in the running version's series, if newer.
    public let update: SoftwareVersion?
    /// Releases newer than the running version, highest first.
    public let newer: [Entry]
    /// New releases, used when no version is set.
    public let newCount: Int
    /// Final releases on the track, highest first, one per version: what the
    /// version picker offers.
    public let known: [SoftwareVersion]

    /// `showSeverity` follows Settings → Display: with tags hidden, a critical
    /// release counts as an ordinary update. `tracksVersions` is false for
    /// blogs and news feeds (see `Feed.tracksVersions`), whose titles mention
    /// versions without being releases; they always use New releases.
    public init(feedID: UUID, running typed: String?, entries all: [Entry], showSeverity: Bool,
                tracksVersions: Bool = true) {
        let entries = all.filter { $0.feedID == feedID }
        // Final releases with a version, highest first, newest entry first among equals.
        let versioned = entries.filter { _ in tracksVersions }
            .compactMap { e in SoftwareVersion.parse(title: e.title).map { (entry: e, version: $0) } }
            .filter { !$0.version.prerelease }
            .sorted { a, b in b.version < a.version || (!(a.version < b.version) && Entry.newestFirst(a.entry, b.entry)) }
        let tracks = Set(versioned.map(\.version.track))
        let mainTrack = tracks.contains("") ? ""
            : versioned.max { Entry.newestFirst($1.entry, $0.entry) }?.version.track ?? ""

        let text = tracksVersions ? typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        var running = text.isEmpty ? nil : SoftwareVersion.parse(typed: text)
        if let r = running, !tracks.contains(r.track) { running = r.on(track: mainTrack) }
        self.running = running
        runningInvalid = !text.isEmpty && running == nil

        let track = running?.track ?? mainTrack
        var inTrack: [(entry: Entry, version: SoftwareVersion)] = []
        for v in versioned where v.version.track == track && !inTrack.contains(where: { $0.version.sameRelease(as: v.version) }) {
            inTrack.append(v)
        }
        latest = inTrack.first
        known = inTrack.map(\.version)

        if let running {
            let newer = inTrack.filter { running < $0.version }
            self.newer = newer.map(\.entry)
            update = newer.first { $0.version.series == running.series }?.version
            newCount = 0
            let security = showSeverity && newer.contains { $0.entry.severity == .critical }
            level = security ? .security : update != nil ? .updates : newer.isEmpty ? .upToDate : .upgrade
        } else {
            let fresh = entries.filter { !$0.read }
            newer = []
            update = nil
            newCount = fresh.count
            let security = showSeverity && fresh.contains { $0.severity == .critical }
            level = security ? .security : fresh.isEmpty ? .upToDate : .updates
        }
    }
}

extension Feed {
    /// A GitHub or GitLab releases or tags feed, whose entries are versions.
    /// Blogs and news feeds are not, even when their titles mention one.
    public var tracksVersions: Bool {
        let path = url.path.lowercased()
        return path.hasSuffix("/releases.atom") || path.hasSuffix("/tags.atom")
    }
}
