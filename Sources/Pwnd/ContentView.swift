import AppKit
import PwndCore
import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .critical: return .red
        case .important: return .orange
        case .routine: return .secondary
        }
    }
}

/// Severity as a soft tinted label with its own icon: an octagon for
/// critical, a triangle for important, so the two differ by shape as well as
/// colour. Routine is left out of list rows (`compact`), where it would be on
/// most rows and say nothing.
struct SeverityBadge: View {
    let severity: Severity
    var compact = false

    var body: some View {
        if !(compact && severity == .routine) {
            HStack(spacing: compact ? 2 : 3) {
                Image(systemName: icon).font(.system(size: compact ? 7 : 9, weight: .bold))
                Text(severity.label.capitalized).font(.system(size: compact ? 9.5 : 11, weight: .semibold))
            }
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .foregroundStyle(severity.color)
            .background(severity.color.opacity(severity == .routine ? 0.12 : 0.16), in: Capsule())
        }
    }

    private var icon: String {
        switch severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .important: return "exclamationmark.triangle.fill"
        case .routine: return "checkmark.circle"
        }
    }
}

/// Rounded panel used for the Why and Evidence sections.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var sidebar: SidebarItem? = .all
    @State private var selection: Set<String> = []
    @State private var showingAdd = false
    @State private var query = ""

    /// The group a new feed goes into by default: the selected group, or the
    /// group of the selected feed.
    private var currentGroup: UUID? {
        switch sidebar {
        case .group(let g): return g
        case .feed(let f): return model.feeds.first { $0.id == f }?.groupID
        default: return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $sidebar, showingAdd: $showingAdd)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            EntryList(sidebar: $sidebar, selection: $selection, query: query)
                .navigationSplitViewColumnWidth(min: 320, ideal: 400)
        } detail: {
            Group {
                if selection.count == 1, let id = selection.first, let entry = model.entries.first(where: { $0.id == id }) {
                    EntryDetail(entry: entry)
                } else if selection.count > 1 {
                    MultiSelection(ids: selection)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled").font(.system(size: 36, weight: .light))
                        Text("Select a release")
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            // All toolbar buttons live on the detail column, in one group, so
            // collapsing the sidebar moves them together instead of
            // re-laying out items owned by different columns.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { openWindow(id: "servers") } label: { Image(systemName: "server.rack") }
                        .help("Servers")
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Settings")
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search releases")
        .sheet(isPresented: $showingAdd) { AddFeedSheet(group: currentGroup) }
        // A server deleted in the Servers window can't stay selected here.
        .onChange(of: model.servers.map(\.id)) { _, ids in
            if case .server(let s) = sidebar, !ids.contains(s) { sidebar = .all; selection = [] }
        }
        .onChange(of: model.generation) { _, _ in
            sidebar = .all
            selection = []
        }
    }
}

/// What follows the pointer while a feed is dragged: the whole entry as a
/// capsule, not just its text.
struct DragLozenge: View {
    let feed: Feed
    let unread: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.up.forward").foregroundStyle(Color.accentColor)
            Text(feed.name).lineLimit(1)
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .fixedSize()
    }
}

/// One-field sheet for naming a group.
struct NameSheet: View {
    let title: String
    let initial: String
    let action: String
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Name, e.g. Lightning", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(done)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action, action: done).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = initial }
    }

    private func done() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        commit(name)
        dismiss()
    }
}

struct EntryList: View {
    @EnvironmentObject private var model: AppModel
    @Binding var sidebar: SidebarItem?
    @Binding var selection: Set<String>
    let query: String
    private var item: SidebarItem? { sidebar }

    // Remembered between launches, like a mail client's filter.
    @AppStorage("filter.minimum") private var minimum = Severity.routine.rawValue

    private var filter: EntryFilter {
        // A hidden severity filter must not keep filtering.
        EntryFilter(minimum: model.settings.showSeverity ? Severity(rawValue: minimum) ?? .routine : .routine, query: query)
    }

    private var singleFeed: Bool { if case .feed = item ?? .all { return true } else { return false } }

