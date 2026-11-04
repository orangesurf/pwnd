import AppKit
import PwndCore
import SwiftUI

/// Drag payload for a piece of software (a feed) from the catalog.
private enum SoftwareDrag {
    static let prefix = "pwnd-software:"
    static func payload(_ id: UUID) -> String { prefix + id.uuidString }
    static func provider(_ id: UUID) -> NSItemProvider {
        NSItemProvider(object: payload(id) as NSString)
    }

    /// Loads dropped strings and hands the software IDs to `install` on the
    /// main thread. Returns false when nothing dropped is text.
    static func receive(_ providers: [NSItemProvider], install: @escaping @MainActor ([UUID]) -> Void) -> Bool {
        let usable = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !usable.isEmpty else { return false }
        for p in usable {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String else { return }
                let found = ids([s])
                guard !found.isEmpty else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { install(found) } }
            }
        }
        return true
    }

    static func ids(_ items: [String]) -> [UUID] {
        items.flatMap { $0.split(whereSeparator: \.isNewline) }
            .compactMap { s in s.hasPrefix(prefix) ? UUID(uuidString: String(s.dropFirst(prefix.count))) : nil }
    }
}

/// Where a server stands, from the new releases of its software. Shown under
/// the server's name like a VM's power state.
struct ServerStatus {
    enum Level { case upToDate, updates, security, empty }
    let level: Level
    let text: String

    @MainActor init(_ server: Server, model: AppModel) {
        let fresh = model.newReleases(on: server)
        let critical = fresh.filter { $0.severity == .critical }.count
        if server.feedIDs.isEmpty {
            level = .empty; text = "No software"
        } else if critical > 0 {
            level = .security; text = "\(critical) security update\(critical == 1 ? "" : "s")"
        } else if !fresh.isEmpty {
            level = .updates; text = "\(fresh.count) new release\(fresh.count == 1 ? "" : "s")"
        } else {
            level = .upToDate; text = "Up to date"
        }
    }

    var color: Color {
        switch level {
        case .upToDate: return .green
        case .updates: return .blue
        case .security: return .red
        case .empty: return .secondary
        }
    }

    var symbol: String {
        switch level {
        case .upToDate: return "checkmark.circle.fill"
        case .updates: return "arrow.down.circle.fill"
        case .security: return "exclamationmark.octagon.fill"
        case .empty: return "circle.dashed"
        }
    }
}

/// The Servers window: machines on the left, the selected one's details in
/// the middle, and the software catalog on the right to drag from.
struct ServersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: UUID?
    @State private var showingNew = false
    @State private var showingCatalog = true
    @State private var confirmingRemove: Server?

    private var selected: Server? { model.servers.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            ServerList(selection: $selection, confirmingRemove: $confirmingRemove)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            Group {
                if let server = selected {
                    ServerDetail(server: server)
                        .id(server.id)
                } else if model.servers.isEmpty {
                    WelcomeView { showingNew = true }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "server.rack").font(.system(size: 36, weight: .light))
                        Text("Select a server")
                    }
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .inspector(isPresented: $showingCatalog) {
                SoftwareCatalog(server: selected)
                    .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingNew = true } label: { Label("New", systemImage: "plus.rectangle.on.rectangle") }
                    .help("New server")
                Button { confirmingRemove = selected } label: { Label("Remove", systemImage: "trash") }
                    .help("Remove the selected server")
                    .disabled(selected == nil)
                Button { showingCatalog.toggle() } label: { Label("Software", systemImage: "shippingbox") }
                    .help(showingCatalog ? "Hide the software catalog" : "Show the software catalog")
            }
        }
        .sheet(isPresented: $showingNew) {
            NewServerSheet { id in selection = id }
        }
        .confirmationDialog("Remove \(confirmingRemove?.name ?? "server")?", isPresented: Binding(
            get: { confirmingRemove != nil }, set: { if !$0 { confirmingRemove = nil } }
        ), presenting: confirmingRemove) { s in
            Button("Remove", role: .destructive) {
                if selection == s.id { selection = nil }
                model.removeServer(s.id)
            }
        } message: { _ in
            Text("The feeds it runs stay subscribed.")
        }
        .navigationTitle("Servers")
        .navigationSubtitle(selected.map { $0.address.isEmpty ? $0.name : "\($0.name) · \($0.address)" } ?? "\(model.servers.count) server\(model.servers.count == 1 ? "" : "s")")
        .onAppear {
            if let f = model.focusServer { selection = f; model.focusServer = nil }
            if selection == nil { selection = model.servers.first?.id }
        }
        .onChange(of: model.focusServer) { _, f in
            if let f { selection = f; model.focusServer = nil }
        }
        .onChange(of: model.generation) { _, _ in selection = nil }
    }
}

