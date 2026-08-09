import Darwin
import Foundation
import SwiftUI

/// Links rendered from model output or persisted meeting content are untrusted. Leave only
/// ordinary HTTPS DNS names clickable; custom schemes, cleartext URLs, credentials, special-use
/// names, encoded-IP aliases, literals, and non-default ports can launch privileged apps or aim
/// directly at local services. This is intentionally a render-time syntax/special-use filter:
/// DNS resolution remains the external browser's responsibility and never blocks Cadenza's UI.
enum ChatLinkPolicy {
    static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.user == nil,
              url.password == nil,
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else {
            return false
        }

        guard url.port == nil || url.port == 443 else { return false }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard host.contains("."),
              !host.hasSuffix("."),
              !host.contains("%"),
              !isSpecialUseName(host),
              !isEncodedAddressAlias(host),
              !resemblesIPv4Literal(host),
              !isIPAddressLiteral(host),
              isValidDNSName(host) else {
            return false
        }
        return true
    }

    private static let specialUseSuffixes = [
        "alt", "arpa", "corp", "example", "home", "internal", "invalid", "lan",
        "local", "localdomain", "localhost", "onion", "test",
    ]

    private static let encodedAddressAliasSuffixes = [
        "lcl.host", "local.gd", "localhost.direct", "localtest.me", "lvh.me",
        "nip.io", "sslip.io", "vcap.me", "xip.io",
    ]

    private static func isSpecialUseName(_ host: String) -> Bool {
        specialUseSuffixes.contains { matchesDomain(host, suffix: $0) }
    }

    private static func isEncodedAddressAlias(_ host: String) -> Bool {
        encodedAddressAliasSuffixes.contains { matchesDomain(host, suffix: $0) }
    }

    private static func matchesDomain(_ host: String, suffix: String) -> Bool {
        host == suffix || host.hasSuffix(".\(suffix)")
    }

    private static func isIPAddressLiteral(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }

        var ipv6 = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    /// Reject abbreviated, decimal, octal-looking, and hexadecimal IPv4 spellings before DNS.
    private static func resemblesIPv4Literal(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count) else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty else { return false }
            if component.hasPrefix("0x") || component.hasPrefix("0X") {
                let digits = component.dropFirst(2)
                return !digits.isEmpty && digits.utf8.allSatisfy { byte in
                    (0x30...0x39).contains(byte)
                        || (0x41...0x46).contains(byte)
                        || (0x61...0x66).contains(byte)
                }
            }
            return component.utf8.allSatisfy { (0x30...0x39).contains($0) }
        }
    }

    private static func isValidDNSName(_ host: String) -> Bool {
        guard host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte)
                    || (0x41...0x5A).contains(byte)
                    || (0x61...0x7A).contains(byte)
                    || byte == 0x2D
            }
        }
    }
}

/// Render-side caches for chat markdown.
///
/// Message content is immutable once delivered, but SwiftUI re-evaluates bubble
/// bodies on every layout pass — and during streaming the chat list re-lays-out
/// every ~0.12–0.4s (snapshot update + scroll-to-bottom). Without these caches
/// each pass re-ran `MarkdownMessageParser.parse` over every historical message
/// AND `AttributedString(markdown:)` (an expensive Foundation parse) for every
/// block. With one long assistant reply in history, a single layout pass cost
/// more than the render interval → the main thread pinned at 100% CPU on the
/// second prompt (2026-06-11 hang, see sample in project memory).
@MainActor
enum MarkdownRenderCache {
    final class BlocksBox {
        let blocks: [MarkdownMessageBlock]
        init(_ blocks: [MarkdownMessageBlock]) { self.blocks = blocks }
    }

    final class AttributedBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let parseCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 256
        // Keys are full message bodies (40k-char cap each) — bound total bytes,
        // not just entry count, so a history of maximal replies can't pin tens
        // of MB. Cost = UTF-16 length of the source string.
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    private static let inlineCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = 4096
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    static func blocks(for content: String) -> [MarkdownMessageBlock] {
        let key = content as NSString
        if let cached = parseCache.object(forKey: key) { return cached.blocks }
        let parsed = MarkdownMessageParser.parse(content)
        parseCache.setObject(BlocksBox(parsed), forKey: key, cost: key.length)
        return parsed
    }

