import Foundation

/// Keyword lists that decide an entry's severity. Edited in the app's settings.
///
/// Three tiers:
/// - `critical`: one match anywhere makes the entry CRITICAL. Keep these
///   specific (CVE ids, "vulnerab", "funds at risk").
/// - `signals`: words that are strong in a headline but common in passing,
///   such as "security". CRITICAL if one appears in the title or two different
///   ones appear anywhere; otherwise IMPORTANT.
/// - `important`: one match anywhere makes the entry IMPORTANT.
///
/// Matching rules, applied to the title plus the release notes:
/// - Case-insensitive.
/// - A plain keyword must start at a word boundary but may run on, so
///   `vulnerab` matches "vulnerability" and "vulnerable", and `fix` does not
///   match "prefix". Phrases with spaces work the same way.
/// - A keyword wrapped in slashes is a regular expression: `/CVE-\d{4}-\d+/`.
/// - Ignore phrases are deleted from the text before matching, to silence
///   boilerplate such as a project's standard "report security issues to…" footer.
public struct KeywordConfig: Codable, Equatable, Sendable {
    public var critical: [String]
    public var signals: [String]
    public var important: [String]
    public var ignore: [String]

    public init(critical: [String], signals: [String], important: [String], ignore: [String]) {
        self.critical = critical
        self.signals = signals
        self.important = important
        self.ignore = ignore
    }

    public static let defaults = KeywordConfig(
        critical: [
            "vulnerab",
            #"/CVE-\d{4}-\d+/"#,
            #"/GHSA(-[0-9a-z]{4}){3}/"#,
            "exploit",
            "emergency",
            "upgrade immediately",
            "update immediately",
            "upgrade as soon as possible",
            "update as soon as possible",
            "funds at risk",
            "loss of funds",
            "zero-day",
            "0-day",
            "security incident",
            "security advisory",
        ],
        signals: [
            "security",
            "critical",
            "urgent",
            "attacker",
            "theft",
            "advisory",
            "disclosure",
            "malicious",
        ],
        important: [
            "hotfix",
            "regression",
            "crash",
            "data loss",
            "corrupt",
            "consensus",
            "breaking change",
            "backward incompatible",
            "deprecat",
            "action required",
            "please upgrade",
            "strongly recommended",
            "highly recommended",
            "recommended upgrade",
        ],
        ignore: [
            "SECURITY.md",
            "security policy",
            // Footer of every Bitcoin Core release-notes file.
            "To receive security and update notifications",
        ]
    )
}

public struct Classification: Equatable, Sendable {
    public var severity: Severity
    /// Keywords that set the severity: critical keywords, then signals, then important ones.
    public var matches: [String]
    /// Where each of `matches` was found, with surrounding words.
    public var details: [MatchDetail] = []
}

public struct Classifier: Sendable {
    private struct Rule: Sendable {
        let label: String
        let regex: NSRegularExpression
    }

    private let critical: [Rule]
    private let signals: [Rule]
    private let important: [Rule]
    private let ignore: [NSRegularExpression]

    public init(_ config: KeywordConfig) {
        critical = config.critical.compactMap(Classifier.rule)
        signals = config.signals.compactMap(Classifier.rule)
        important = config.important.compactMap(Classifier.rule)
        ignore = config.ignore.compactMap(Classifier.ignoreRule)
    }

