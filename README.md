# pwnd

A macOS menu bar app that follows release feeds for bitcoin projects and alerts you when a release looks security-critical.

```sh
git clone https://github.com/orangesurf/pwnd && cd pwnd
./scripts/build-app.sh && open build/pwnd.app
```

To update:

```sh
git pull && ./scripts/build-app.sh && open build/pwnd.app
```

Quit pwnd first (menu bar shield → Quit pwnd), or `open` will bring the old copy to the front. To keep it with your other apps, copy `build/pwnd.app` to `~/Applications`.

Requires macOS 14 or later and the Xcode command line tools (`xcode-select --install`). Run tests with `swift test`.

The app is ad-hoc signed, not notarised. Built on your own Mac it opens normally. A copy downloaded from elsewhere needs right-click → Open the first time.

## What it does

pwnd polls GitHub release feeds (`releases.atom`) and ordinary RSS/Atom feeds, scores every entry against keyword lists, and sends a notification when a new critical release appears. It stays in the menu bar after the window is closed, so it keeps polling in the background. The menu bar shield shows the number of new critical releases.

On first launch macOS asks whether pwnd may send notifications. Clicking a notification opens the release page. If you decline, alerts fall back to plain `osascript` notifications, which appear under Script Editor's name and cannot open a link.

## Feeds

Add a feed with `owner/repo`, a GitHub repository URL, or any RSS/Atom URL. The defaults are Bitcoin Core; mempool and mempool's electrs; lnd, Core Lightning and phoenixd; Sparrow and BlueWallet; Coldcard, Jade, Trezor and Passport firmware; and BTCPay Server (releases and blog).

Feeds can be filed into groups, drawn as thin boxes in the sidebar with the group's name at the top left; selecting the name lists releases from all its feeds. Drag anything in the sidebar to reorder it. Dropping a feed near the top or bottom edge of another row inserts it there; dropping it on the middle of a row joins that feed's group, or makes a new group with an ungrouped feed. Drop a feed on a group's name to file it there, or below the last item to take it out of its group. Right-click a feed or a group's name to move, rename or delete. New installs start with Lightning, Wallets and Hardware groups.

### Sharing your feed list

