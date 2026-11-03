import AppKit
import PwndCore
import SwiftUI

@main
struct PwndApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("pwnd", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 480)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh All Feeds") { model.refreshNow() }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .appSettings) {
                Divider()
                Button("Reset pwnd…") { confirmReset(model) }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About pwnd") { showAbout() }
            }
            CommandMenu("Feeds") {
                Button("Copy Feed List") { model.copyFeedList() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Paste Feed List…") { pasteFeedList(model) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        // Stays in the menu bar after the window closes, so polling and
        // alerts carry on in the background.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            let n = model.unreadCritical
            if n > 0 {
                Label("\(n)", systemImage: "exclamationmark.shield.fill")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "shield")
            }
        }
    }
}

enum AppInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let repository = URL(string: "https://github.com/orangesurf/pwnd")!
    static let tips = URL(string: "https://tips.orange.surf")!
}

/// The standard About window, with the author and repository link.
@MainActor
func showAbout() {
    let credits = NSMutableAttributedString(string: "by orangesurf\n", attributes: [
        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    credits.append(NSAttributedString(string: "github.com/orangesurf/pwnd", attributes: [
        .font: NSFont.systemFont(ofSize: 11), .link: AppInfo.repository]))
    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationVersion: AppInfo.version, .version: ""])
}

/// Reads a feed list from the clipboard and asks whether to add it or
/// replace the current list, saying what each would change.
@MainActor
func pasteFeedList(_ model: AppModel) {
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    guard let list = FeedList.parse(text) else {
        let a = NSAlert()
        a.messageText = "No feed list on the clipboard"
        a.informativeText = "Copy an OPML feed list, or lines of owner/repo or feed URLs, then try again."
        a.runModal()
        return
    }
    let total = list.allFeeds.count
    let missing = list.missing(from: model.feeds).count
    let removing = model.feeds.filter { f in !list.allFeeds.contains { $0.url.absoluteString.lowercased() == f.url.absoluteString.lowercased() } }.count
    let a = NSAlert()
    a.messageText = "Import \(total) feed\(total == 1 ? "" : "s")?"
    a.informativeText = """
        Add puts the \(missing) you don't have yet into a new Imported group.
        Replace makes this your feed list\(removing > 0 ? " and removes \(removing) feed\(removing == 1 ? "" : "s") not in it, with their releases" : "").
        """
    a.addButton(withTitle: "Add")
    let replace = a.addButton(withTitle: "Replace")
    replace.hasDestructiveAction = removing > 0
    a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    switch a.runModal() {
    case .alertFirstButtonReturn: withAnimation(.snappy) { model.importAdding(list) }
    case .alertSecondButtonReturn: withAnimation(.snappy) { model.importReplacing(list) }
    default: break
    }
}

/// Asks before deleting everything. A plain NSAlert, so it works from the
/// menu whether or not the main window is open.
@MainActor
func confirmReset(_ model: AppModel) {
    let alert = NSAlert()
    alert.messageText = "Reset pwnd?"
    alert.informativeText = """
        This deletes all your feeds, groups, releases, read state, keyword lists, settings \
        and saved GitHub token, and starts again with the default feeds. It cannot be undone.
        """
    alert.alertStyle = .warning
    let reset = alert.addButton(withTitle: "Reset")
    reset.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn { model.reset() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary runs outside an .app bundle (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window keeps pwnd running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let alerts = model.entries(in: .all, filter: EntryFilter(unreadOnly: true, minimum: .important)).prefix(10)
        if alerts.isEmpty {
            Text("No new important releases")
        } else {
            ForEach(Array(alerts)) { e in
                Button("\(e.severity == .critical ? "⛔" : "⚠️") \(model.feedName(e.feedID)): \(e.title)") {
                    if let link = e.link { NSWorkspace.shared.open(link) }
                    model.setRead([e.id], true)
                }
            }
        }
        Divider()
        Button("Open pwnd") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(model.refreshing ? "Refreshing…" : "Refresh Now") { model.refreshNow() }
            .disabled(model.refreshing)
        Divider()
        Button("Quit pwnd") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
