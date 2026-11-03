import Foundation

public enum FetchResult: Sendable {
    /// 304: the server says nothing changed since the stored validators.
    case notModified
    case updated(entries: [ParsedEntry], etag: String?, lastModified: String?)
}

public enum FetchError: Error, CustomStringConvertible {
    case http(Int)
    case parse(FeedParseError)
    case transport(String)

    public var description: String {
        switch self {
        case .http(let code):
            return code == 429 ? "HTTP 429: rate limited, will retry next cycle" : "HTTP \(code)"
        case .parse(let e): return e.description
        case .transport(let m): return m
        }
    }
}

/// Conditional GET of one feed. With stored validators the steady state is a
/// 304 with an empty body, which keeps polling GitHub cheap and polite.
public struct Fetcher: Sendable {
    private let session: URLSession
    public static let userAgent = "pwnd/0.1 (personal release-feed reader; conditional requests)"

    public init() {
        let config = URLSessionConfiguration.ephemeral
        // We send our own validators; URLSession's cache would otherwise turn
        // a 304 into a cached 200 and hide whether anything changed.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.httpAdditionalHeaders = ["User-Agent": Fetcher.userAgent]
        session = URLSession(configuration: config)
    }

    public func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FetchResult {
        var req = URLRequest(url: url)
        req.setValue("application/atom+xml, application/rss+xml, application/xml;q=0.9, */*;q=0.5",
                     forHTTPHeaderField: "Accept")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FetchError.transport("not an HTTP response") }
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
        do {
            let entries = try FeedParser.parse(data)
            return .updated(entries: entries,
                            etag: http.value(forHTTPHeaderField: "ETag"),
                            lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        } catch let e as FeedParseError {
            throw FetchError.parse(e)
        }
    }
}
