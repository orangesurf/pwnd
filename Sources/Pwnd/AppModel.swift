import AppKit
import Foundation
import PwndCore
import SwiftUI

/// Left-hand column, like mailboxes in an email client.
enum SidebarItem: Hashable {
    case all
    case group(UUID)
    case feed(UUID)
}

/// The filter bar above the release list.
struct EntryFilter: Equatable {
    var unreadOnly = false
    var minimum: Severity = .routine
    var query = ""

    func matches(_ e: Entry) -> Bool {
        if unreadOnly && e.read { return false }
        if e.severity < minimum { return false }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty && !e.title.localizedCaseInsensitiveContains(q) && !e.text.localizedCaseInsensitiveContains(q) {
            return false
        }
        return true
    }
}

/// App state: feeds, entries, settings, and the polling loop.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var groups: [FeedGroup] = []
    /// Sidebar top-level order; see `SidebarLayout`.
    @Published private(set) var order: [UUID] = []
    @Published private(set) var feeds: [Feed] = []
    @Published private(set) var entries: [Entry] = []
    @Published var settings: AppSettings = .defaults {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published private(set) var refreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published var saveError: String?

    @Published private(set) var enriching = false
    /// Increments on reset, so views drop selections that pointed at old feeds.
    @Published private(set) var generation = 0
    @Published private(set) var hasToken = false
    /// The entry whose evidence is being fetched right now, if any. Only this
    /// one shows a spinner; queued entries show a still clock.
    @Published private(set) var fetchingID: String?
    /// A short confirmation shown at the foot of the sidebar, e.g. "Copied 12 feeds".
    @Published private(set) var notice: String?

    private let persistence = Persistence.standard
    private let fetcher = Fetcher()
    private var evidence = GitHubEvidence()
    private var classifier = Classifier(.defaults)
    private var pollTask: Task<Void, Never>?
    let notifier = Notifier()
    /// Advisory lists are re-checked this often per repository.
    static let advisoryInterval: TimeInterval = 6 * 3600

    init() {
        switch persistence.load() {
        case .loaded(let snap):
            groups = snap.groups
            order = snap.order
            feeds = snap.feeds
            entries = snap.entries
            // Version 3 replaced read/unread with New/Old and starts everything
            // in New; earlier installs had history filed as read.
            if snap.version < 3 { for i in entries.indices { entries[i].read = false } }
            settings = snap.settings
            evidence = GitHubEvidence(budget: snap.budget)
        case .missing:
            (groups, feeds, order) = DefaultFeeds.make()
        case .unreadable(let error, let movedTo):
            // Start fresh, but never write over the file we could not read.
            (groups, feeds, order) = DefaultFeeds.make()
            saveError = "Saved state could not be read (\(error)). "
                + (movedTo.map { "It was moved to \($0.path)." } ?? "It was left in place.")
        }
        classifier = Classifier(settings.keywords)
        // Rescore stored releases with this build's rules, so details and
        // coverage saved by an earlier version are brought up to date. Local
        // and quiet: nothing notifies.
        rescore()
        repairFeedURLs()
        evidence.token = Keychain.readToken()
        hasToken = evidence.token != nil
        clampPollInterval()
        queueInitialEvidence()
        notifier.requestAuthorization()
        startPolling()
    }

    // MARK: - Queries

    func feedName(_ id: UUID) -> String { feeds.first { $0.id == id }?.name ?? "?" }

    func entries(in item: SidebarItem?, filter: EntryFilter = EntryFilter()) -> [Entry] {
        let base: [Entry]
        switch item ?? .all {
        case .all: base = entries
        case .group(let gid):
            let members = Set(feeds.filter { $0.groupID == gid }.map(\.id))
            base = entries.filter { members.contains($0.feedID) }
        case .feed(let id): base = entries.filter { $0.feedID == id }
        }
        return base.filter(filter.matches).sorted(by: Entry.newestFirst)
    }

    func unreadCount(_ item: SidebarItem) -> Int { entries(in: item, filter: EntryFilter(unreadOnly: true)).count }

    func feeds(in group: UUID?) -> [Feed] { feeds.filter { $0.groupID == group } }

    var unreadCritical: Int { entries.filter { !$0.read && $0.severity == .critical }.count }

    // MARK: - Polling

    /// Wakes every 30 s and refreshes when the interval has passed. Checking
    /// a deadline instead of sleeping for the whole interval means a changed
    /// interval takes effect without cancelling an in-flight fetch, and a
    /// refresh that came due while the Mac slept runs soon after wake.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.refreshDue {
                    await self.refreshAll()
                } else if !self.enriching, self.budgetRemaining > 0,
                          self.entries.contains(where: { $0.evidenceState.isQueued }) {
                    // Resume a queue that paused on GitHub's rate limit.
                    await self.gatherEvidence()
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var refreshDue: Bool {
        guard let last = lastRefresh else { return true }
        return Date().timeIntervalSince(last) >= Double(max(5, settings.pollMinutes) * 60)
    }

    func refreshNow() {
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        let started = generation
        // After a reset mid-refresh, leave lastRefresh unset so the new
        // default feeds are fetched on the next 30-second wake.
        defer { refreshing = false; lastRefresh = generation == started ? Date() : nil }
        // Sequential on purpose: a dozen requests every 15 minutes is
        // nothing, and it avoids bursting GitHub with parallel fetches.
        for feed in feeds {
            await refresh(feedID: feed.id)
        }
        queueTagRechecks()
        save()
        await gatherEvidence()
    }

    private func refresh(feedID: UUID) async {
        guard let feed = feeds.first(where: { $0.id == feedID }) else { return }
        let result: Result<FetchResult, Error>
        do {
            result = .success(try await fetcher.fetch(feed.url, etag: feed.etag, lastModified: feed.lastModified))
        } catch {
            result = .failure(error)
        }
        // The feed may have been removed while the request was in flight.
        guard let idx = feeds.firstIndex(where: { $0.id == feedID }) else { return }
        feeds[idx].lastChecked = Date()
        switch result {
        case .failure(let error):
            feeds[idx].lastError = String(describing: error)
        case .success(.notModified):
            feeds[idx].lastError = nil
        case .success(.updated(let parsed, let etag, let lastModified)):
            let seeding = !feeds[idx].seeded
            let merged = Merge.apply(parsed, feed: feeds[idx], into: entries, classifier: classifier, seeding: seeding)
            entries = merged.entries
            feeds[idx].etag = etag
            feeds[idx].lastModified = lastModified
            feeds[idx].seeded = true
            feeds[idx].lastError = nil
            if seeding { queueInitialEvidence() }
            let isGitHub = GitHubRepo(feedURL: feeds[idx].url) != nil
            var alerts: [Alert] = []
            // New releases and changed ones (a tag that became a release) get
            // their notes and advisories fetched; seeded history only on request.
            for e in merged.new {
                update(e.id) { e in
                    if isGitHub { e.evidenceState = .pending; Assessor.assess(&e, classifier: classifier) }
                    if consider(&e, previous: nil) { alerts.append(Alert(entry: e, escalated: false)) }
                }
            }
            for (id, previous) in merged.updated {
                update(id) { e in
                    if isGitHub { e.evidenceState = .pending; Assessor.assess(&e, classifier: classifier) }
                    if consider(&e, previous: previous) { alerts.append(Alert(entry: e, escalated: true)) }
                }
            }
            post(alerts)
        }
    }

    // MARK: - Alerts

    struct Alert {
        var entry: Entry
        /// True when an entry already seen rose in severity.
        var escalated: Bool
    }

    private var threshold: Severity { settings.notifyImportant ? .important : .critical }

    func ignoresOldAlerts(_ feedID: UUID) -> Bool {
        feeds.first { $0.id == feedID }?.ignoreOldAlerts ?? settings.ignoreOldAlerts
    }

    private func consider(_ e: inout Entry, previous: Severity?) -> Bool {
        Alerts.evaluate(&e, previous: previous, threshold: threshold, ignoreOld: ignoresOldAlerts(e.feedID))
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }

    /// Posts at most five notifications per batch, then one summary.
    private func post(_ alerts: [Alert]) {
        for a in alerts.prefix(5) {
            notifier.post(entry: a.entry, feedName: feedName(a.entry.feedID), escalated: a.escalated)
        }
        if alerts.count > 5 {
            notifier.postSummary("\(alerts.count - 5) more pwnd alerts", body: "Open pwnd to see them.")
        }
    }

    // MARK: - Evidence

    /// Fetches release notes and advisories for pending entries, then checks
    /// each GitHub repository's advisories when due. Serial, and stops when
    /// the request budget runs out; whatever is left waits for the next poll.
    func gatherEvidence() async {
        guard !enriching else { return }
        enriching = true
        defer { enriching = false; save() }

        // Re-read the queue after each entry, so releases queued while this
        // runs (Check Older Releases) are picked up in the same pass.
        var tried = Set<String>()
        while let next = entries.filter({ $0.evidenceState.isQueued && !tried.contains($0.id) })
            .sorted(by: Entry.newestFirst).first {
            tried.insert(next.id)
            if await enrich(next.id) == .stop { return }
        }
        for feed in feeds {
            guard let repo = GitHubRepo(feedURL: feed.url) else { continue }
            if let last = feed.advisoriesCheckedAt, Date().timeIntervalSince(last) < AppModel.advisoryInterval { continue }
            if await checkAdvisories(feedID: feed.id, repo: repo) == .stop { break }
        }
    }

    /// Queues every stored release of a feed that has not been checked yet,
    /// and starts checking. Used by Check Older Releases and when a feed is
    /// set to alert for older releases.
    /// When each tag-only entry was last queued for a re-check. In memory: a
    /// relaunch re-checks once, which is cheap.
    private var tagRechecked: [String: Date] = [:]

    /// A tag usually gets its GitHub release hours or days later, often
    /// without the feed item changing, so a recent tag-only entry is looked
    /// up again about hourly until its release appears. Older tags are
    /// assumed to stay tags.
    private func queueTagRechecks(now: Date = Date()) {
        for i in entries.indices where entries[i].kind == .tagOnly && !entries[i].evidenceState.isQueued
            && now.timeIntervalSince(entries[i].firstSeen) < 30 * 86_400
            && now.timeIntervalSince(tagRechecked[entries[i].id] ?? .distantPast) > 3_600 {
            guard let feed = feeds.first(where: { $0.id == entries[i].feedID }), GitHubRepo(feedURL: feed.url) != nil
            else { continue }
            tagRechecked[entries[i].id] = now
            entries[i].evidenceState = .pending
        }
    }

    func checkOlderReleases(_ feedID: UUID) {
        guard let feed = feeds.first(where: { $0.id == feedID }), let repo = GitHubRepo(feedURL: feed.url) else { return }
        for i in entries.indices where entries[i].feedID == feedID
            && (entries[i].evidenceState == .notRequested || entries[i].evidenceState == .failed)
            && repo.tag(fromReleaseLink: entries[i].link) != nil {
            entries[i].evidenceState = .pending
            Assessor.assess(&entries[i], classifier: classifier)
        }
        save()
        Task { await gatherEvidence() }
    }

    /// Releases waiting to be checked in a sidebar item.
    func queuedCount(_ item: SidebarItem) -> Int { entries(in: item).filter { $0.evidenceState.isQueued }.count }

    func uncheckedCount(_ feedID: UUID) -> Int {
        entries.filter { $0.feedID == feedID && ($0.evidenceState == .notRequested || $0.evidenceState == .failed) }.count
    }

    var queuedTotal: Int { entries.filter { $0.evidenceState.isQueued }.count }
    var resumesAt: Date? { evidence.resumesAt }

    /// The feed of the entry being fetched, for the sidebar spinner.
    var fetchingFeedID: UUID? { fetchingID.flatMap { id in entries.first { $0.id == id }?.feedID } }

    /// One line on what evidence gathering is doing, or nil when idle.
    func evidenceStatus(_ item: SidebarItem) -> String? {
        let queued = queuedCount(item)
        guard queued > 0 else { return nil }
        if let resume = evidence.resumesAt {
            return "\(queued) release\(queued == 1 ? "" : "s") waiting: GitHub rate limit, resumes at \(resume.formatted(date: .omitted, time: .shortened))"
                + (hasToken ? "" : ". A GitHub token in Settings raises the limit.")
        }
        return "Checking \(queued) release\(queued == 1 ? "" : "s") for notes and advisories…"
    }

    /// Which of a newly added feed's existing releases get evidence fetched:
    /// at least the newest two, plus any published within three days of the
    /// newest (Bitcoin Core ships several maintenance branches minutes
    /// apart), up to six.
    static let initialEvidenceMinimum = 2
    static let initialEvidenceMaximum = 6
    static let initialEvidenceWindow: TimeInterval = 3 * 86400

    /// For each GitHub feed that has never had evidence fetched, queue its
    /// newest releases. Runs when a feed is first fetched, and at launch so
    /// installs from before this existed catch up once. Without it a feed's
    /// latest release is scored on feed text alone until it is superseded.
    private func queueInitialEvidence() {
        for feed in feeds where GitHubRepo(feedURL: feed.url) != nil {
            let mine = entries.indices.filter { entries[$0].feedID == feed.id }
            guard !mine.isEmpty, mine.allSatisfy({ entries[$0].evidenceState == .notRequested }) else { continue }
            let sorted = mine.sorted { Entry.newestFirst(entries[$0], entries[$1]) }.filter { entries[$0].link != nil }
            guard let top = sorted.first.map({ entries[$0].sortDate }) else { continue }
            let chosen = sorted.enumerated().filter { n, i in
                n < AppModel.initialEvidenceMinimum || top.timeIntervalSince(entries[i].sortDate) <= AppModel.initialEvidenceWindow
            }.map(\.element).prefix(AppModel.initialEvidenceMaximum)
            for i in chosen {
                entries[i].evidenceState = .initial
                Assessor.assess(&entries[i], classifier: classifier)
            }
        }
    }

    /// "Fetch More Evidence" in the detail pane: works for seeded history too.
    func fetchEvidence(for id: String) {
        update(id) { $0.evidenceState = .pending; Assessor.assess(&$0, classifier: classifier) }
        Task {
            _ = await enrich(id)
            if let e = entries.first(where: { $0.id == id }), let feed = feeds.first(where: { $0.id == e.feedID }),
               let repo = GitHubRepo(feedURL: feed.url) {
                _ = await checkAdvisories(feedID: feed.id, repo: repo)
            }
            save()
        }
    }

    func canFetchEvidence(_ e: Entry) -> Bool {
        guard let feed = feeds.first(where: { $0.id == e.feedID }), let repo = GitHubRepo(feedURL: feed.url) else { return false }
        return repo.tag(fromReleaseLink: e.link) != nil
    }

    var budgetRemaining: Int { evidence.available }
    var hourlyLimit: Int { evidence.hourlyLimit }

    // MARK: - GitHub token

    /// Checks the token with GitHub, then stores it in the keychain. Returns
    /// a message for the settings pane.
    func setToken(_ raw: String) async -> (ok: Bool, message: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return (false, "Paste a token first.") }
        guard Keychain.isWellFormed(token) else { return (false, "That does not look like a GitHub token.") }
        switch await evidence.check(token: token) {
        case .rejected:
            return (false, "GitHub rejected this token.")
        case .failed(let why):
            return (false, "Could not check the token: \(why)")
        case .valid(let limit, let remaining):
            guard Keychain.saveToken(token) else { return (false, "GitHub accepted it, but saving to the keychain failed.") }
            evidence.token = token
            hasToken = true
            Task { await gatherEvidence() }
            return (true, "Saved. GitHub allows \(limit) requests an hour on this token; \(remaining) left now.")
        }
    }

    func removeToken() {
        Keychain.deleteToken()
        evidence.token = nil
        hasToken = false
        clampPollInterval()
    }

    /// The fastest refresh without a token. Each poll can lead to several
    /// GitHub API requests, and the anonymous allowance is 60 an hour.
    static let minimumPollWithoutToken = 15

    private func clampPollInterval() {
        if !hasToken, settings.pollMinutes < AppModel.minimumPollWithoutToken {
            settings.pollMinutes = AppModel.minimumPollWithoutToken
        }
    }

    private enum Step { case next, stop }

    private func enrich(_ id: String) async -> Step {
        guard let e = entries.first(where: { $0.id == id }),
              let feed = feeds.first(where: { $0.id == e.feedID }),
              let repo = GitHubRepo(feedURL: feed.url),
              let tag = repo.tag(fromReleaseLink: e.link) else {
            update(id) { $0.evidenceState = .notRequested; Assessor.assess(&$0, classifier: classifier) }
            return .next
        }
        let revision = e.revision
        let initial = e.evidenceState == .initial
        fetchingID = id
        defer { fetchingID = nil }
        var items: [EvidenceItem] = []
        var kind: EntryKind = .release
        do {
            switch try await evidence.release(repo, tag: tag) {
            case .tagOnly:
                kind = .tagOnly
            case .release(let body, _):
                if !body.isEmpty {
                    items.append(EvidenceItem(kind: .releaseNotes, source: e.link?.absoluteString ?? tag, title: "Release notes",
                                              text: String(body.prefix(GitHubEvidence.maxText)), fetchedAt: Date()))
                }
            }
            var probe = e
            probe.evidence = items
            if kind == .release, let notesURL = repo.notesFile(in: probe.candidateLinks) {
                let text = try await evidence.notesFile(notesURL)
                items.append(EvidenceItem(kind: .linkedNotes, source: notesURL.absoluteString, title: notesURL.lastPathComponent,
                                          text: String(text.prefix(GitHubEvidence.maxText)), fetchedAt: Date()))
            }
        } catch EvidenceError.budget {
            return .stop                       // stays pending
        } catch {
            update(id) { $0.evidenceState = .failed; Assessor.assess(&$0, classifier: classifier) }
            return .next
        }

        var alerts: [Alert] = []
        update(id) { e in
            // The feed changed the entry while we were fetching: drop the result
            // and leave it pending for the next pass.
            guard e.revision == revision else { return }
            // A first look is not a rise the user could have noticed.
            let previous: Severity? = initial ? nil : e.severity
            e.kind = kind
            e.evidence.removeAll { $0.kind != .advisory }
            e.evidence += items
            e.evidenceState = .done
            Assessor.assess(&e, classifier: classifier)
            if consider(&e, previous: previous) { alerts.append(Alert(entry: e, escalated: !initial)) }
        }
        post(alerts)
        return .next
    }

    private func checkAdvisories(feedID: UUID, repo: GitHubRepo) async -> Step {
        guard let feed = feeds.first(where: { $0.id == feedID }) else { return .next }
        let result: AdvisoryLookup
        do {
            result = try await evidence.advisories(repo, etag: feed.advisoriesETag)
        } catch EvidenceError.budget {
            return .stop
        } catch {
            return .next                       // try again at the next interval
        }
        guard let fi = feeds.firstIndex(where: { $0.id == feedID }) else { return .next }
        feeds[fi].advisoriesCheckedAt = Date()
        guard case .list(let advisories, let etag) = result else { return .next }
        feeds[fi].advisoriesETag = etag

        var alerts: [Alert] = []
        for i in entries.indices where entries[i].feedID == feedID {
            let e = entries[i]
            let tag = repo.tag(fromReleaseLink: e.link)
            let text = ([e.title, e.text] + e.evidence.map(\.text)).joined(separator: "\n")
            let applicable = advisories.filter { $0.applies(toTag: tag, text: text) }
            let known = Set(e.evidence.filter { $0.kind == .advisory }.map(\.source))
            let current = Set(applicable.map(\.ghsa))
            guard known != current else { continue }
            let previous = e.severity
            entries[i].evidence.removeAll { $0.kind == .advisory }
            entries[i].evidence += applicable.map { $0.evidence(at: Date()) }
            Assessor.assess(&entries[i], classifier: classifier)
            if consider(&entries[i], previous: previous) { alerts.append(Alert(entry: entries[i], escalated: true)) }
        }
        post(alerts)
        return .next
    }

    // MARK: - Mutations

    /// Returns an error message, or nil on success.
    func addFeed(_ input: String, group: UUID? = nil) -> String? {
        guard let (name, url) = FeedInput.resolve(input) else {
            return "Enter owner/repo (e.g. bitcoin/bitcoin) or an RSS/Atom URL."
        }
        if feeds.contains(where: { $0.url == url }) { return "Already subscribed to \(name)." }
        let feed = Feed(name: name, url: url, groupID: groups.contains { $0.id == group } ? group : nil)
        feeds.append(feed)
        save()
        Task { await refresh(feedID: feed.id); save() }
        return nil
    }

    /// Choosing to be alerted about older releases also checks them, since
    /// an alert can only come from evidence that has been fetched.
    func setIgnoreOldAlerts(_ id: UUID, _ value: Bool?) {
        guard let i = feeds.firstIndex(where: { $0.id == id }) else { return }
        feeds[i].ignoreOldAlerts = value
        save()
        if !ignoresOldAlerts(id) { checkOlderReleases(id) }
    }

    func removeFeed(_ id: UUID) {
        feeds.removeAll { $0.id == id }
        entries.removeAll { $0.feedID == id }
        save()
    }

    // MARK: - Groups

    /// Creates a group and returns its id. A blank name is ignored.
    @discardableResult
    func addGroup(_ name: String) -> UUID? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        let g = FeedGroup(name: n)
        groups.append(g)
        save()
        return g.id
    }

    func renameGroup(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = n
        save()
    }

    /// Deletes the group only. Its feeds stay subscribed, ungrouped.
    func deleteGroup(_ id: UUID) {
        let members = feeds.filter { $0.groupID == id }.map(\.id)
        var o = topLevel.map(\.id)
        if let j = o.firstIndex(of: id) { o.replaceSubrange(j...j, with: members) }
        order = o
        groups.removeAll { $0.id == id }
        for i in feeds.indices where feeds[i].groupID == id { feeds[i].groupID = nil }
        save()
    }

    func moveFeed(_ feedID: UUID, to group: UUID?) {
        move(feed: feedID, to: group.map { .group($0, before: nil) } ?? .top(before: nil))
    }

    /// Dropping one ungrouped feed on another: file both in a new group.
    /// Returns the group so the caller can offer to name it.
    func groupTogether(_ dragged: UUID, onto target: UUID) -> FeedGroup? {
        let slot = topLevel.map(\.id)
        guard dragged != target, let gid = addGroup("New Group") else { return nil }
        var o = slot.filter { $0 != dragged }
        if let j = o.firstIndex(of: target) { o[j] = gid } else { o.append(gid) }
        order = o
        move(feed: target, to: .group(gid, before: nil))
        move(feed: dragged, to: .group(gid, before: nil))
        return groups.first { $0.id == gid }
    }

    // MARK: - Sharing the feed list

    var feedList: FeedList { FeedList(order: order, groups: groups, feeds: feeds) }

    func copyFeedList() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(feedList.opml(), forType: .string)
        show("Copied \(feeds.count) feed\(feeds.count == 1 ? "" : "s") as OPML")
    }

    /// Adds the list's feeds that are not already subscribed, in a new
    /// Imported group.
    func importAdding(_ list: FeedList) {
        let added = list.missing(from: feeds).count
        let s = list.add(to: FeedList.State(groups: groups, order: order, feeds: feeds))
        (groups, order, feeds) = (s.groups, s.order, s.feeds)
        save()
        show(added == 0 ? "Nothing new to add" : "Added \(added) feed\(added == 1 ? "" : "s") in \(groups.last?.name ?? "Imported")")
        if added > 0 { refreshNow() }
    }

    /// Makes the list the subscription list. Feeds kept keep their releases.
    func importReplacing(_ list: FeedList) {
        let (s, removed) = list.replace(FeedList.State(groups: groups, order: order, feeds: feeds))
        (groups, order, feeds) = (s.groups, s.order, s.feeds)
        entries.removeAll { removed.contains($0.feedID) }
        generation += 1
        save()
        show("Replaced with \(feeds.count) feed\(feeds.count == 1 ? "" : "s")")
        refreshNow()
    }

    private func show(_ message: String) {
        notice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if notice == message { notice = nil }
        }
    }

    // MARK: - Sidebar order

    var topLevel: [TopItem] { SidebarLayout.topLevel(order: order, groups: groups, feeds: feeds) }

    func move(feed id: UUID, to dest: SidebarLayout.Destination) {
        (order, feeds) = SidebarLayout.move(feed: id, to: dest, order: order, groups: groups, feeds: feeds)
        save()
    }

    func move(group id: UUID, before: UUID?) {
        order = SidebarLayout.move(group: id, before: before, order: order, groups: groups, feeds: feeds)
        save()
    }

    func groupName(_ id: UUID) -> String { groups.first { $0.id == id }?.name ?? "?" }

    func setRead(_ ids: Set<String>, _ read: Bool) {
        var changed = false
        for i in entries.indices where ids.contains(entries[i].id) && entries[i].read != read {
            entries[i].read = read
            changed = true
        }
        if changed { save() }
    }

    func markAllRead(in item: SidebarItem?) {
        setRead(Set(entries(in: item).map(\.id)), true)
    }

    private func settingsChanged(from old: AppSettings) {
        if settings.keywords != old.keywords {
            classifier = Classifier(settings.keywords)
            let changed = rescore()
            show(changed == 0 ? "Rescored: no release changed level"
                 : "Rescored: \(changed) release\(changed == 1 ? "" : "s") changed level")
        }
        save()
    }

    /// A GitLab project page added before pwnd understood GitLab was stored
    /// as the feed URL itself and fails to parse. Point it at the project's
    /// releases feed; it then seeds quietly like a newly added feed.
    private func repairFeedURLs() {
        for i in feeds.indices {
            guard let host = feeds[i].url.host?.lowercased(), host == "gitlab.com" || host == "www.gitlab.com",
                  let fixed = FeedInput.resolve(feeds[i].url.absoluteString), fixed.url != feeds[i].url,
                  !feeds.contains(where: { $0.url == fixed.url }) else { continue }
            feeds[i].url = fixed.url
            if feeds[i].name == host { feeds[i].name = fixed.name }
            feeds[i].etag = nil
            feeds[i].lastModified = nil
            feeds[i].lastError = nil
            feeds[i].seeded = false
        }
    }

    /// Re-applies the keyword lists to every stored entry. Read state is
    /// kept, and nothing notifies: this is a policy change, not news. The new
    /// levels count as seen so a later poll does not alert on them. Returns
    /// how many releases changed level.
    @discardableResult
    private func rescore() -> Int {
        var changed = 0
        for i in entries.indices {
            let before = entries[i].severity
            Assessor.assess(&entries[i], classifier: classifier)
            entries[i].notifiedSeverity = max(entries[i].notifiedSeverity, entries[i].severity)
            if entries[i].severity != before { changed += 1 }
        }
        return changed
    }

    // MARK: - Reset

    /// Deletes all local data and starts again with the default feeds and
    /// settings, as on first launch. The GitHub request budget is kept: it
    /// records real requests this machine made in the last hour, and clearing
    /// it could push a re-fetch over GitHub's limit.
    func reset() {
        // In-flight fetches look their feed and entry up by ID when they
        // finish; the new defaults have new IDs, so stale results are dropped.
        let dir = persistence.url.deletingLastPathComponent()
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("state") && f.pathExtension == "json" {
                try? FileManager.default.removeItem(at: f)
            }
        }
        for key in ["filter.unreadOnly", "filter.minimum"] { UserDefaults.standard.removeObject(forKey: key) }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        notifier.clearDelivered()
        removeToken()

        (groups, feeds, order) = DefaultFeeds.make()
        entries = []
        settings = .defaults
        classifier = Classifier(settings.keywords)
        saveError = nil
        lastRefresh = nil
        generation += 1
        save()
        refreshNow()
    }

    func save() {
        do {
            try persistence.save(Snapshot(groups: groups, order: order, feeds: feeds, entries: entries, settings: settings, budget: evidence.budget))
            saveError = nil
        } catch {
            saveError = "Could not save state: \(error.localizedDescription)"
        }
    }
}
