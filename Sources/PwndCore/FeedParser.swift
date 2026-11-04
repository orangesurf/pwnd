import Foundation
#if canImport(FoundationXML)
import FoundationXML // XMLParser lives here on Linux
#endif

public enum FeedParseError: Error, CustomStringConvertible {
    case invalidXML(String)
    case notAFeed

    public var description: String {
        switch self {
        case .invalidXML(let m): return "invalid XML: \(m)"
        case .notAFeed: return "not an RSS or Atom feed"
        }
    }
}

/// Parses Atom (GitHub releases) and RSS 2.0 feeds with Foundation's XMLParser.
/// Entries come back in feed order, which for both formats is newest first.
public enum FeedParser {
    /// Stored text is capped. Scoring uses the stored text, so a rescore gives
    /// the same result as the first score.
    public static let maxTextLength = 32_000

    public static func parse(_ data: Data) throws -> [ParsedEntry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        if !parser.parse() {
            throw FeedParseError.invalidXML(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard delegate.sawFeedRoot else { throw FeedParseError.notAFeed }
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [ParsedEntry] = []
        var sawFeedRoot = false

        private var inItem = false
        private var depthInItem = 0
        private var fields: [String: String] = [:]
        private var link: String?
        private var buffer = ""
        private var stack: [String] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(name)
            if stack.count == 1, name == "feed" || name == "rss" || name == "rdf:RDF" {
                sawFeedRoot = true
            }
            if name == "entry" || name == "item" {
                inItem = true
                depthInItem = stack.count
                fields = [:]
                link = nil
                return
            }
            guard inItem else { return }
            buffer = ""
            // Atom: <link rel="alternate" href="..."/>. A link with no rel is alternate.
            if name == "link", let href = attributes["href"] {
                let rel = attributes["rel"] ?? "alternate"
                if rel == "alternate" || link == nil { link = href }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inItem { buffer += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if inItem, let s = String(data: CDATABlock, encoding: .utf8) { buffer += s }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            defer { stack.removeLast() }
            guard inItem else { return }

            if (name == "entry" || name == "item") && stack.count == depthInItem {
                inItem = false
                finishItem()
                return
            }
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            // Only direct children of the item, plus author/name inside Atom <author>.
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
            if parent == "author", name == "name" {
                fields["author"] = value
            } else if stack.count == depthInItem + 1, !value.isEmpty {
                // RSS <link> carries the URL as text.
                if name == "link", link == nil { link = value }
                if fields[name] == nil { fields[name] = value }
            }
        }

        private func finishItem() {
            let title = fields["title"].map(HTMLText.decodeEntities) ?? "(untitled)"
            let body = fields["content"] ?? fields["content:encoded"] ?? fields["description"]
                ?? fields["summary"] ?? ""
            let linkURL = link.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            let key = fields["id"] ?? fields["guid"] ?? link ?? title
            let dateString = fields["updated"] ?? fields["published"] ?? fields["pubDate"] ?? fields["dc:date"]
            let author = fields["author"] ?? fields["dc:creator"]
            entries.append(ParsedEntry(
                key: key,
                title: title,
                link: linkURL,
                published: dateString.flatMap(FeedDate.parse),
                author: author,
                text: HTMLText.plain(body),
                links: HTMLText.links(body)
            ))
        }
    }
}

enum FeedDate {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let rfc822: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = iso.date(from: t) ?? isoFractional.date(from: t) { return d }
        for f in rfc822 { if let d = f.date(from: t) { return d } }
        return nil
    }
}

/// Minimal HTML → text, enough for release notes. Not a sanitiser: the output
/// is only ever shown as plain text.
public enum HTMLText {
    public static func plain(_ html: String) -> String {
        var s = html
        // Block-level boundaries become line breaks so list items and
        // paragraphs stay readable.
        let breaks = [#"<br\s*/?>"#, #"</p>"#, #"</h[1-6]>"#, #"</li>"#, #"</pre>"#, #"</tr>"#, #"</div>"#]
        for b in breaks {
            s = s.replacingOccurrences(of: b, with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"<li[^>]*>"#, with: "• ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<(script|style)[^>]*>[\s\S]*?</\1>"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// href values in document order, entity-decoded, de-duplicated, at most 30.
    public static func links(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])
        else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let href = decodeEntities(String(html[r])).trimmingCharacters(in: .whitespaces)
            if href.hasPrefix("http"), seen.insert(href).inserted { out.append(href) }
            if out.count == 30 { break }
        }
        return out
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "bull": "•", "copy": "©",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    replacement = named[name]
                }
                if let r = replacement {
                    out += r
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
}
