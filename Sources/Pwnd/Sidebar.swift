import AppKit
import PwndCore
import SwiftUI

/// The left column: All Feeds, then groups and ungrouped feeds in the user's
/// order. Groups are thin rounded boxes with a small label at the top left.
///
/// Drag anything to reorder. Dropping a feed on the top or bottom third of a
/// row inserts it there; on the middle of a row it joins that feed's group,
/// or makes a new group with an ungrouped feed. Dropping on a group's label
/// files the feed in that group. The space below the last item takes a feed
/// out of its group.
struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: SidebarItem?
    @Binding var showingAdd: Bool
    @State private var naming: GroupNaming?
    @State private var dragging: DragItem?
    @State private var spot: DropSpot?
    @State private var landed: UUID?

    static let rowHeight: CGFloat = 26

    enum DragItem: Equatable { case feed(UUID), group(UUID) }

    /// Where the pointer is during a drag, for the insertion line or highlight.
    enum DropSpot: Equatable {
        case before(UUID), after(UUID), onto(UUID), end
    }

    /// The name sheet is shared by "New Group" and "Rename". `moving` files a
    /// feed into the group once it is created ("Move to Group → New Group…").
    struct GroupNaming: Identifiable {
        var id = UUID()
        var renaming: FeedGroup?
        var moving: UUID?
    }

    var body: some View {
        // The feed list scrolls in its own pane; Add and the links stay fixed below it.
        VStack(spacing: 0) {
            feedList
            Divider()
            footer
        }
        .sheet(item: $naming) { n in
            NameSheet(title: n.renaming == nil ? "New Group" : "Name Group",
                      initial: n.renaming?.name ?? "",
                      action: n.renaming == nil ? "Create" : "Save") { name in
                if let g = n.renaming {
                    model.renameGroup(g.id, to: name)
                } else if let gid = model.addGroup(name), let feedID = n.moving {
                    withAnimation(.snappy) { model.move(feed: feedID, to: .group(gid, before: nil)) }
                    celebrate(gid)
                }
            }
        }
    }

    private var feedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row(selected: selection == .all) {
                    Label("All Feeds", systemImage: "tray.full")
                    Spacer()
                    badge(model.unreadCount(.all))
                }
                .onTapGesture { selection = .all }
                .contextMenu { Button("Move All to Old") { model.markAllRead(in: .all) } }
                .padding(.bottom, 10)

                ForEach(model.topLevel) { item in
                    switch item {
                    case .feed(let id): if let f = feed(id) { feedRow(f, group: nil) }
                    case .group(let id): if let g = model.groups.first(where: { $0.id == id }) { groupBox(g) }
                    }
                }

                // Below the last item: a feed dropped here leaves its group.
                Color.clear
                    .frame(height: 40)
                    .overlay(alignment: .top) { if spot == .end { InsertLine() } }
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: SpotDrop(spot: $spot, at: { _ in dragging == nil ? nil : .end },
                                                            perform: performDrop))
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .animation(.snappy(duration: 0.25), value: model.topLevel)
            .animation(.snappy(duration: 0.25), value: model.feeds.map(\.groupID))
            .background(AlwaysShowScrollers().allowsHitTesting(false))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .transition(.opacity)
                    .padding(.horizontal, 8)
            }
            EvidenceStatusBar()
                .padding(.horizontal, 8)
            // Add Feed as a row, with the other list actions as icons beside it.
            HStack(spacing: 2) {
                Button { showingAdd = true } label: { AddRow() }
                    .buttonStyle(.plain)
                    .help("Add a feed")
                IconAction(symbol: "folder.badge.plus", help: "New group") { naming = GroupNaming() }
                IconAction(symbol: "doc.on.doc", help: "Copy feed list (OPML)") { model.copyFeedList() }
                IconAction(symbol: "doc.on.clipboard", help: "Paste feed list") { pasteFeedList(model) }
            }
            HStack(spacing: 6) {
                RepositoryPill()
                TipsPill()
                Spacer()
                if let err = model.saveError {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).help(err)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func feed(_ id: UUID) -> Feed? { model.feeds.first { $0.id == id } }

    // MARK: - Rows

    private func row<Content: View>(selected: Bool, highlighted: Bool = false,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 8)
            .frame(height: Sidebar.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.25)
                          : highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
    }

    private func feedRow(_ feed: Feed, group: UUID?) -> some View {
        row(selected: selection == .feed(feed.id), highlighted: spot == .onto(feed.id)) {
            FeedName(name: feed.name)
            if let err = feed.lastError {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red).help(err)
            }
            Spacer(minLength: 4)
            CheckingIndicator(item: .feed(feed.id))
            badge(model.unreadCount(.feed(feed.id)))
        }
        .overlay(alignment: .top) { if spot == .before(feed.id) { InsertLine() } }
        .overlay(alignment: .bottom) { if spot == .after(feed.id) { InsertLine() } }
        .onTapGesture { selection = .feed(feed.id) }
        .onDrag {
            dragging = .feed(feed.id)
            return NSItemProvider(object: "pwnd-feed:\(feed.id.uuidString)" as NSString)
        } preview: {
            DragLozenge(feed: feed, unread: model.unreadCount(.feed(feed.id)))
        }
        .onDrop(of: [.text], delegate: SpotDrop(spot: $spot, at: { y in feedSpot(feed, group: group, y: y) },
                                                perform: performDrop))
        .contextMenu { feedMenu(feed) }
    }

    private func groupBox(_ g: FeedGroup) -> some View {
        let members = model.feeds(in: g.id)
        let selected = selection == .group(g.id)
        let lit = spot == .onto(g.id) || landed == g.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(g.name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Spacer()
                badge(model.unreadCount(.group(g.id)))
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .contentShape(Rectangle())
            .onTapGesture { selection = .group(g.id) }
            .onDrag {
                dragging = .group(g.id)
                return NSItemProvider(object: "pwnd-group:\(g.id.uuidString)" as NSString)
            } preview: {
                Text(g.name).font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .onDrop(of: [.text], delegate: SpotDrop(spot: $spot, at: { y in labelSpot(g, y: y) }, perform: performDrop))
            .contextMenu {
                Button("Move All to Old") { model.markAllRead(in: .group(g.id)) }
                Button("Rename…") { naming = GroupNaming(renaming: g) }
                Divider()
                Button("Delete Group") {
                    if selection == .group(g.id) { selection = .all }
                    withAnimation(.snappy) { model.deleteGroup(g.id) }
                }
            }

            ForEach(members) { feedRow($0, group: g.id) }
            if members.isEmpty {
                Text("Drag feeds here").font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 8).frame(height: Sidebar.rowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: SpotDrop(spot: $spot, at: { _ in
                        if case .feed = dragging { return .onto(g.id) } else { return nil }
                    }, perform: performDrop))
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(lit ? Color.accentColor : Color.secondary.opacity(0.28), lineWidth: lit ? 1.5 : 1)
        )
        .overlay(alignment: .bottom) { if spot == .after(g.id) { InsertLine().offset(y: 2) } }
        .padding(.bottom, 4)
        // The gap above each group is a drop zone: a feed or group dropped
        // there goes to the top level, just before this group.
        .safeAreaInset(edge: .top, spacing: 0) { gapAbove(g) }
    }

    private func gapAbove(_ g: FeedGroup) -> some View {
        Color.clear
            .frame(height: 10)
            .frame(maxWidth: .infinity)
            .overlay { if spot == .before(g.id) { InsertLine() } }
            .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: SpotDrop(spot: $spot, at: { _ in
                switch dragging {
                case .feed: return .before(g.id)
                case .group(let d) where d != g.id: return .before(g.id)
                default: return nil
                }
            }, perform: performDrop))
    }

    @ViewBuilder private func badge(_ n: Int) -> some View {
        if n > 0 {
            Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func feedMenu(_ feed: Feed) -> some View {
        Button("Move All to Old") { model.markAllRead(in: .feed(feed.id)) }
        Menu("Move to Group") {
            ForEach(model.groups) { g in
                Button(g.name) {
                    withAnimation(.snappy) { model.move(feed: feed.id, to: .group(g.id, before: nil)) }
                    celebrate(g.id)
                }
                .disabled(feed.groupID == g.id)
            }
            if !model.groups.isEmpty { Divider() }
            Button("No Group") { withAnimation(.snappy) { model.move(feed: feed.id, to: .top(before: nil)) } }
                .disabled(feed.groupID == nil)
            Button("New Group…") { naming = GroupNaming(moving: feed.id) }
        }
        Divider()
        Button("Unsubscribe", role: .destructive) {
            if selection == .feed(feed.id) { selection = .all }
            withAnimation(.snappy) { model.removeFeed(feed.id) }
        }
    }

    // MARK: - Drop rules

    /// Where a drop on a feed row would land, from the pointer's height in it.
    private func feedSpot(_ target: Feed, group: UUID?, y: CGFloat) -> DropSpot? {
        let third = Sidebar.rowHeight / 3
        switch dragging {
        case .feed(let d) where d != target.id:
            return y < third ? .before(target.id) : y > 2 * third ? .after(target.id) : .onto(target.id)
        case .group where group == nil:
            return y < Sidebar.rowHeight / 2 ? .before(target.id) : .after(target.id)
        default:
            return nil
        }
    }

    private func labelSpot(_ g: FeedGroup, y: CGFloat) -> DropSpot? {
        switch dragging {
        case .feed: return .onto(g.id)
        case .group(let d) where d != g.id: return y < 10 ? .before(g.id) : .after(g.id)
        default: return nil
        }
    }

    /// The item after `id` in its container, for "insert after".
    private func next(after id: UUID) -> UUID? {
        if let f = feed(id), let gid = f.groupID, model.groups.contains(where: { $0.id == gid }) {
            let members = model.feeds(in: gid).map(\.id)
            return members.firstIndex(of: id).flatMap { $0 + 1 < members.count ? members[$0 + 1] : nil }
        }
        let top = model.topLevel.map(\.id)
        return top.firstIndex(of: id).flatMap { $0 + 1 < top.count ? top[$0 + 1] : nil }
    }

    /// The group a feed is in, or nil at the top level.
    private func container(of id: UUID) -> UUID? {
        guard let gid = feed(id)?.groupID, model.groups.contains(where: { $0.id == gid }) else { return nil }
        return gid
    }

    private func performDrop(_ spot: DropSpot) -> Bool {
        defer { dragging = nil }
        switch (dragging, spot) {
        case (.feed(let d), .before(let t)):
            if let gid = container(of: t) { model.move(feed: d, to: .group(gid, before: t)) }
            else { model.move(feed: d, to: .top(before: t)) }
        case (.feed(let d), .after(let t)):
            if let gid = container(of: t) { model.move(feed: d, to: .group(gid, before: next(after: t))) }
            else { model.move(feed: d, to: .top(before: next(after: t))) }
        case (.feed(let d), .onto(let t)):
            if model.groups.contains(where: { $0.id == t }) {
                model.move(feed: d, to: .group(t, before: nil))      // dropped on a group label
                celebrate(t)
            } else if let gid = container(of: t) {
                model.move(feed: d, to: .group(gid, before: next(after: t)))
                celebrate(gid)
            } else if let g = model.groupTogether(d, onto: t) {
                celebrate(g.id)
                naming = GroupNaming(renaming: g)                    // new group: ask for a name
            }
        case (.feed(let d), .end):
            model.move(feed: d, to: .top(before: nil))
        case (.group(let g), .before(let t)):
            model.move(group: g, before: t)
        case (.group(let g), .after(let t)):
            model.move(group: g, before: next(after: t))
        case (.group(let g), .end):
            model.move(group: g, before: nil)
        default:
            return false
        }
        return true
    }

    /// Brief accent border on the group that just received a feed.
    private func celebrate(_ group: UUID) {
        withAnimation(.easeOut(duration: 0.15)) { landed = group }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.3)) { if landed == group { landed = nil } }
        }
    }
}

