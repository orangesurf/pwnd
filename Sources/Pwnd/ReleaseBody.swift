import PwndCore
import SwiftUI

/// The release notes, with structure kept and matched terms highlighted.
///
/// Shows GitHub's release notes when pwnd has fetched them (Markdown, so
/// headings, lists and code read as such), otherwise the feed's text, and
/// any linked notes file in a section that opens on request. A small block
/// renderer (headings, bullets, fenced code, paragraphs) with SwiftUI's
/// inline Markdown, not a full CommonMark implementation.
///
/// `jump` scrolls to the first block containing a matched term, from the
/// Why box, and briefly highlights it.
struct ReleaseBody: View {
    @EnvironmentObject private var model: AppModel
    let entry: Entry
    @Binding var jump: Jump?
    let proxy: ScrollViewProxy
    @State private var showLinked = false
    @State private var flashed: String?

    struct Jump: Equatable {
        /// The match's source: "feed text", "release notes", "linked notes", "title".
        let source: String
        let term: String
    }

    struct Source {
        let id: String
        let label: String
        let blocks: [Block]
        let link: URL?
    }

    private var primary: Source {
        if let notes = entry.evidence.first(where: { $0.kind == .releaseNotes }), !notes.text.isEmpty {
            return Source(id: "release", label: "Release notes", blocks: Self.blocks(notes.text, markdown: true), link: nil)
        }
        return Source(id: "feed", label: "Feed text", blocks: Self.blocks(entry.text, markdown: false), link: nil)
    }

    private var linked: Source? {
        guard let n = entry.evidence.first(where: { $0.kind == .linkedNotes }), !n.text.isEmpty else { return nil }
        return Source(id: "linked", label: n.title, blocks: Self.blocks(n.text, markdown: true), link: URL(string: n.source))
    }

    var body: some View {
        let main = primary
        let extra = linked
        VStack(alignment: .leading, spacing: 18) {
            section(main)
            if let extra {
                DisclosureGroup(isExpanded: $showLinked) {
                    section(extra, showLabel: false).padding(.top, 8)
                } label: {
                    Text("Linked notes · \(extra.label)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if main.blocks.isEmpty && extra == nil {
                Text("No release notes in the feed.").foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .onChange(of: jump) { _, j in
            guard let j else { return }
            perform(j, main: main, extra: extra)
            jump = nil
        }
    }

    private func section(_ src: Source, showLabel: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showLabel {
                Text(src.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(Array(src.blocks.enumerated()), id: \.offset) { i, b in
                let id = "\(src.id)-\(i)"
                view(for: b)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(flashed == id ? Color.accentColor.opacity(0.18) : Color.clear))
                    .padding(.horizontal, -6)
                    .id(id)
            }
        }
    }

    private func perform(_ j: Jump, main: Source, extra: Source?) {
        // Look first where the match was found; fall back to the other text.
        var order: [Source] = []
        if j.source == "linked notes", let extra { order = [extra, main] } else { order = [main] + (extra.map { [$0] } ?? []) }
        for src in order {
            if let i = src.blocks.firstIndex(where: { $0.plain.range(of: j.term, options: .caseInsensitive) != nil }) {
                let id = "\(src.id)-\(i)"
                if src.id == "linked" { showLinked = true }
                Task { @MainActor in
                    // Let a just-opened section lay out before scrolling to it.
                    if src.id == "linked" { try? await Task.sleep(for: .milliseconds(60)) }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    flashed = id
                    try? await Task.sleep(for: .milliseconds(1400))
                    withAnimation(.easeOut(duration: 0.4)) { if flashed == id { flashed = nil } }
                }
                return
            }
        }
    }

    // MARK: - Blocks

    enum Block {
        case heading(level: Int, text: String)
        case bullet(String)
        case code(String)
        case paragraph(String)

        var plain: String {
            switch self {
            case .heading(_, let t), .bullet(let t), .code(let t), .paragraph(let t): return t
            }
        }
    }

    static func blocks(_ text: String, markdown: Bool) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if markdown, line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if markdown, line.hasPrefix("#"), let h = line.firstIndex(where: { $0 != "#" }), line[h] == " " {
                flush()
                out.append(.heading(level: line.distance(from: line.startIndex, to: h),
                                    text: String(line[h...]).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else if markdown {
                para.append(line)
            } else {
                // Feed text: each line is already a paragraph or list line.
                flush()
                out.append(.paragraph(line))
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    @ViewBuilder func view(for b: Block) -> some View {
        switch b {
        case .heading(let level, let text):
            Text(inline(text)).font(level <= 2 ? .title3.bold() : .headline).padding(.top, 6)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).lineSpacing(3)
            }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quinary))
        case .paragraph(let text):
            Text(inline(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Inline Markdown, then a highlight on each matched term.
    func inline(_ text: String) -> AttributedString {
        var a = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        // Matched terms are highlighted only alongside the severity tags.
        guard model.settings.showSeverity else { return a }
        let plain = String(a.characters)
        for term in Set(entry.details.compactMap(\.matched)) where term.count >= 3 {
            var from = plain.startIndex
            while let r = plain.range(of: term, options: .caseInsensitive, range: from..<plain.endIndex) {
                let lo = plain.distance(from: plain.startIndex, to: r.lowerBound)
                let len = plain.distance(from: r.lowerBound, to: r.upperBound)
                let start = a.index(a.startIndex, offsetByCharacters: lo)
                let end = a.index(start, offsetByCharacters: len)
                a[start..<end].backgroundColor = entry.severity == .critical ? .red.opacity(0.3) : .orange.opacity(0.3)
                a[start..<end].inlinePresentationIntent = .stronglyEmphasized
                from = r.upperBound
            }
        }
        return a
    }
}
