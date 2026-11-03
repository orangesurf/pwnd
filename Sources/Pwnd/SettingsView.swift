import AppKit
import PwndCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            KeywordSettings().tabItem { Label("Keywords", systemImage: "text.magnifyingglass") }
        }
        .frame(width: 560)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Check feeds every", selection: $model.settings.pollMinutes) {
                    ForEach(PollInterval.choices, id: \.self) { m in
                        Text(PollInterval.label(m)).tag(m)
                            .disabled(!model.hasToken && m < AppModel.minimumPollWithoutToken)
                    }
                }
                if !model.hasToken {
                    Text("Without a GitHub token, every \(AppModel.minimumPollWithoutToken) minutes is the fastest.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("GitHub token") {
                GitHubTokenForm()
            }
            Section("Display") {
                Toggle("Show severity tags (Critical, Important)", isOn: $model.settings.showSeverity)
            }
            Section("Alerts") {
                Toggle("Also notify for important releases", isOn: $model.settings.notifyImportant)
                Toggle("No alerts for releases from before a feed was added", isOn: $model.settings.ignoreOldAlerts)
            }
            Section {
                HStack(spacing: 6) {
                    Text("pwnd \(AppInfo.version) · by orangesurf").foregroundStyle(.secondary)
                    Spacer()
                    Link("github.com/orangesurf/pwnd", destination: AppInfo.repository)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }
}

struct KeywordSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var critical = ""
    @State private var signals = ""
    @State private var important = ""
    @State private var ignore = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One keyword per line, case-insensitive, matched at the start of a word: `vulnerab` matches “vulnerability”. Wrap a line in slashes for a regular expression: `/CVE-\\d{4}-\\d+/`. Each release is scored on its title and notes.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                editor("Critical", "One match makes a release critical.", $critical)
                editor("Signals", "Critical if one is in the title or two match anywhere; otherwise important.", $signals)
            }
            HStack(alignment: .top, spacing: 12) {
                editor("Important", "One match makes a release important.", $important)
                editor("Ignore", "Phrases removed before matching. Line breaks and Markdown between words are ignored.", $ignore)
            }
            if let problem = problems.first {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Restore Defaults") { load(.defaults) }
                Spacer()
                Button("Revert") { load(model.settings.keywords) }.disabled(!dirty)
                Button("Apply and Rescore") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dirty || !problems.isEmpty)
            }
        }
        .padding(20)
        .onAppear { if !loaded { load(model.settings.keywords); loaded = true } }
    }

    private func editor(_ title: String, _ hint: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 150)
                .border(Color.secondary.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
    }

    private var edited: KeywordConfig {
        KeywordConfig(critical: lines(critical), signals: lines(signals), important: lines(important), ignore: lines(ignore))
    }

    private var dirty: Bool { edited != model.settings.keywords }

    private var problems: [String] {
        (edited.critical + edited.signals + edited.important + edited.ignore).compactMap(Classifier.problem)
    }

    private func lines(_ s: String) -> [String] {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func load(_ k: KeywordConfig) {
        critical = k.critical.joined(separator: "\n")
        signals = k.signals.joined(separator: "\n")
        important = k.important.joined(separator: "\n")
        ignore = k.ignore.joined(separator: "\n")
    }

    private func apply() { model.settings.keywords = edited }
}

/// Refresh-frequency choices, shared by Settings and the toolbar clock.
enum PollInterval {
    static let choices = [5, 10, 15, 30, 60, 180]

    static func label(_ m: Int) -> String {
        m < 60 ? "\(m) minutes" : "\(m / 60) hour\(m == 60 ? "" : "s")"
    }
}

/// Token entry. Once a token is saved it collapses to one line and Remove.
struct GitHubTokenForm: View {
    @EnvironmentObject private var model: AppModel
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        if model.hasToken {
            HStack {
                Label("GitHub token set", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Remove") { model.removeToken() }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("A token allows more frequent checks.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Link("Create one on GitHub", destination: URL(string: "https://github.com/settings/personal-access-tokens")!)
                    Text("· Generate new token, Public repositories, Generate").foregroundStyle(.secondary)
                }
                .font(.callout)
                HStack {
                    SecureField("Paste token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button(checking ? "Checking…" : "Save", action: save)
                        .disabled(checking || token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Kept in your keychain via macOS's security tool, like GitHub's gh CLI.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func save() {
        checking = true
        Task {
            let result = await model.setToken(token)
            error = result.ok ? nil : result.message
            if result.ok { token = "" }
            checking = false
        }
    }
}

/// GitHub's mark (from Primer Octicons, MIT licence), as a template image so
/// it follows the toolbar's colour in light and dark mode.
struct GitHubMark: View {
    static let image: NSImage = {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>"#
        let img = NSImage(data: Data(svg.utf8)) ?? NSImage(systemSymbolName: "key", accessibilityDescription: nil)!
        img.isTemplate = true
        return img
    }()

    var body: some View {
        Image(nsImage: GitHubMark.image).resizable().aspectRatio(contentMode: .fit)
    }
}