    static func inlineAttributed(_ string: String, limit: Int) -> AttributedString {
        let key = "\(limit)|\(string)" as NSString
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        // Over-limit strings skip markdown interpretation but still pay an O(n)
        // AttributedString copy per construction — cache those too.
        let parsed: AttributedString
        if string.count <= limit {
            parsed = (try? AttributedString(
                markdown: string,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(string)
        } else {
            parsed = AttributedString(string)
        }
        let attributed = sanitizeLinks(in: parsed)
        inlineCache.setObject(AttributedBox(attributed), forKey: key, cost: key.length)
        return attributed
    }

    private static func sanitizeLinks(in attributed: AttributedString) -> AttributedString {
        var sanitized = attributed
        let unsafeRanges = sanitized.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let destination = run.link,
                  !ChatLinkPolicy.isSafe(destination) else {
                return nil
            }
            return run.range
        }
        for range in unsafeRanges {
            sanitized[range].link = nil
        }
        return sanitized
    }

    // MARK: - Soft bold

    /// Cache for bold-softened inline strings. Keyed by fontSize+uiScale+content
    /// because the softened runs carry an explicit sized font. Separate from
    /// `inlineCache` so the size-agnostic base parse stays shared and hot.
    private static let softBoldCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = 4096
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    /// Markdown `**bold**` renders as a heavy weight that, stacked across a reply,
    /// reads as a wall of bold. This softens every strong-emphasis run to semibold
    /// (one step lighter, still a clear accent). Result is cached per (size, scale)
    /// so it never recomputes on the streaming hot path for unchanged content.
    static func inlineAttributedSoftBold(_ string: String, limit: Int, fontSize: CGFloat, uiScale: CGFloat) -> AttributedString {
        let key = "\(limit)|\(Int(fontSize * 10))|\(Int(uiScale * 100))|\(string)" as NSString
        if let cached = softBoldCache.object(forKey: key) { return cached.value }
        let softened = softenBold(inlineAttributed(string, limit: limit), fontSize: fontSize, uiScale: uiScale)
        softBoldCache.setObject(AttributedBox(softened), forKey: key, cost: key.length)
        return softened
    }

    /// Replace strong-emphasis (markdown bold) with an explicit semibold font so it
    /// reads lighter than the default bold. Ranges are collected before mutation to
    /// avoid mutating the run view mid-iteration.
    static func softenBold(_ attr: AttributedString, fontSize: CGFloat, uiScale: CGFloat) -> AttributedString {
        var out = attr
        let softFont = Font.cadenzaBody(fontSize, weight: .semibold, scale: uiScale)
        let boldRanges = out.runs
            .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { $0.range }
        for range in boldRanges {
            // Only drop strong emphasis (bold); keep `.emphasized` (italic) etc. so
            // `***bold italic***` stays italic, now at semibold instead of bold.
            out[range].inlinePresentationIntent?.remove(.stronglyEmphasized)
            out[range].font = softFont
        }
        return out
    }

    // MARK: - Flattened rendering (long messages)

    private static let flattenedCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = 64
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    /// One AttributedString for an entire long message — rendered by a single
    /// Text so the layout engine sees one view instead of hundreds. Styling is
    /// an approximation of the per-block views (prefix bullets, monospaced code,
    /// secondary-colored quotes); acceptable for the long tail that would
    /// otherwise hang the app. Cached on a fingerprint of the block contents:
    /// completed messages hit every time, a still-streaming tail just recomputes
    /// (string concatenation is milliseconds — the win is in layout, not here).
    static func flattened(blocks: [MarkdownMessageBlock], fontSize: CGFloat, uiScale: CGFloat) -> AttributedString {
        var fingerprint = Hasher()
        fingerprint.combine(blocks)
        fingerprint.combine(Int(fontSize * 10))
        fingerprint.combine(Int(uiScale * 100))
        let key = String(fingerprint.finalize()) as NSString

        if let cached = flattenedCache.object(forKey: key) { return cached.value }

        let bodySize = fontSize * uiScale
        var out = AttributedString()
        var isFirst = true

        func append(_ segment: AttributedString) {
            if !isFirst { out += AttributedString("\n\n") }
            isFirst = false
            out += segment
        }

        for block in blocks {
            switch block {
            case .paragraph(let text):
                append(softenBold(inlineAttributed(text, limit: 2_000), fontSize: fontSize, uiScale: uiScale))

            case .heading(let level, let text):
                var seg = softenBold(inlineAttributed(text, limit: 2_000), fontSize: fontSize, uiScale: uiScale)
                let headingSize = bodySize + CGFloat(max(1, 5 - level))
                seg.font = .system(size: headingSize, weight: .semibold)
                append(seg)

            case .unorderedListItem(let level, let text):
                var seg = AttributedString(String(repeating: "    ", count: level) + "•  ")
                seg += softenBold(inlineAttributed(text, limit: 2_000), fontSize: fontSize, uiScale: uiScale)
                if !isFirst { out += AttributedString("\n") }
                isFirst = false
                out += seg

            case .orderedListItem(let level, let marker, let text):
                var seg = AttributedString(String(repeating: "    ", count: level) + marker + "  ")
                seg += softenBold(inlineAttributed(text, limit: 2_000), fontSize: fontSize, uiScale: uiScale)
                if !isFirst { out += AttributedString("\n") }
                isFirst = false
                out += seg

            case .codeBlock(let code):
                var seg = AttributedString(code)
                seg.font = .system(size: max(10, (fontSize - 2) * uiScale), design: .monospaced)
                append(seg)

            case .quote(let text):
                var seg = AttributedString("❝ ") + softenBold(inlineAttributed(text, limit: 2_000), fontSize: fontSize, uiScale: uiScale)
                seg.foregroundColor = .secondary
                append(seg)

            case .divider:
                var seg = AttributedString("───")
                seg.foregroundColor = .secondary
                append(seg)
            }
        }

        flattenedCache.setObject(AttributedBox(out), forKey: key, cost: out.characters.count)
        return out
    }

#if DEBUG
    /// Test-only: clear every render cache so performance reproductions can measure cold-cache
    /// cost deterministically (NSCache eviction is otherwise nondeterministic and order-
    /// dependent across cases). Not used by production code.
    static func _test_resetCaches() {
        parseCache.removeAllObjects()
        inlineCache.removeAllObjects()
        softBoldCache.removeAllObjects()
        flattenedCache.removeAllObjects()
    }
#endif
}

struct MarkdownMessageView: View {
    let content: String
    let fontSize: CGFloat
    let uiScale: CGFloat
    let compact: Bool