/// The accent line that shows where a dragged item will be inserted.
struct InsertLine: View {
    var body: some View {
        Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 4)
    }
}

/// Reports the drop spot under the pointer and performs the drop there.
struct SpotDrop: DropDelegate {
    @Binding var spot: Sidebar.DropSpot?
    let at: (CGFloat) -> Sidebar.DropSpot?
    let perform: (Sidebar.DropSpot) -> Bool

    func validateDrop(info: DropInfo) -> Bool { at(info.location.y) != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let s = at(info.location.y)
        if s != spot { spot = s }
        return s == nil ? DropProposal(operation: .forbidden) : DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { spot = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let s = at(info.location.y) else { spot = nil; return false }
        spot = nil
        return withAnimation(.snappy(duration: 0.25)) { perform(s) }
    }
}

/// "Add Feed", laid out like a sidebar row: full width, with a hover highlight.
struct AddRow: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").frame(width: 16)
            Text("Add Feed")
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: Sidebar.rowHeight)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A light pill with black text in both appearances, so the links read as
/// badges rather than controls like Add.
struct LinkPill<Label: View>: View {
    let url: URL
    let help: String
    @ViewBuilder let label: () -> Label

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 4) { label() }
                .lineLimit(1)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color(white: 0.9)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct RepositoryPill: View {
    var body: some View {
        LinkPill(url: AppInfo.repository, help: "pwnd \(AppInfo.version) by orangesurf. Opens github.com/orangesurf/pwnd.") {
            GitHubMark().frame(width: 10, height: 10)
            Text("orangesurf/pwnd")
            Text("v\(AppInfo.version)").foregroundStyle(Color.black.opacity(0.5))
        }
    }
}

/// A plain white coffee cup linking to the tips page.
struct TipsPill: View {
    var body: some View {
        Link(destination: AppInfo.tips) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Buy orangesurf a coffee: tips.orange.surf")
    }
}

/// A small icon button for the sidebar footer, with a hover highlight.
struct IconAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: Sidebar.rowHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}
