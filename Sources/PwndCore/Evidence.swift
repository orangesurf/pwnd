import Foundation

/// GitHub's unauthenticated REST limit is 60 requests an hour per IP, shared
/// with anything else on the network; with a token it is 5,000 an hour per
/// account. pwnd spends at most `limit` (or `tokenLimit`) in any rolling hour,
/// and stops early when GitHub's headers say the allowance is nearly gone.
public struct RequestBudget: Codable, Equatable, Sendable {
    public static let limit = 40
    public static let tokenLimit = 1000
    static let reserve = 5

    /// Times of requests in the last hour.
    public var stamps: [Date] = []
    /// No requests before this time (from rate-limit headers or Retry-After).
    public var blockedUntil: Date?
    /// Whether that pause came from requests made with a token. A pause from
    /// GitHub's per-IP anonymous limit does not apply once a token is used.
    public var blockedWithToken: Bool?

    public init() {}

    func blocked(at now: Date, limit: Int) -> Date? {
        guard let b = blockedUntil, b > now else { return nil }
        // A token raises the limit; an anonymous-limit pause does not bind it.
        if limit > RequestBudget.limit, blockedWithToken != true { return nil }
        return b
    }

    public func available(at now: Date = Date(), limit: Int = RequestBudget.limit) -> Int {
        if blocked(at: now, limit: limit) != nil { return 0 }
        return max(0, limit - stamps.filter { now.timeIntervalSince($0) < 3600 }.count)
    }

    /// When requests can resume, if they are paused.
    public func resumesAt(now: Date = Date(), limit: Int = RequestBudget.limit) -> Date? {
        if let b = blocked(at: now, limit: limit) { return b }
        let recent = stamps.filter { now.timeIntervalSince($0) < 3600 }.sorted()
        guard recent.count >= limit, let oldest = recent.first else { return nil }
        return oldest.addingTimeInterval(3600)
    }

    public mutating func record(at now: Date = Date()) {
        stamps = stamps.filter { now.timeIntervalSince($0) < 3600 } + [now]
    }

    /// Reads `X-RateLimit-Remaining`, `X-RateLimit-Reset` and `Retry-After`.
    public mutating func observe(status: Int, headers: [String: String], at now: Date = Date(), withToken: Bool = false) {
        let before = blockedUntil
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        if let retry = header("Retry-After").flatMap(Double.init) {
            blockedUntil = now.addingTimeInterval(retry)
        }
        let remaining = header("X-RateLimit-Remaining").flatMap(Int.init)
        let reset = header("X-RateLimit-Reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        if let remaining, remaining < RequestBudget.reserve, let reset {
            blockedUntil = max(blockedUntil ?? reset, reset)
        } else if status == 403 || status == 429, remaining == 0 || remaining == nil, blockedUntil == nil {
            blockedUntil = now.addingTimeInterval(15 * 60)
        }
        if blockedUntil != before { blockedWithToken = withToken }
    }
}

public enum EvidenceError: Error, CustomStringConvertible {
    case budget
    case http(Int)
    case tooLarge
    case transport(String)
    case decode

    public var description: String {
        switch self {
        case .budget: return "GitHub request budget used up; will retry later"
        case .http(let c): return "HTTP \(c)"
        case .tooLarge: return "response too large"
        case .transport(let m): return m
        case .decode: return "unexpected response"
        }
    }
}

public enum ReleaseLookup: Sendable {
    case release(body: String, prerelease: Bool)
    /// GitHub has a tag but no release for it.
    case tagOnly
}

public enum AdvisoryLookup: Sendable {
    case notModified
    case list([Advisory], etag: String?)
}

/// The few GitHub requests evidence gathering makes, all read-only, to fixed
/// routes on api.github.com and raw.githubusercontent.com.
public final class GitHubEvidence: @unchecked Sendable {
    private let session: URLSession
    /// Responses above this are refused rather than parsed.
    static let maxBytes = 2 * 1024 * 1024
    /// Stored evidence text is capped per item.
    public static let maxText = 64_000

    private let lock = NSLock()
    private var _budget: RequestBudget
    private var _token: String?
    public var budget: RequestBudget {
        lock.lock(); defer { lock.unlock() }
        return _budget
    }