    init(_ content: String, fontSize: CGFloat, uiScale: CGFloat, compact: Bool = false) {
        self.content = content
        self.fontSize = fontSize
        self.uiScale = uiScale
        self.compact = compact
    }

    var body: some View {
        MarkdownBlocksView(
            blocks: MarkdownRenderCache.blocks(for: content),
            fontSize: fontSize,
            uiScale: uiScale,
            compact: compact
        )
    }
}

struct MarkdownBlocksView: View {
    private static let maxRenderedBlocks = 500
    private static let maxInlineMarkdownCharacters = 2_000

    /// Above this block count the per-block view tree is replaced by ONE Text
    /// holding a flattened AttributedString. Each block view costs the layout
    /// engine a baseline-aligned HStack + background; a few hundred of them
    /// makes a single SwiftUI layout pass take seconds (ZStack explicitAlignment
    /// recursion — both 2026-06-11/12 main-thread 100% hangs sampled exactly
    /// this). TextKit lays out one huge attributed string in milliseconds.
    /// Typical replies stay under this and keep the fully styled rendering.
    static let flattenThreshold = 48

    let blocks: [MarkdownMessageBlock]
    let fontSize: CGFloat
    let uiScale: CGFloat
    let compact: Bool

    var body: some View {
        if blocks.count > Self.flattenThreshold {
            Text(MarkdownRenderCache.flattened(blocks: blocks, fontSize: fontSize, uiScale: uiScale))
                .font(.cadenzaBody(fontSize, scale: uiScale))
                .lineSpacing(compact ? 3 : 5)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            blockStack
        }
    }