// MARK: - List

private struct ServerList: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: UUID?
    @Binding var confirmingRemove: Server?
    @State private var dropTarget: UUID?

    // A plain stack rather than a List: on macOS a List row sits in an
    // NSTableView, which takes drops itself, so row drop targets never fire.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Servers")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                ForEach(model.servers) { server in
                    ServerRow(server: server, selected: selection == server.id, highlighted: dropTarget == server.id)
                        .onTapGesture { selection = server.id }
                        // Dropping software straight onto a server in the list installs it.
                        .onDrop(of: [.text], isTargeted: Binding(
                            get: { dropTarget == server.id },
                            set: { on in if on { dropTarget = server.id } else if dropTarget == server.id { dropTarget = nil } }
                        )) { providers in
                            SoftwareDrag.receive(providers) { ids in
                                withAnimation(.snappy) { model.install(ids, on: server.id) }
                                selection = server.id
                            }
                        }
                        .contextMenu {
                            Button("Remove…", role: .destructive) { confirmingRemove = server }
                        }
                }
            }
            .padding(10)
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { confirmingRemove = model.servers.first { $0.id == selection } }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
    }

    private func step(_ by: Int) {
        let ids = model.servers.map(\.id)
        guard !ids.isEmpty else { return }
        let i = selection.flatMap { ids.firstIndex(of: $0) } ?? (by > 0 ? -1 : ids.count)
        selection = ids[min(max(i + by, 0), ids.count - 1)]
    }
}

private struct ServerRow: View {
    @EnvironmentObject private var model: AppModel
    let server: Server
    var selected = false
    var highlighted = false

    var body: some View {
        let status = ServerStatus(server, model: model)
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "server.rack")
                    .font(.system(size: 22, weight: .light))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.quinary))
                Image(systemName: status.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.white, status.color)
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).fontWeight(.semibold).lineLimit(1)
                Text(status.text)
                    .foregroundStyle(status.level == .security ? status.color : .secondary)
                    .font(.caption)
                    .lineLimit(1)
                if !server.address.isEmpty {
                    Text(server.address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.28) : highlighted ? Color.accentColor.opacity(0.15) : .clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .opacity(highlighted ? 1 : 0)
        }
        .contentShape(Rectangle())
    }
}

private struct WelcomeView: View {
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("Welcome to Servers").font(.title2.weight(.semibold))
            Text("Add the machines you run, then drag software from the catalog onto them. Each server shows when its software has new or security releases.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("New Server…", action: onNew)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail

/// One titled block of the detail pane, like VirtualBox's General / System
/// sections: an icon and heading, then label/value rows or free content.
private struct DetailSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
    }
}

private struct ServerDetail: View {
    @EnvironmentObject private var model: AppModel
    let server: Server
    @State private var name = ""
    @State private var address = ""
    @State private var notes = ""
    @State private var dropTargeted = false
    @FocusState private var focus: Field?

    private enum Field { case name, address, notes }

