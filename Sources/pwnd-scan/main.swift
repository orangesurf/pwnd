import Foundation
import PwndCore

// Fetch feeds once and print how each entry scores with the default keywords.
// Usage: swift run pwnd-scan [--all] [--evidence N] <owner/repo | feed URL>...
// Without --all, routine entries are counted but not listed.
// --evidence N also fetches GitHub release notes, linked notes and advisories
// for the newest N entries of each GitHub feed (about 2 requests per entry
// plus 1 per repository, from the 60/hour unauthenticated allowance).

var args = Array(CommandLine.arguments.dropFirst())
let showAll = args.contains("--all")
args.removeAll { $0 == "--all" }
var evidenceCount = 0
if let i = args.firstIndex(of: "--evidence"), i + 1 < args.count, let n = Int(args[i + 1]) {
    evidenceCount = n
    args.removeSubrange(i...(i + 1))
}
if args.isEmpty {
    FileHandle.standardError.write("usage: pwnd-scan [--all] [--evidence N] <owner/repo | feed URL>...\n".data(using: .utf8)!)
    exit(2)
}

let classifier = Classifier(.defaults)
let fetcher = Fetcher()
let github = GitHubEvidence()
let dateFormat = Date.FormatStyle(date: .numeric, time: .omitted)

func enrich(_ e: inout Entry, repo: GitHubRepo, advisories: [Advisory]) async {
    guard let tag = repo.tag(fromReleaseLink: e.link) else { return }
    do {
        switch try await github.release(repo, tag: tag) {
        case .tagOnly: e.kind = .tagOnly
        case .release(let body, _):
            e.kind = .release
            if !body.isEmpty {
                e.evidence.append(EvidenceItem(kind: .releaseNotes, source: tag, title: "Release notes", text: body, fetchedAt: Date()))
            }
            if let url = repo.notesFile(in: e.candidateLinks) {
                let text = try await github.notesFile(url)
                e.evidence.append(EvidenceItem(kind: .linkedNotes, source: url.absoluteString, title: url.lastPathComponent,
                                               text: String(text.prefix(GitHubEvidence.maxText)), fetchedAt: Date()))
            }
        }
        e.evidenceState = .done
    } catch {
        e.evidenceState = .failed
        print("     ! \(e.title): \(error)")
    }
    let text = ([e.title, e.text] + e.evidence.map(\.text)).joined(separator: "\n")
    e.evidence += advisories.filter { $0.applies(toTag: tag, text: text) }.map { $0.evidence(at: Date()) }
}

for arg in args {
    guard let (name, url) = FeedInput.resolve(arg) else {
        print("? \(arg): not a repo or feed URL")
        continue
    }
    do {
        guard case .updated(let parsed, _, _) = try await fetcher.fetch(url, etag: nil, lastModified: nil) else { continue }
        let feed = Feed(name: name, url: url)
        var entries = Merge.apply(parsed, feed: feed, into: [], classifier: classifier, seeding: true).entries
        if evidenceCount > 0, let repo = GitHubRepo(feedURL: url) {
            var advisories: [Advisory] = []
            if case .list(let list, _) = try await github.advisories(repo, etag: nil) { advisories = list }
            for i in entries.indices.prefix(evidenceCount) {
                await enrich(&entries[i], repo: repo, advisories: advisories)
                Assessor.assess(&entries[i], classifier: classifier)
            }
        }
        var routine = 0
        print("== \(name)  (\(entries.count) entries)  \(url.absoluteString)")
        for e in entries {
            if e.severity == .routine && !showAll && e.evidence.isEmpty && e.kind == nil { routine += 1; continue }
            let date = e.published.map { $0.formatted(dateFormat) } ?? "-"
            let sev = e.severity.label.padding(toLength: 9, withPad: " ", startingAt: 0)
            let kind = e.kind == .tagOnly ? " [tag only]" : ""
            let raised = e.baseline != e.severity ? " (feed alone: \(e.baseline.label.lowercased()))" : ""
            print("  \(sev)  \(date)  \(e.title)\(kind)\(raised)")
            for d in e.details.prefix(3) { print("       \(d.keyword) — \(d.source): \(d.snippet)") }
        }
        if routine > 0 { print("  (\(routine) routine)") }
    } catch {
        print("!! \(name): \(error)")
    }
}
print("GitHub requests left in this run's budget: \(github.budget.available())")
