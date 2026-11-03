import Foundation

/// One item at the top level of the sidebar: a group, or a feed in no group.
public enum TopItem: Hashable, Sendable, Identifiable {
    case group(UUID)
    case feed(UUID)

    public var id: UUID {
        switch self {
        case .group(let g): return g
        case .feed(let f): return f
        }
    }
}

/// Sidebar order. Top-level order is a list of group and ungrouped-feed IDs;
/// the order of feeds inside a group is their order in the feeds array.
/// Pure functions over plain values, so they can be tested without the app.
public enum SidebarLayout {
    /// The top level in display order. IDs missing from `order` (new items,
    /// state from before ordering existed) follow, groups first.
    public static func topLevel(order: [UUID], groups: [FeedGroup], feeds: [Feed]) -> [TopItem] {
        let groupIDs = Set(groups.map(\.id))
        let ungrouped = feeds.filter { $0.groupID == nil || !groupIDs.contains($0.groupID!) }.map(\.id)
        let valid = groupIDs.union(ungrouped)
        var seen = Set<UUID>()
        var out: [TopItem] = []
        func add(_ id: UUID) {
            guard valid.contains(id), seen.insert(id).inserted else { return }
            out.append(groupIDs.contains(id) ? .group(id) : .feed(id))
        }
        order.forEach(add)
        groups.map(\.id).forEach(add)
        ungrouped.forEach(add)
        return out
    }

    /// Where a dragged item lands.
    public enum Destination: Equatable, Sendable {
        /// Top level, before the given top-level item, or at the end (nil).
        case top(before: UUID?)
        /// Inside a group, before the given feed, or at the end (nil).
        case group(UUID, before: UUID?)
    }

    /// Moves a feed. Returns the new top-level order and feeds array.
    public static func move(feed id: UUID, to dest: Destination, order: [UUID], groups: [FeedGroup],
                            feeds: [Feed]) -> (order: [UUID], feeds: [Feed]) {
        var order = topLevel(order: order, groups: groups, feeds: feeds).map(\.id)
        var feeds = feeds
        guard let i = feeds.firstIndex(where: { $0.id == id }), dest != .top(before: id) else {
            return (order, feeds)
        }
        var feed = feeds.remove(at: i)
        order.removeAll { $0 == id }
        switch dest {
        case .top(let before):
            feed.groupID = nil
            feeds.append(feed)
            if let before, let j = order.firstIndex(of: before) { order.insert(id, at: j) } else { order.append(id) }
        case .group(let gid, let before):
            feed.groupID = gid
            if let before, before != id, let j = feeds.firstIndex(where: { $0.id == before }) {
                feeds.insert(feed, at: j)
            } else if let last = feeds.lastIndex(where: { $0.groupID == gid }) {
                feeds.insert(feed, at: last + 1)
            } else {
                feeds.append(feed)
            }
        }
        return (order, feeds)
    }

    /// Moves a group within the top level, before `before` or to the end.
    public static func move(group id: UUID, before: UUID?, order: [UUID], groups: [FeedGroup], feeds: [Feed]) -> [UUID] {
        var order = topLevel(order: order, groups: groups, feeds: feeds).map(\.id)
        guard before != id else { return order }
        order.removeAll { $0 == id }
        if let before, let j = order.firstIndex(of: before) { order.insert(id, at: j) } else { order.append(id) }
        return order
    }
}