    /// A GitHub token, sent only to api.github.com. Nil for unauthenticated.
    public var token: String? {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue?.isEmpty == true ? nil : newValue } }
    }

    public var hourlyLimit: Int { token == nil ? RequestBudget.limit : RequestBudget.tokenLimit }

    public var available: Int { lock.withLock { _budget.available(limit: _token == nil ? RequestBudget.limit : RequestBudget.tokenLimit) } }

    public var resumesAt: Date? { lock.withLock { _budget.resumesAt(limit: _token == nil ? RequestBudget.limit : RequestBudget.tokenLimit) } }

    public enum TokenCheck: Sendable {
        case valid(limit: Int, remaining: Int)
        case rejected
        case failed(String)
    }

    /// Checks a token against GitHub's rate-limit endpoint, which does not
    /// count against the limit. Does not store the token.
    public func check(token: String) async -> TokenCheck {
        var req = URLRequest(url: URL(string: "https://api.github.com/rate_limit")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return .rejected }
            guard status == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let core = (obj["resources"] as? [String: Any])?["core"] as? [String: Any],
                  let limit = core["limit"] as? Int, let remaining = core["remaining"] as? Int
            else { return .failed("HTTP \(status)") }
            return .valid(limit: limit, remaining: remaining)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public init(budget: RequestBudget = RequestBudget()) {
        _budget = budget
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["User-Agent": Fetcher.userAgent]
        session = URLSession(configuration: config, delegate: SameHostRedirects(), delegateQueue: nil)
    }

    public func release(_ repo: GitHubRepo, tag: String) async throws -> ReleaseLookup {
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? tag
        let url = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)/releases/tags/\(encoded)")!
        let (status, data, _) = try await get(url, api: true)
        if status == 404 { return .tagOnly }
        guard status == 200 else { throw EvidenceError.http(status) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EvidenceError.decode }
        return .release(body: (obj["body"] as? String) ?? "", prerelease: (obj["prerelease"] as? Bool) ?? false)
    }

    public func advisories(_ repo: GitHubRepo, etag: String?) async throws -> AdvisoryLookup {
        let url = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)/security-advisories?state=published&per_page=100")!
        let (status, data, headers) = try await get(url, api: true, etag: etag)
        if status == 304 { return .notModified }
        guard status == 200 else { throw EvidenceError.http(status) }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw EvidenceError.decode }
        let advisories: [Advisory] = list.compactMap { a in
            // Published only; a withdrawn advisory no longer applies.
            guard let ghsa = a["ghsa_id"] as? String, a["withdrawn_at"] as? String == nil else { return nil }
            let vulns = (a["vulnerabilities"] as? [[String: Any]]) ?? []
            return Advisory(ghsa: ghsa, cve: a["cve_id"] as? String, severity: a["severity"] as? String,
                            summary: (a["summary"] as? String) ?? ghsa, url: (a["html_url"] as? String) ?? "",
                            patched: vulns.compactMap { $0["patched_versions"] as? String },
                            vulnerable: vulns.compactMap { $0["vulnerable_version_range"] as? String })
        }
        let etag = headers.first { $0.key.caseInsensitiveCompare("ETag") == .orderedSame }?.value
        return .list(advisories, etag: etag)
    }

    /// A Markdown file from `GitHubRepo.notesFile`.
    public func notesFile(_ url: URL) async throws -> String {
        guard url.host == "raw.githubusercontent.com" else { throw EvidenceError.decode }
        let (status, data, _) = try await get(url, api: false)
        guard status == 200 else { throw EvidenceError.http(status) }
        return String(decoding: data, as: UTF8.self)
    }

    private func get(_ url: URL, api: Bool, etag: String? = nil) async throws -> (Int, Data, [String: String]) {
        let token: String? = try lock.withLock {
            let limit = _token == nil ? RequestBudget.limit : RequestBudget.tokenLimit
            guard _budget.available(limit: limit) > 0 else { throw EvidenceError.budget }
            _budget.record()
            return _token
        }
        var req = URLRequest(url: url)
        if api {
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // The token goes to api.github.com only, never to raw content or redirects elsewhere.
        if api, let token, url.host == "api.github.com" {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw EvidenceError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw EvidenceError.transport("not HTTP") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
        if api { lock.withLock { _budget.observe(status: http.statusCode, headers: headers, withToken: token != nil) } }
        guard data.count <= GitHubEvidence.maxBytes else { throw EvidenceError.tooLarge }
        return (http.statusCode, data, headers)
    }
}

/// Follows a redirect only to the same host, so the token is never sent
/// anywhere but the host it was meant for. A renamed GitHub repository
/// redirects within api.github.com, which still works.
final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let from = task.originalRequest?.url?.host
        completionHandler(request.url?.host == from && request.url?.scheme == "https" ? request : nil)
    }
}

extension String {
    /// URLs written out in Markdown or plain text, for finding linked notes.
    var bareURLs: [String] {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>"'\])]+"#) else { return [] }
        return re.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap {
            Range($0.range, in: self).map { String(self[$0]) }
        }
    }
}

extension Entry {
    /// Links to search for a notes file: the feed body's links, then any
    /// URLs written out in the fetched release notes.
    public var candidateLinks: [String] {
        links + evidence.filter { $0.kind == .releaseNotes }.flatMap { $0.text.bareURLs }
    }
}