    private var addressKind: ServerAddress.Kind? { ServerAddress.classify(address) }
    private var addressOK: Bool { address.trimmingCharacters(in: .whitespaces).isEmpty || addressKind != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                general
                software
                updates
                DetailSection(title: "Notes", symbol: "note.text") {
                    TextField("Location, OS, anything else", text: $notes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...6)
                        .focused($focus, equals: .notes)
                        .onSubmit(commit)
                }
            }
            .padding(18)
        }
        .onAppear { load() }
        .onChange(of: server) { _, _ in if focus == nil { load() } }
        .onChange(of: focus) { old, _ in if old != nil { commit() } }
        .onDisappear(perform: commit)
    }

    private var header: some View {
        let status = ServerStatus(server, model: model)
        return HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 34, weight: .ultraLight))
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.title2.weight(.semibold)).lineLimit(1)
                Label(status.text, systemImage: status.symbol)
                    .foregroundStyle(status.color)
                    .font(.callout)
            }
            Spacer()
        }
    }

    private var general: some View {
        DetailSection(title: "General", symbol: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Name:").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("Server name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .name)
                        .onSubmit(commit)
                }
                GridRow {
                    Text("Address:").foregroundStyle(.secondary)
                    HStack {
                        TextField("192.168.1.10 or node.local", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .focused($focus, equals: .address)
                            .onSubmit(commit)
                        AddressBadge(address: address)
                    }
                }
                GridRow {
                    Text("Software:").foregroundStyle(.secondary)
                    Text("\(server.feedIDs.count) installed")
                }
            }
            if !addressOK {
                Text("Not a valid IPv4, IPv6 address or hostname; the last valid address is kept.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var software: some View {
        let installed = model.software(on: server)
        return DetailSection(title: "Installed Software", symbol: "shippingbox") {
            SoftwareSearchField(server: server)
            if installed.isEmpty {
                Text("Drag software here from the catalog, or search above.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                VStack(spacing: 0) {
                    ForEach(installed) { feed in
                        InstalledRow(server: server, feed: feed)
                        if feed.id != installed.last?.id { Divider() }
                    }
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .opacity(dropTargeted ? 1 : 0)
        }
        .onDrop(of: [.text], isTargeted: $dropTargeted) { providers in
            SoftwareDrag.receive(providers) { ids in
                withAnimation(.snappy) { model.install(ids, on: server.id) }
            }
        }
    }

    @ViewBuilder
    private var updates: some View {
        let fresh = model.newReleases(on: server)
        if !fresh.isEmpty {
            DetailSection(title: "New Releases", symbol: "bell.badge") {
                ForEach(fresh.prefix(8)) { e in
                    HStack(spacing: 8) {
                        if e.severity > .routine { SeverityBadge(severity: e.severity, compact: true) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).lineLimit(1)
                            Text(model.feedName(e.feedID)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let link = e.link {
                            Button("Open") { NSWorkspace.shared.open(link) }.controlSize(.small)
                        }
                        Button("Mark Old") { model.setRead([e.id], true) }.controlSize(.small)
                    }
                }
                if fresh.count > 8 {
                    Text("and \(fresh.count - 8) more in the main window").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() {
        name = server.name
        address = server.address
        notes = server.notes
    }

    private func commit() {
        let ok = addressOK
        model.updateServer(server.id) { s in
            s.name = name
            if ok { s.address = address }
            s.notes = notes
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = server.name }
    }
}

/// "IPv4" / "IPv6" / "Host" tag next to the address, red when invalid.
private struct AddressBadge: View {
    let address: String

    var body: some View {
        let blank = address.trimmingCharacters(in: .whitespaces).isEmpty
        let kind = ServerAddress.classify(address)
        let text: String = switch kind {
        case .ipv4: "IPv4"
        case .ipv6: "IPv6"
        case .hostname: "Host"
        case nil: blank ? "None" : "Invalid"
        }
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(kind == nil && !blank ? Color.red : Color.secondary)
            .background(Capsule().fill(kind == nil && !blank ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12)))
            .frame(width: 60)
    }
}

private struct InstalledRow: View {
    @EnvironmentObject private var model: AppModel
    let server: Server
    let feed: Feed
    @State private var hovering = false

    var body: some View {
        let latest = model.latestRelease(feed.id)
        let fresh = model.entries.filter { $0.feedID == feed.id && !$0.read }
        let critical = fresh.contains { $0.severity == .critical }
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(feed.name).lineLimit(1)
                Text(latest.map { "Latest: \($0.title)" } ?? "No releases fetched yet")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !fresh.isEmpty {
                Text("\(fresh.count) new")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(critical ? .white : .primary)
                    .background(Capsule().fill(critical ? Color.red : Color.accentColor.opacity(0.2)))
            }
            Button {
                withAnimation(.snappy) { model.uninstall([feed.id], from: server.id) }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Remove \(feed.name) from \(server.name)")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let link = latest?.link { Button("Open Latest Release") { NSWorkspace.shared.open(link) } }
            Button("Remove from \(server.name)") { model.uninstall([feed.id], from: server.id) }
        }
    }
}

/// Type to find software; matches drop down below. Return installs the top
/// match, arrow keys move through them.
private struct SoftwareSearchField: View {
    @EnvironmentObject private var model: AppModel
    let server: Server
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var matches: [Feed] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return model.feeds.filter { !server.feedIDs.contains($0.id) && SoftwareSearch.matches($0, query: query) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search software to add…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { add(at: highlighted) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(matches.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) { query = ""; return .handled }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.3)))

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty {
                        Text("No matching software that isn't installed").foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(Array(matches.enumerated()), id: \.element.id) { i, feed in
                        Button { add(at: i) } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                                Text(feed.name)
                                Spacer()
                                if let g = feed.groupID { Text(model.groupName(g)).font(.caption).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 5).fill(i == highlighted ? Color.accentColor.opacity(0.18) : .clear))
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { highlighted = i } }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 7).fill(.background))
                .padding(.top, 4)
            }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func add(at i: Int) {
        guard matches.indices.contains(i) else { return }
        withAnimation(.snappy) { model.install([matches[i].id], on: server.id) }
        query = ""
        focused = true
    }
}

// MARK: - Catalog

/// Every followed feed, grouped as in the main sidebar. Drag a row onto a
/// server (in the list or the detail pane), or double-click it to install on
/// the selected server.
private struct SoftwareCatalog: View {
    @EnvironmentObject private var model: AppModel
    let server: Server?
    @State private var query = ""

    private var sections: [(title: String, feeds: [Feed])] {
        let visible = model.feeds.filter { SoftwareSearch.matches($0, query: query) }
        var out: [(String, [Feed])] = []
        let ungrouped = visible.filter { $0.groupID == nil }
        if !ungrouped.isEmpty { out.append(("Other", ungrouped)) }
        for g in model.groups {
            let fs = visible.filter { $0.groupID == g.id }
            if !fs.isEmpty { out.append((g.name, fs)) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter software", text: $query).textFieldStyle(.plain)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quinary))
            .padding(10)

            // A plain stack, not a List, so rows start drags reliably.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(sections, id: \.title) { section in
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(section.feeds) { feed in
                            CatalogRow(feed: feed, server: server)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if sections.isEmpty {
                    Text(model.feeds.isEmpty ? "Subscribe to feeds in the main window first." : "No matches")
                        .foregroundStyle(.secondary).padding()
                }
            }

            Text(server == nil ? "Select a server to install software on." : "Drag onto a server, or double-click to install on \(server!.name).")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(10)
        }
    }
}

private struct CatalogRow: View {
    @EnvironmentObject private var model: AppModel
    let feed: Feed
    let server: Server?
    @State private var hovering = false

    var body: some View {
        let installed = server?.feedIDs.contains(feed.id) ?? false
        let count = model.servers.filter { $0.feedIDs.contains(feed.id) }.count
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(Color.accentColor)
            Text(feed.name).lineLimit(1)
            Spacer()
            if installed {
                Image(systemName: "checkmark").foregroundStyle(.green).help("Installed on \(server?.name ?? "")")
            } else if count > 0 {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("On \(count) server\(count == 1 ? "" : "s")")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Drag onto a server to install")
        .onDrag { SoftwareDrag.provider(feed.id) } preview: {
            Label(feed.name, systemImage: "shippingbox.fill")
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.regularMaterial))
        }
        .onTapGesture(count: 2) {
            if let s = server, !installed { withAnimation(.snappy) { model.install([feed.id], on: s.id) } }
        }
        .contextMenu {
            ForEach(model.servers) { s in
                Button(s.feedIDs.contains(feed.id) ? "Remove from \(s.name)" : "Install on \(s.name)") {
                    if s.feedIDs.contains(feed.id) { model.uninstall([feed.id], from: s.id) } else { model.install([feed.id], on: s.id) }
                }
            }
        }
    }
}

// MARK: - New server

private struct NewServerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onCreate: (UUID) -> Void
    @State private var name = ""
    @State private var address = ""
    @FocusState private var nameFocused: Bool

    private var addressValid: Bool { ServerAddress.isValid(address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").font(.system(size: 26, weight: .light))
                Text("New Server").font(.headline)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name:").gridColumnAlignment(.trailing)
                    TextField("Home node", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                }
                GridRow {
                    Text("Address:")
                    HStack {
                        TextField("192.168.1.10", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .onSubmit(create)
                        AddressBadge(address: address)
                    }
                }
            }
            .frame(width: 400)
            Text("An IPv4 or IPv6 address, or a hostname such as node.local. Add software after creating it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 400, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction)
                    .disabled(!addressValid)
            }
        }
        .padding(20)
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard addressValid else { return }
        let id = model.addServer(name: name, address: address)
        onCreate(id)
        dismiss()
    }
}