    private var blockStack: some View {
        let visibleCount = min(blocks.count, Self.maxRenderedBlocks)

        return VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            ForEach(0..<visibleCount, id: \.self) { index in
                blockView(blocks[index])
            }

            if blocks.count > visibleCount {
                Text("Output truncated for performance.")
                    .font(.cadenza(fontSize - 1, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .lineSpacing(compact ? 3 : 5)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownMessageBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inlineAttributed(text))
                .font(.cadenzaBody(fontSize, scale: uiScale))

        case .heading(let level, let text):
            Text(inlineAttributed(text))
                .font(.cadenzaBody(headingFontSize(for: level), weight: .semibold, scale: uiScale))
                .padding(.top, compact ? 1 : 3)

        case .unorderedListItem(let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•")
                    .font(.cadenzaBody(fontSize, weight: .semibold, scale: uiScale))
                Text(inlineAttributed(text))
                    .font(.cadenzaBody(fontSize, scale: uiScale))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 12)

        case .orderedListItem(let level, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.cadenzaBody(fontSize, weight: .semibold, scale: uiScale))
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inlineAttributed(text))
                    .font(.cadenzaBody(fontSize, scale: uiScale))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 12)

        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: max(10, (fontSize - 2) * uiScale), design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 2)
                Text(inlineAttributed(text))
                    .font(.cadenzaBody(fontSize, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, compact ? 2 : 4)

        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: compact ? 96 : 160, height: 1)
                .padding(.vertical, compact ? 6 : 10)
        }
    }

    private func headingFontSize(for level: Int) -> CGFloat {
        switch level {
        case 1: fontSize + 4
        case 2: fontSize + 2
        default: fontSize + 1
        }
    }

    private func inlineAttributed(_ string: String) -> AttributedString {
        MarkdownRenderCache.inlineAttributedSoftBold(string, limit: Self.maxInlineMarkdownCharacters, fontSize: fontSize, uiScale: uiScale)
    }
}

enum MarkdownMessageBlock: Hashable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedListItem(level: Int, text: String)
    case orderedListItem(level: Int, marker: String, text: String)
    case codeBlock(String)
    case quote(String)
    case divider
}

enum MarkdownMessageParser {
    static func parse(_ source: String) -> [MarkdownMessageBlock] {
        var blocks: [MarkdownMessageBlock] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var isInCodeFence = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines.removeAll(keepingCapacity: true)
        }

        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isInCodeFence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    isInCodeFence = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushQuote()
                isInCodeFence = true
                codeLines.removeAll(keepingCapacity: true)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(.divider)
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let unordered = parseUnorderedListItem(line) {
                flushParagraph()
                flushQuote()
                blocks.append(.unorderedListItem(level: unordered.level, text: unordered.text))
                continue
            }

            if let ordered = parseOrderedListItem(line) {
                flushParagraph()
                flushQuote()
                blocks.append(.orderedListItem(level: ordered.level, marker: ordered.marker, text: ordered.text))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                quoteLines.append(text)
                continue
            }

            flushQuote()
            paragraphLines.append(line)
        }

        if isInCodeFence {
            blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
        }
        flushQuote()
        flushParagraph()

        return blocks.isEmpty ? [.paragraph(source)] : blocks
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        var index = trimmed.startIndex
        var level = 0
        while index < trimmed.endIndex, trimmed[index] == "#", level < 6 {
            level += 1
            index = trimmed.index(after: index)
        }

        guard level > 0, index < trimmed.endIndex, trimmed[index].isWhitespace else {
            return nil
        }

        let textStart = trimmed.index(after: index)
        let text = textStart < trimmed.endIndex ? String(trimmed[textStart..<trimmed.endIndex]) : ""
        return (level, text)
    }

    private static func parseUnorderedListItem(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") else {
            return nil
        }

        let level = indentationLevel(in: line)
        return (level, String(trimmed.dropFirst(2)))
    }

    private static func parseOrderedListItem(_ line: String) -> (level: Int, marker: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var numberEnd = trimmed.startIndex

        while numberEnd < trimmed.endIndex, trimmed[numberEnd].isNumber {
            numberEnd = trimmed.index(after: numberEnd)
        }

        guard numberEnd > trimmed.startIndex, numberEnd < trimmed.endIndex else {
            return nil
        }

        let delimiter = trimmed[numberEnd]
        guard delimiter == "." || delimiter == ")" else {
            return nil
        }

        let spaceIndex = trimmed.index(after: numberEnd)
        guard spaceIndex < trimmed.endIndex, trimmed[spaceIndex].isWhitespace else {
            return nil
        }

        let textStart = trimmed.index(after: spaceIndex)
        let marker = String(trimmed[trimmed.startIndex...numberEnd])
        let text = textStart < trimmed.endIndex ? String(trimmed[textStart..<trimmed.endIndex]) : ""
        return (indentationLevel(in: line), marker, text)
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        let markerCharacters = trimmed.filter { !$0.isWhitespace }
        guard markerCharacters.count >= 3 else { return false }
        return markerCharacters.allSatisfy { $0 == "-" }
            || markerCharacters.allSatisfy { $0 == "*" }
            || markerCharacters.allSatisfy { $0 == "_" }
    }

    private static func indentationLevel(in line: String) -> Int {
        let width = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { total, character in
            total + (character == "\t" ? 4 : 1)
        }
        return min(width / 2, 4)
    }
}