    /// An Ignore phrase as a pattern. Words may be separated in the text by
    /// any run of spaces, line breaks or Markdown emphasis (`*`, `_`, `` ` ``,
    /// `~`), because snippets show the text with those collapsed and users copy
    /// phrases from there. `/…/` is a regular expression, as in the other lists.
    private static func ignoreRule(_ raw: String) -> NSRegularExpression? {
        let p = raw.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        if p.count >= 3, p.hasPrefix("/"), p.hasSuffix("/") {
            return try? NSRegularExpression(pattern: String(p.dropFirst().dropLast()), options: [.caseInsensitive])
        }
        let words = p.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        return try? NSRegularExpression(pattern: words.joined(separator: #"[\s*_`~]+"#), options: [.caseInsensitive])
    }

    /// Returns nil for a blank line or an invalid regular expression.
    private static func rule(_ raw: String) -> Rule? {
        let k = raw.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return nil }
        let pattern: String
        if k.count >= 3, k.hasPrefix("/"), k.hasSuffix("/") {
            pattern = String(k.dropFirst().dropLast())
        } else {
            // Word start, then the literal; whitespace in the keyword matches any run of whitespace.
            let words = k.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#)
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return Rule(label: k, regex: re)
    }

    /// Validates one keyword line for the settings editor. Returns an error message or nil.
    public static func problem(with keyword: String) -> String? {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard k.count >= 3, k.hasPrefix("/"), k.hasSuffix("/") else { return nil }
        do {
            _ = try NSRegularExpression(pattern: String(k.dropFirst().dropLast()))
            return nil
        } catch {
            return "invalid regular expression: \(k)"
        }
    }

    /// Fixed phrases in which a signal word is negated. Only signal-tier
    /// matches inside these are dropped; critical keywords (CVE ids,
    /// "vulnerab") still count, so "no security impact; fixes CVE-…" stays
    /// critical. Deliberately a short exact list, not a negation parser.
    public static let negations = [
        "no security impact", "no security implications", "no security implication",
        "not a security fix", "not a security issue", "not security related", "not security-related",
        "no security relevance", "not security relevant",
    ]
    private static let negationRegexes: [NSRegularExpression] = negations.compactMap {
        let words = $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        return try? NSRegularExpression(pattern: words.joined(separator: #"\s+"#), options: [.caseInsensitive])
    }

    /// Scores a title plus body. `source` names the body in match details
    /// ("release notes", "linked notes").
    public func classify(title: String, text: String, source: String = "release notes") -> Classification {
        let title = scrub(title)
        let body = scrub(text)
        let all = title + "\n" + body
        let titleSignals = Classifier.removeNegations(title)
        let allSignals = Classifier.removeNegations(all)

        func hits(_ rules: [Rule], in s: String) -> [Rule] {
            let range = NSRange(s.startIndex..., in: s)
            return rules.filter { $0.regex.firstMatch(in: s, range: range) != nil }
        }
        // Signal snippets skip occurrences inside a negated phrase, so the
        // snippet shows the occurrence that actually counted.
        func detail(_ rule: Rule, skipNegated: Bool, tier: String) -> MatchDetail? {
            for (name, s) in [("title", title), (source, body)] where !s.isEmpty {
                let range = NSRange(s.startIndex..., in: s)
                for m in rule.regex.matches(in: s, range: range) {
                    guard let r = Range(m.range, in: s) else { continue }
                    if skipNegated, isNegated(r, in: s) { continue }
                    return MatchDetail(keyword: rule.label, source: name, snippet: Classifier.snippet(s, around: r),
                                       matched: String(s[r]), tier: tier)
                }
            }
            return nil
        }

        let c = hits(critical, in: all)
        let sig = hits(signals, in: allSignals)
        let result: (Severity, [Rule])
        if !c.isEmpty || sig.count >= 2 || !hits(signals, in: titleSignals).isEmpty {
            result = (.critical, c + sig)
        } else {
            let i = hits(important, in: all)
            if !sig.isEmpty || !i.isEmpty {
                result = (.important, sig + i)
            } else {
                result = (.routine, [])
            }
        }
        let sigLabels = Set(sig.map(\.label))
        let critLabels = Set(c.map(\.label))
        return Classification(
            severity: result.0,
            matches: result.1.map(\.label),
            details: result.1.compactMap { rule in
                let tier = critLabels.contains(rule.label) ? "critical" : sigLabels.contains(rule.label) ? "signal" : "important"
                return detail(rule, skipNegated: tier == "signal", tier: tier)
            }
        )
    }

    private func isNegated(_ r: Range<String.Index>, in s: String) -> Bool {
        let ns = NSRange(s.startIndex..., in: s)
        let target = NSRange(r, in: s)
        return Classifier.negationRegexes.contains { re in
            re.matches(in: s, range: ns).contains { NSIntersectionRange($0.range, target).length > 0 }
        }
    }

    static func removeNegations(_ s: String) -> String {
        var out = s
        for re in negationRegexes {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        return out
    }

    /// About 50 characters either side of the match, on one line.
    static func snippet(_ s: String, around r: Range<String.Index>) -> String {
        let lo = s.index(r.lowerBound, offsetBy: -50, limitedBy: s.startIndex) ?? s.startIndex
        let hi = s.index(r.upperBound, offsetBy: 50, limitedBy: s.endIndex) ?? s.endIndex
        var out = String(s[lo..<hi]).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if lo > s.startIndex { out = "…" + out }
        if hi < s.endIndex { out += "…" }
        return out
    }

    private func scrub(_ s: String) -> String {
        var out = s
        for re in ignore {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        return out
    }
}
