import AppKit
import Foundation
import PwndCore
import UserNotifications

/// Posts macOS notifications; clicking one opens the release page.
///
/// The app is ad-hoc signed, not Developer ID signed. UserNotifications still
/// works for an ad-hoc signed bundle once the user allows it in System
/// Settings → Notifications → pwnd. If authorization is refused or the call
/// fails, alerts fall back to `osascript display notification`, which shows
/// under Script Editor's name and cannot open a link.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when there is no app bundle,
        // e.g. when running `.build/debug/Pwnd` directly.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }
    private var authorized = false

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func post(entry: Entry, feedName: String, escalated: Bool = false) {
        let title = escalated ? "Now \(entry.severity.label): \(feedName)" : "\(entry.severity.label): \(feedName)"
        let why = entry.matches.isEmpty ? "" : " — " + entry.matches.prefix(3).joined(separator: ", ")
        deliver(title: title, body: entry.title + why, link: entry.link,
                sound: entry.severity == .critical)
    }

    func clearDelivered() {
        center?.removeAllDeliveredNotifications()
        center?.removeAllPendingNotificationRequests()
    }

    func postSummary(_ title: String, body: String) {
        deliver(title: title, body: body, link: nil, sound: false)
    }

    private func deliver(title: String, body: String, link: URL?, sound: Bool) {
        guard let center, authorized else {
            fallback(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if let link { content.userInfo = ["link": link.absoluteString] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req) { [weak self] error in
            if error != nil { self?.fallback(title: title, body: body) }
        }
    }

    /// Strings go through argv, never into the AppleScript source, so a
    /// quote in a release title cannot inject script.
    private func fallback(title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e",
                       "display notification (item 1 of argv) with title (item 2 of argv)",
                       "-e", "end run", "--", body, title]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // Show banners even while pwnd is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["link"] as? String, let url = URL(string: s) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