Feeds → Copy Feed List (⇧⌘C, also in the sidebar's + menu) puts your feeds on the clipboard as OPML, the standard format feed readers use for subscription lists, with groups and order kept. Paste it into a message, a gist, or another reader.

Feeds → Paste Feed List… (⇧⌘V) reads OPML from the clipboard, or plain lines of `owner/repo` or feed URLs, and asks:

- **Add** puts the feeds you don't have yet into a new Imported group. Feeds you already follow are left as they are.
- **Replace** makes the pasted list your feed list, groups included. Feeds you already follow keep their releases; feeds not in the list are removed with their releases. The dialog says how many before you choose.

pwnd scores only what the feed contains. Some projects publish little in the release itself: Bitcoin Core's GitHub release text is just download links, and its security disclosures are published at `https://bitcoincore.org/en/rss.xml`, which you can add as a feed.

## Servers

Servers track which machines run which software. Open the Servers window with Window → Servers (⌘2) or the rack button in the main toolbar.

- **Add a server:** click **New** and give it a name. The address is optional: an IPv4 or IPv6 address, or a hostname such as `node.local`. pwnd only stores and shows the address; it never connects to it.
- **Add software:** use the catalog on the right, which lists your feeds grouped as in the sidebar. Drag a row onto the server in the list or onto its Installed Software box, double-click it, or type in "Search software to add…" and press Return.
- **Running version:** type the version each server runs next to the software, or pick one from the releases pwnd has seen. It's optional. pwnd compares version numbers, not publish dates, so Bitcoin Core 32.1 is the latest even when 29.5 was published after it. Release candidates are ignored. Firmware lines in one repo, such as trezor's `core/` and `legacy/` tags or Coldcard's Q and X models, are compared only with their own line.
- **Status:** with a version set, a newer release in the same series (29.4 → 29.5) is an update, and a newer series alone (29.5 → 32.1) shows as "newer versions available". Without a version, status counts New releases. News feeds such as a project blog have no versions, so they always count New posts. With severity tags on (Settings → Display), critical releases show as security updates.
- **Main sidebar:** once you have a server, a Servers section appears under All Feeds. Selecting a server lists the releases of its software; double-click it, or use Open in Servers, to edit it.
- **Removing:** removing a server leaves its feeds subscribed. Unsubscribing a feed, or replacing the feed list, takes it off every server.

## How scoring works

Each entry's title and notes are checked against three keyword lists, editable in Settings → Keywords:

| List | Effect | Examples |
|---|---|---|
| Critical | One match anywhere → CRITICAL | `vulnerab`, `/CVE-\d{4}-\d+/`, GHSA ids, `exploit`, `funds at risk` |
| Signals | CRITICAL if one is in the title or two different ones match anywhere; otherwise IMPORTANT | `security`, `critical`, `attacker`, `advisory` |
| Important | One match anywhere → IMPORTANT | `hotfix`, `regression`, `consensus`, `breaking change` |

A fourth list, Ignore, removes phrases before matching. By default it holds `SECURITY.md`, `security policy` and the footer of Bitcoin Core's release notes ("To receive security and update notifications…"), which appear in routine releases. Words in an Ignore phrase match across line breaks and Markdown, and `/…/` is a regular expression. Applying changed lists rescores every stored release.

The Critical and Important tags are hidden by default; turn on Settings → General → Show severity tags to see them, with a severity filter above the list, the box explaining each level and the matched words highlighted in the notes. Releases are scored and critical ones notify either way.

Signal words inside a short fixed list of negated phrases, such as "no security impact" or "not a security fix", do not count. Critical keywords always count, so "no security impact; fixes CVE-…" stays critical.

Matching is case-insensitive and anchored at the start of a word, so `vulnerab` matches "vulnerability" and `sec` does not match "insecure". A line wrapped in slashes is a regular expression. Changing a list rescores every stored entry, and the detail pane shows which keywords matched.

The signals tier exists because "security" on its own is too noisy: with a single tier, a customer-story blog post that mentioned security scored critical.

### Evidence beyond the feed

Feed text is often thin: Bitcoin Core's GitHub release text is only download links. For new releases on GitHub feeds, pwnd also fetches:

- the full release notes from GitHub's API, which also shows whether the entry is a published release or only a tag (GitHub's releases feed lists bare tags, and projects such as Bitcoin Core push tags days before the release);
- the first release-notes or changelog Markdown file the release links to, in the same repository only;
- the repository's published GitHub security advisories, every 6 hours. An advisory applies when it lists the release's tag as a patched version, or the release cites its GHSA or CVE id. High and critical advisories make a release critical; others make it important.

Each source is scored and the highest result wins. The detail pane shows the release's facts (released, author, tag) and a short "Why it's critical" box with one line per source, such as "CVE-2026-98432 in feed text"; click a line to jump to that place in the notes. Details opens every match with its rule and context, and each evidence source with what was checked and what was not. Routine means nothing was found in that evidence, not that the release is safe. The ↗ button opens the release on GitHub.

When a GitHub feed is first added, its newest releases are checked too: the newest two plus any published within three days of the newest, up to six, so a batch such as Bitcoin Core's four simultaneous maintenance releases is covered. Use Fetch Evidence in Details to check any other older release, or Check Older Releases from the bell above the list.

When a feed edits an entry (a tag becoming a release, revised notes), pwnd rescores it. If any of this raises a release's severity after you first saw it, the release is marked ↑, moves back to New, and you get a "Now CRITICAL" notification. Releases from before you added the feed do not notify by default, but are still marked: change this in Settings, or per feed with the bell above its release list.