    var body: some View {
        let list = model.entries(in: item, filter: filter)
        let fresh = list.filter { !$0.read }
        let old = list.filter(\.read)
        // New and Old are two fixed panes that scroll on their own. The top
        // pane runs down to the dividing line; the button sits on the line.
        return VStack(spacing: 0) {
            pane(fresh, label: "New", empty: list.isEmpty ? "" : "No new releases", old: false)
            SplitLine(newCount: fresh.count) {
                withAnimation(.snappy) { model.setRead(Set(fresh.map(\.id)), true) }
            }
            .zIndex(1)
            .onDrop(of: [.plainText], isTargeted: nil) { providers in receive(providers, toOld: true) }
            pane(old, label: "Old", empty: list.isEmpty ? "" : "Drag releases here", old: true)
        }
        .animation(.snappy(duration: 0.25), value: list.map { "\($0.id)\($0.read)" })
        .safeAreaInset(edge: .top, spacing: 0) { ListBar(sidebar: $sidebar) }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .overlay {
            if list.isEmpty {
                Text(model.feeds.allSatisfy { !$0.seeded } ? "Fetching feeds…" : emptyText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Selection within one pane: ⌘-click and ⇧-click extend it there, and
    /// selecting in one pane clears the other.
    private func paneSelection(_ ids: Set<String>) -> Binding<Set<String>> {
        Binding(get: { selection.intersection(ids) }, set: { selection = $0 })
    }

    private func pane(_ entries: [Entry], label: String, empty: String, old: Bool) -> some View {
        let ids = Set(entries.map(\.id))
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: label).padding(.horizontal, 16).padding(.top, old ? 14 : 8).padding(.bottom, 2)
            List(selection: paneSelection(ids)) {
                ForEach(entries) { row($0, paneSelection: selection.intersection(ids)) }
                    // List's own insertion drops: anything dropped among these rows joins this pane.
                    .onInsert(of: [.plainText]) { _, providers in _ = receive(providers, toOld: old) }
            }
            .background(AlwaysShowScrollers().allowsHitTesting(false))
            .overlay {
                if entries.isEmpty && !empty.isEmpty {
                    Text(empty).font(.callout).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onDrop(of: [.plainText], isTargeted: nil) { providers in receive(providers, toOld: old) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ e: Entry, paneSelection: Set<String>) -> some View {
        EntryRow(entry: e, showFeed: !singleFeed)
            .tag(e.id)
            // List drags every selected row in the pane, one provider each.
            .itemProvider { NSItemProvider(object: ("pwnd-entry:" + e.id) as NSString) }
            .contextMenu {
                let targets = paneSelection.contains(e.id) ? paneSelection : [e.id]
                let n = targets.count
                Button(e.read ? "Move \(n > 1 ? "\(n) " : "")to New" : "Move \(n > 1 ? "\(n) " : "")to Old") {
                    withAnimation(.snappy) { model.setRead(targets, !e.read) }
                }
                if n == 1, let link = e.link { Button("Open in Browser") { NSWorkspace.shared.open(link) } }
            }
    }

    /// Loads dropped release IDs and files them in New or Old.
    private func receive(_ providers: [NSItemProvider], toOld: Bool) -> Bool {
        let usable = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !usable.isEmpty else { return false }
        for p in usable {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String, s.hasPrefix("pwnd-entry:") else { return }
                let id = String(s.dropFirst("pwnd-entry:".count))
                DispatchQueue.main.async { withAnimation(.snappy) { model.setRead([id], toOld) } }
            }
        }
        return true
    }

    /// The window title names what is selected, as Mail names the mailbox.
    private var title: String {
        switch item ?? .all {
        case .all: return "All Feeds"
        case .group(let g): return model.groupName(g)
        case .feed(let f): return model.feedName(f)
        case .server(let s): return model.serverName(s)
        }
    }

    private var subtitle: String {
        let all = model.entries(in: item)
        let fresh = all.filter { !$0.read }.count
        var parts = ["\(fresh) new", "\(all.count - fresh) old"]
        if case .feed(let f) = item ?? .all, let feed = model.feeds.first(where: { $0.id == f }) {
            if feed.lastError != nil { parts.append("last fetch failed") }
            else if let t = feed.lastChecked { parts.append("checked \(t.formatted(date: .omitted, time: .shortened))") }
        }
        return parts.joined(separator: " · ")
    }

    private var emptyText: String {
        filter == EntryFilter() ? "Nothing here" : "No releases match"
    }

    // MARK: - Controls row

    /// One row above the list: what to show, and the selected item's actions.
    struct ListBar: View {
        @EnvironmentObject private var model: AppModel
        @Binding var sidebar: SidebarItem?
        @AppStorage("filter.minimum") private var minimum = Severity.routine.rawValue
        @State private var renaming: FeedGroup?
        @State private var confirmUnsubscribe: Feed?
        @Environment(\.openWindow) private var openWindow

        private var severityMenu: some View {
            Menu {
                Picker("Severity", selection: $minimum) {
                    Text("Any severity").tag(Severity.routine.rawValue)
                    Text("Important and up").tag(Severity.important.rawValue)
                    Text("Critical only").tag(Severity.critical.rawValue)
                }
                .pickerStyle(.inline)
            } label: {
                Label(severityLabel, systemImage: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(minimum == 0 ? Color.secondary : Color.accentColor)
        }

        var body: some View {
            HStack(spacing: 10) {
                if model.settings.showSeverity { severityMenu }

                Spacer()

                if case .feed(let f) = sidebar ?? .all, let feed = model.feeds.first(where: { $0.id == f }) {
                    if GitHubRepo(feedURL: feed.url) != nil { alertsMenu(feed) }
                    feedMenu(feed)
                } else if case .group(let gid) = sidebar ?? .all, let g = model.groups.first(where: { $0.id == gid }) {
                    groupMenu(g)
                } else if case .server(let sid) = sidebar ?? .all {
                    Button {
                        model.focusServer = sid
                        openWindow(id: "servers")
                    } label: {
                        Label("Open in Servers", systemImage: "server.rack")
                    }
                    .help("Edit this server and its software")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .sheet(item: $renaming) { g in
                NameSheet(title: "Rename Group", initial: g.name, action: "Save") { model.renameGroup(g.id, to: $0) }
            }
            .confirmationDialog("Unsubscribe from \(confirmUnsubscribe?.name ?? "")?",
                                isPresented: Binding(get: { confirmUnsubscribe != nil }, set: { if !$0 { confirmUnsubscribe = nil } }),
                                presenting: confirmUnsubscribe) { feed in
                Button("Unsubscribe", role: .destructive) {
                    sidebar = .all
                    withAnimation(.snappy) { model.removeFeed(feed.id) }
                }
            } message: { _ in Text("Its stored releases are removed too.") }
        }

        private var severityLabel: String {
            switch minimum {
            case Severity.important.rawValue: return "Important+"
            case Severity.critical.rawValue: return "Critical"
            default: return "Any"
            }
        }

        /// Bell shows the current choice: filled when older releases alert.
        private func alertsMenu(_ feed: Feed) -> some View {
            let alerting = !model.ignoresOldAlerts(feed.id)
            let unchecked = model.uncheckedCount(feed.id)
            return Menu {
                Section("Alerts for releases from before this feed was added") {
                    Toggle("Default (\(model.settings.ignoreOldAlerts ? "no alerts" : "alert"))", isOn: Binding(
                        get: { feed.ignoreOldAlerts == nil }, set: { _ in model.setIgnoreOldAlerts(feed.id, nil) }))
                    Toggle("No alerts", isOn: Binding(
                        get: { feed.ignoreOldAlerts == true }, set: { _ in model.setIgnoreOldAlerts(feed.id, true) }))
                    Toggle("Alert, and check them", isOn: Binding(
                        get: { feed.ignoreOldAlerts == false }, set: { _ in model.setIgnoreOldAlerts(feed.id, false) }))
                }
                Divider()
                Button(unchecked == 0 ? "All Releases Checked" : "Check \(unchecked) Older Release\(unchecked == 1 ? "" : "s")") {
                    model.checkOlderReleases(feed.id)
                }
                .disabled(unchecked == 0)
            } label: {
                Image(systemName: alerting ? "bell.fill" : "bell.slash")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(alerting ? "Older releases can alert" : "Older releases do not alert")
        }

        private func feedMenu(_ feed: Feed) -> some View {
            Menu {
                Menu("Move to Group") {
                    ForEach(model.groups) { g in
                        Button(g.name) { withAnimation(.snappy) { model.moveFeed(feed.id, to: g.id) } }
                            .disabled(feed.groupID == g.id)
                    }
                    if !model.groups.isEmpty { Divider() }
                    Button("No Group") { withAnimation(.snappy) { model.moveFeed(feed.id, to: nil) } }
                        .disabled(feed.groupID == nil)
                }
                Button("Copy Feed URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(feed.url.absoluteString, forType: .string)
                }
                if let err = feed.lastError {
                    Divider()
                    Text("Last fetch failed: \(err)")
                }
                Divider()
                Button("Unsubscribe…", role: .destructive) { confirmUnsubscribe = feed }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Feed actions")
        }

        private func groupMenu(_ g: FeedGroup) -> some View {
            Menu {
                Button("Rename…") { renaming = g }
                Divider()
                Button("Delete Group") {
                    sidebar = .all
                    withAnimation(.snappy) { model.deleteGroup(g.id) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Group actions")
        }
    }
}

/// One release in the list: date, title, severity, and the arrow that moves
/// it between New and Old. Date and severity sit in fixed-width columns so
/// they line up from row to row.
struct EntryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: Entry
    let showFeed: Bool

    /// Wide enough for the small "Important" chip.
    static let severityWidth: CGFloat = 70
    static let dateWidth: CGFloat = 44

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.sortDate.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: EntryRow.dateWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.body.weight(entry.read ? .regular : .semibold))
                    .foregroundStyle(entry.kind == .tagOnly ? Color.secondary : Color.primary)
                    .lineLimit(2)
                if showFeed || entry.kind == .tagOnly || (model.settings.showSeverity && entry.escalatedFrom != nil)
                    || entry.evidenceState.isQueued {
                    HStack(spacing: 6) {
                        EntryMarkers(entry: entry)
                        if showFeed {
                            Text(model.feedName(entry.feedID)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        QueueMark(entry: entry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.settings.showSeverity {
                SeverityBadge(severity: entry.severity, compact: true)
                    .frame(width: EntryRow.severityWidth, alignment: .leading)
            }
            MoveArrow(old: entry.read) {
                withAnimation(.snappy) { model.setRead([entry.id], !entry.read) }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .padding(.vertical, 4)
    }
}

/// At the start of a row: a down arrow moves a new release to Old, an up
/// arrow brings an old one back to New.
struct MoveArrow: View {
    let old: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: old ? "arrow.up" : "arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(old ? Color.secondary.opacity(0.6) : Color.accentColor)
                .frame(width: 18, height: 18)
                .background(Circle().fill(old ? Color.clear : Color.accentColor.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(old ? "Move to New" : "Move to Old")
    }
}

/// Small capitals heading for the New and Old parts of the list.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.4).foregroundStyle(.tertiary)
    }
}

/// The line between New and Old. With new releases it carries a button that
/// moves them all to Old: the first click says what it will do, a second
/// click within four seconds does it. With none, it is a plain line.
struct SplitLine: View {
    let newCount: Int
    let moveAll: () -> Void
    @State private var armed = false

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .overlay {
                if newCount > 0 {
                    HStack(spacing: 8) {
                        Button(action: tap) {
                            Image(systemName: armed ? "checkmark" : "arrow.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(armed ? Color.orange : Color.accentColor))
                                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help("Move all \(newCount) new release\(newCount == 1 ? "" : "s") to Old")
                        if armed {
                            Text("Moves \(newCount) to Old · click again")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(.regularMaterial))
                                .transition(.opacity)
                        }
                    }
                    // Keep the button centred while the hint appears beside it.
                    .offset(x: armed ? 70 : 0)
                }
            }
            .frame(height: 1)
            .onChange(of: newCount) { _, _ in armed = false }
    }

    private func tap() {
        if armed {
            armed = false
            moveAll()
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { armed = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.2)) { armed = false }
        }
    }
}

/// Several releases selected in one pane.
struct MultiSelection: View {
    @EnvironmentObject private var model: AppModel
    let ids: Set<String>

    var body: some View {
        let selected = model.entries.filter { ids.contains($0.id) }
        let allOld = selected.allSatisfy(\.read)
        VStack(spacing: 12) {
            Text("\(selected.count) releases selected").font(.title3.weight(.semibold))
            Button(allOld ? "Move \(selected.count) to New" : "Move \(selected.count) to Old") {
                withAnimation(.snappy) { model.setRead(ids, !allOld) }
            }
            .controlSize(.large)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Makes the enclosing scroll view use always-visible scroll bars, which
/// still hide when there is nothing to scroll. SwiftUI's scrollIndicators
/// follows the system "show scroll bars when scrolling" setting on macOS.
///
/// The probe view is a real AppKit view laid over the list's area, so it must
/// be invisible to the mouse and to drags: otherwise AppKit delivers clicks
/// and drag sessions to it instead of to the SwiftUI rows, and dragging a
/// feed or release silently does nothing.
struct AlwaysShowScrollers: NSViewRepresentable {
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }

    func makeNSView(context: Context) -> NSView {
        let v = Probe()
        v.unregisterDraggedTypes()
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            var node: NSView? = view
            while let n = node {
                if let scroll = Self.find(in: n) {
                    scroll.scrollerStyle = .legacy
                    scroll.hasVerticalScroller = true
                    scroll.autohidesScrollers = true
                    return
                }
                node = n.superview
            }
        }
    }

    private static func find(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = find(in: sub) { return s } }
        return nil
    }
}

struct EntryDetail: View {
    @EnvironmentObject private var model: AppModel
    let entry: Entry
    @State private var jump: ReleaseBody.Jump?
    @State private var showingDetails = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ReleaseHeader(entry: entry)
                    if model.settings.showSeverity, !entry.details.isEmpty {
                        WhyBox(entry: entry, onJump: { jump = $0 }, onDetails: { showingDetails = true })
                    }
                    ReleaseBody(entry: entry, jump: $jump, proxy: proxy)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AlwaysShowScrollers().allowsHitTesting(false))
            }
        }
        .sheet(isPresented: $showingDetails) { DetailsSheet(entry: entry) }
        .id(entry.id)
    }
}

/// Severity, title, and a small table of facts, with the release link at the
/// top right. The repository is the window title, so it is not repeated.
struct ReleaseHeader: View {
    @EnvironmentObject private var model: AppModel
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if model.settings.showSeverity { SeverityBadge(severity: entry.severity) }
                        EntryMarkers(entry: entry, long: true)
                    }
                    Text(entry.title).font(.system(size: 22, weight: .bold)).textSelection(.enabled)
                }
                Spacer()
                if let link = entry.link {
                    Button { NSWorkspace.shared.open(link) } label: {
                        Image(systemName: "arrow.up.right").font(.body.weight(.semibold)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Open \(link.absoluteString)")
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                if let d = entry.published { fact("Released", d.formatted(date: .abbreviated, time: .shortened)) }
                if let a = entry.author { fact("Author", a) }
                if let tag = tag { fact("Tag", tag) }
                if let status = evidenceStatus { fact("Checks", status) }
            }
            .font(.callout)
        }
    }

    private var tag: String? {
        guard let feed = model.feeds.first(where: { $0.id == entry.feedID }), let repo = GitHubRepo(feedURL: feed.url) else { return nil }
        return repo.tag(fromReleaseLink: entry.link)
    }

    /// Only when something is pending or failed; otherwise the Why box and
    /// the Details sheet cover it.
    private var evidenceStatus: String? {
        if model.fetchingID == entry.id { return "fetching release notes and advisories…" }
        switch entry.evidenceState {
        case .pending, .initial:
            if let r = model.resumesAt { return "queued, resumes \(r.formatted(date: .omitted, time: .shortened))" }
            return "queued"
        case .failed: return "could not fetch release notes"
        default: return nil
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// One line per source of matches, each a link to that place in the notes,
/// plus a button for the full detail.
struct WhyBox: View {
    let entry: Entry
    let onJump: (ReleaseBody.Jump) -> Void
    let onDetails: () -> Void

    struct Line: Identifiable {
        var id: String { source }
        let source: String
        let terms: [String]
        let critical: Bool
    }

    private var lines: [Line] {
        var order: [String] = []
        var terms: [String: [String]] = [:]
        var critical: [String: Bool] = [:]
        for d in entry.details {
            if terms[d.source] == nil { order.append(d.source) }
            let t = d.matched ?? d.keyword
            if !(terms[d.source] ?? []).contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
                terms[d.source, default: []].append(t)
            }
            if d.tier == "critical" || d.tier == "advisory" { critical[d.source] = true }
        }
        return order.map { Line(source: $0, terms: terms[$0] ?? [], critical: critical[$0] ?? false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.severity == .routine ? "Matches" : "Why it's \(entry.severity.label.lowercased())")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Details", action: onDetails).buttonStyle(.link).font(.callout)
            }
            ForEach(lines) { line in
                Button {
                    if line.source != "GitHub advisory", let first = line.terms.first {
                        onJump(ReleaseBody.Jump(source: line.source, term: first))
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.terms.prefix(3).joined(separator: ", ")
                             + (line.terms.count > 3 ? " +\(line.terms.count - 3)" : ""))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(line.critical || entry.severity == .critical ? Color.red : Color.orange)
                        Text("in \(line.source)").font(.callout).foregroundStyle(.secondary)
                        if line.source != "GitHub advisory" && line.source != "title" {
                            Image(systemName: "arrow.down.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(line.source == "title" ? "In the release title" : "Show in the text below")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
    }
}

/// Everything behind the score, in a large sheet: each match with its rule,
/// list and context, and each evidence source with its state.
struct DetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(entry.title).font(.title3.bold())
                SeverityBadge(severity: entry.severity)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Matches").font(.headline)
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow {
                                Text("Matched"); Text("Rule"); Text("List"); Text("Where"); Text("Context")
                            }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Divider().gridCellUnsizedAxes(.horizontal)
                            ForEach(entry.details, id: \.self) { d in
                                GridRow {
                                    Text(d.matched ?? d.keyword).font(.system(.callout, design: .monospaced).weight(.semibold))
                                    Text(d.keyword).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(d.tier ?? "—").font(.caption).foregroundStyle(.secondary)
                                    Text(d.source).font(.caption).foregroundStyle(.secondary)
                                    Text(d.snippet).font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .textSelection(.enabled)
                            }
                        }
                        if entry.baseline != entry.severity {
                            Text("The feed text alone scored \(entry.baseline.label.lowercased()).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    EvidenceCard(entry: entry)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 680)
    }
}

/// Each evidence source and its live state.
struct EvidenceCard: View {
    @EnvironmentObject private var model: AppModel
    let entry: Entry

    private var feed: Feed? { model.feeds.first { $0.id == entry.feedID } }
    private var isGitHub: Bool { feed.flatMap { GitHubRepo(feedURL: $0.url) } != nil }

    var body: some View {
        Card(title: "Evidence") {
            VStack(alignment: .leading, spacing: 7) {
                row("Feed text", state: "checked", done: true, link: nil)
                if isGitHub {
                    row("GitHub release", state: releaseState, done: entry.evidenceState == .done || entry.kind != nil,
                        link: entry.link)
                    let linked = entry.evidence.first { $0.kind == .linkedNotes }
                    row(linked.map { "Notes · \($0.title)" } ?? "Linked notes",
                        state: linked != nil ? "checked" : (entry.evidenceState == .done ? "none linked" : fetchState),
                        done: linked != nil || entry.evidenceState == .done, link: linked.flatMap { URL(string: $0.source) })
                    let advisories = entry.evidence.filter { $0.kind == .advisory }
                    row("Advisories", state: advisoryState(advisories.count), done: feed?.advisoriesCheckedAt != nil, link: nil)
                    ForEach(advisories, id: \.self) { a in
                        HStack(spacing: 6) {
                            Text(a.source).font(.system(.caption, design: .monospaced))
                            Text(a.rating ?? "unrated").font(.caption.weight(.semibold)).foregroundStyle(.red)
                            Text(a.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.leading, 22)
                    }
                }
            }
            if !entry.coverage.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.coverage, id: \.self) { Text($0) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if model.canFetchEvidence(entry), !entry.evidenceState.isQueued {
                Button(entry.evidenceState == .done ? "Fetch Again" : "Fetch Evidence") { model.fetchEvidence(for: entry.id) }
                    .disabled(model.budgetRemaining == 0)
            }
        }
    }

    private var fetchState: String {
        if model.fetchingID == entry.id { return "fetching…" }
        switch entry.evidenceState {
        case .pending, .initial:
            if let r = model.resumesAt { return "queued · resumes \(r.formatted(date: .omitted, time: .shortened))" }
            return "queued"
        case .failed: return "failed"
        case .notRequested: return "not fetched"
        case .done: return "checked"
        }
    }

    private var releaseState: String {
        if entry.kind == .tagOnly { return "tag only" }
        if entry.evidence.contains(where: { $0.kind == .releaseNotes }) { return "checked" }
        return entry.evidenceState == .done ? "no notes" : fetchState
    }

    private func advisoryState(_ n: Int) -> String {
        guard feed?.advisoriesCheckedAt != nil else { return "not checked yet" }
        return n == 0 ? "none apply" : "\(n) apply"
    }

    private func row(_ name: String, state: String, done: Bool, link: URL?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .frame(width: 14)
            Text(name).font(.callout)
            if let link {
                Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "arrow.up.right").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(link.absoluteString)
            }
            Spacer()
            Text(state).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A spinner while releases in this sidebar item are being checked, or a
/// clock while they wait for GitHub's rate limit.
struct CheckingIndicator: View {
    @EnvironmentObject private var model: AppModel
    let item: SidebarItem

    var body: some View {
        if case .feed(let id) = item, model.fetchingFeedID == id {
            ProgressView().controlSize(.mini).help("Fetching release notes and advisories")
        }
    }
}

/// Spinner on the release being fetched now; a still clock on queued ones.
struct QueueMark: View {
    @EnvironmentObject private var model: AppModel
    let entry: Entry

    var body: some View {
        if model.fetchingID == entry.id {
            ProgressView().controlSize(.mini).help("Fetching release notes and advisories")
        } else if entry.evidenceState.isQueued {
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                .help("Queued for release notes and advisories")
        }
    }
}

/// Evidence-gathering state, shown only while releases are queued: one line,
/// plus a token link when GitHub's anonymous limit is what is holding it up.
struct EvidenceStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let queued = model.queuedTotal
        if queued > 0 || model.fetchingID != nil {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if model.fetchingID != nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "clock")
                    }
                    Text(headline(queued)).lineLimit(1)
                }
                if model.resumesAt != nil, !model.hasToken {
                    SettingsLink { Text("Add a GitHub token to go faster") }.buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(model.budgetRemaining) of \(model.hourlyLimit) GitHub requests left this hour")
        }
    }

    private func headline(_ queued: Int) -> String {
        if model.fetchingID != nil { return "Checking \(queued) release\(queued == 1 ? "" : "s")…" }
        if let r = model.resumesAt { return "\(queued) queued · resumes \(r.formatted(date: .omitted, time: .shortened))" }
        return "\(queued) queued"
    }
}

/// "owner/repo" with the owner dimmed, so the repository name reads first.
/// Other feeds (a blog's host name) show as they are.
struct FeedName: View {
    let name: String

    var body: some View {
        if let slash = name.firstIndex(of: "/") {
            (Text(name[..<slash] + "/").foregroundColor(.secondary) + Text(name[name.index(after: slash)...]))
                .lineLimit(1)
                .truncationMode(.head)
                .help(name)
        } else {
            Text(name).lineLimit(1)
        }
    }
}

/// Small labels after the severity badge: tag-only entries and releases
/// whose severity rose after they were first seen.
struct EntryMarkers: View {
    @EnvironmentObject private var model: AppModel
    let entry: Entry
    var long = false

    var body: some View {
        HStack(spacing: 6) {
            if entry.kind == .tagOnly {
                marker(long ? "Tag only" : nil, "tag", .secondary, help: "A tag with no GitHub release yet")
            }
            if model.settings.showSeverity, let from = entry.escalatedFrom {
                marker(long ? "Raised from \(from.label.lowercased())" : nil, "arrow.up", entry.severity.color,
                       help: "Raised from \(from.label.lowercased()) after it was first seen")
            }
        }
    }

    /// Icon only in list rows; icon and words in the detail pane.
    @ViewBuilder private func marker(_ text: String?, _ icon: String, _ color: Color, help: String) -> some View {
        Group {
            if let text { Label(text, systemImage: icon) } else { Image(systemName: icon) }
        }
        .font(long ? .caption.weight(.medium) : .caption2.weight(.medium))
        .foregroundStyle(color)
        .help(help)
    }
}

struct AddFeedSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var error: String?
    @State var group: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Feed").font(.headline)
            TextField("owner/repo, GitHub URL, or RSS/Atom URL", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onSubmit(add)
            if !model.groups.isEmpty {
                Picker("Group", selection: $group) {
                    Text("No group").tag(UUID?.none)
                    ForEach(model.groups) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .frame(width: 380)
            }
            Text("A GitHub repository subscribes to its releases feed. Existing releases are added as read, with no alerts.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 380, alignment: .leading)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func add() {
        if let e = model.addFeed(input, group: group) { error = e } else { dismiss() }
    }
}