Evidence requests use GitHub's API. Without a token it allows 60 requests an hour for everything on your network; pwnd spends at most 40. With a token (Settings, from the gear at the top right) the limit is 5,000 an hour for your account and pwnd spends at most 1,000. Either way pwnd backs off when GitHub's rate-limit headers say the allowance is low and resumes the queue when it recovers. To make one, open [github.com/settings/personal-access-tokens](https://github.com/settings/personal-access-tokens), choose Generate new token with Public repositories access, then Generate token. The token is sent only to api.github.com.

#### How the token is stored

pwnd keeps the token in your login keychain, but writes and reads it through Apple's `/usr/bin/security` tool rather than the Security framework. This is what GitHub's `gh` CLI does on macOS.

The reason is signing. A keychain item records which app may read it by that app's code signature. pwnd is ad-hoc signed when you build it, so every build has a different signature, and macOS would ask for your login password after each update. An item created by `/usr/bin/security` names that tool as its reader instead; it is signed by Apple and does not change, so there is no prompt.

The trade-off is the same as gh's: any program running as your user can ask `security` for the token without a prompt. The token itself can only read public repositories. pwnd passes the token to `security` on standard input, so it never appears in the process list, and Reset pwnd or Remove deletes it. To inspect or delete it by hand, look for "pwnd GitHub token" (service `pwnd-github-token`) in Keychain Access.

Each release list is split in two fixed panes that scroll separately: New at the top and Old below. Releases arrive in New. The arrow at the end of a row moves it to Old (down) or back to New (up), and you can drag releases onto the other pane. ⌘-click and ⇧-click select several in one pane, to move or drag them together. The arrow in the middle of the dividing line moves everything in New to Old; it asks for a second click to confirm. Sidebar counts are new releases.

Above the release list, one row holds the severity filter and the selected feed's actions. The bell sets whether releases from before you added the feed may alert, and can check those releases now; choosing to alert also checks them. The ⋯ menu moves, copies or unsubscribes the feed. Search is in the toolbar, next to the gear for Settings. While releases are being checked, a spinner shows on that release and its feed, queued releases show a clock, and the foot of the sidebar says how many are queued and when GitHub's rate limit lets the queue resume.

To try keyword changes against live feeds without the app:

```sh
swift run pwnd-scan [--all] lightningnetwork/lnd https://blog.btcpayserver.org/rss.xml
swift run pwnd-scan --evidence 4 bitcoin/bitcoin    # also fetch notes and advisories for the newest 4
```

## Polling

- Every 15 minutes by default, one feed at a time. Settings offers 15 minutes to 3 hours, and 5 or 10 minutes with a GitHub token.
- Conditional requests (`If-None-Match` / `If-Modified-Since`): an unchanged feed returns 304 with no body.
- The first fetch of a feed puts its existing releases in New but sends no notifications, so subscribing does not fire an alert for every historic release. Later releases also arrive in New. Critical ones notify, and important ones too if enabled in Settings. At most five notifications per feed per poll, then a summary.
- At most 200 entries are kept per feed.

Feeds, entries and settings are stored in one JSON file, `~/Library/Application Support/pwnd/state.json`. To start over, choose pwnd → Reset pwnd…, which deletes that file, the remembered list filters and delivered notifications, then reloads the default feeds. It keeps the count of recent GitHub requests so the re-fetch stays within GitHub's hourly limit. Notification permission is managed in System Settings → Notifications.

## Layout

| Path | Contents |
|---|---|
| `Sources/PwndCore/` | Feed parser, classifier, fetcher, merge and persistence. No UI. |
| `Sources/Pwnd/` | SwiftUI app: window, menu bar item, settings, notifications |
| `Sources/pwnd-scan/` | Command-line scorer for tuning keywords |
| `Tests/PwndCoreTests/` | Unit tests for the core |
| `scripts/build-app.sh` | Builds `build/pwnd.app` |
| `scripts/make-icon.swift` | Draws `scripts/AppIcon.icns` from `scripts/AppIcon.svg` |
