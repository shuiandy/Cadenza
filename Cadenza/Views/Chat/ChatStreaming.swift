import Foundation
import SwiftUI

@MainActor @Observable
final class ChatStreamState {
    static let maxResponseCharacterCount = 40_000

    private static let responseTruncationNotice = "\n\n_Response truncated to keep Cadenza responsive._"

    private(set) var isActive = false
    private(set) var text = ""
    private(set) var snapshot = ChatMarkdownSnapshot.empty
    private(set) var renderRevision = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var accumulator = ChatStreamAccumulator()
    @ObservationIgnored private(set) var savePartialOnCancel = false
    /// Throttle for `renderRevision` (the scroll-to-bottom signal). Every bump
    /// triggers `proxy.scrollTo` in the chat views, which forces a full lazy-stack
    /// measurement pass — at the raw render cadence (~0.12s) that stacked up
    /// full-history layout passes faster than the main thread could drain them.
    @ObservationIgnored private var lastScrollSignalAt = Date.distantPast
    private static let scrollSignalInterval: TimeInterval = 0.3

    /// Streaming visibility is derived from `snapshot` only. `text` is
    /// deliberately NOT consulted: it updates once per terminal render (see
    /// `render(forceFull:)`), so reading it here would either be stale or —
    /// worse, as originally written — make every bubble observing this
    /// property invalidate on every streaming tick.
    var hasVisibleContent: Bool {
        !snapshot.blocks.isEmpty
    }

    func run(_ operation: @escaping @MainActor () async -> Void) {
        guard !isActive else { return }
        begin()
        task = Task { [weak self] in
            await operation()
            self?.finish()
        }
    }

    func stop(savePartial: Bool) {
        guard isActive else { return }
        savePartialOnCancel = savePartial
        if !savePartial {
            resetVisibleContent()
        } else {
            render(forceFull: true)
        }
        task?.cancel()
    }

    func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                let reachedLimit = accumulator.append(chunk, maximumCharacterCount: Self.maxResponseCharacterCount)

                if accumulator.shouldRender(afterAppending: chunk) {
                    render(forceFull: false)
                    // Anchor the throttle to render COMPLETION so backlogged
                    // chunks coalesce instead of each replaying a full render.
                    accumulator.noteRenderCompleted()
                    await Task.yield()
                }

                if reachedLimit {
                    NSLog("[AIChat] Response truncated at %d characters", Self.maxResponseCharacterCount)
                    accumulator.append(Self.responseTruncationNotice)
                    render(forceFull: true)
                    return accumulator.fullText
                }
            }
            try Task.checkCancellation()
        } catch {
            if savePartialOnCancel {
                render(forceFull: true)
            }
            throw error
        }

        render(forceFull: true)
        return accumulator.fullText
    }

    func currentPartialText() -> String {
        accumulator.fullText.isEmpty ? text : accumulator.fullText
    }

    private func begin() {
        task?.cancel()
        task = nil
        isActive = true
        savePartialOnCancel = false
        accumulator.reset()
        resetVisibleContent()
    }

    private func finish() {
        task = nil
        isActive = false
        savePartialOnCancel = false
        accumulator.reset()
        resetVisibleContent()
    }

    private func render(forceFull: Bool) {
        // `text` is observable and has no per-tick UI consumer (rendering uses
        // `snapshot`; hasVisibleContent is snapshot-only). Writing it every
        // streaming tick invalidated every observer 3-8×/s for nothing — the
        // third 2026-06-12 hang sampled exactly that invalidation storm. Write
        // it only at terminal renders (finish/stop/truncate).
        if forceFull {
            text = accumulator.fullText
        }

        // @Observable does no equality check on assignment — writing an equal
        // snapshot would still invalidate every bubble observing it. Skip the
        // no-op writes (common when only the unstable tail re-parsed equal).
        let next = accumulator.snapshot(forceFull: forceFull)
        if next != snapshot {
            snapshot = next
        }

        // renderRevision's only consumers are the chat views' scroll-to-bottom
        // onChange handlers; throttle it independently of the visual update so
        // scrollTo (a full-layout trigger) runs at a sustainable cadence.
        let now = Date()
        if forceFull || now.timeIntervalSince(lastScrollSignalAt) >= Self.scrollSignalInterval {
            lastScrollSignalAt = now
            renderRevision &+= 1
        }
    }

    private func resetVisibleContent() {
        text = ""
        snapshot = .empty
        renderRevision &+= 1
    }

#if DEBUG
    /// Test-only: drive the private render path directly so the scroll-signal
    /// throttle can be pinned by unit tests without a live stream.
    func _test_render(forceFull: Bool, appending chunk: String) {
        accumulator.append(chunk)
        render(forceFull: forceFull)
    }
#endif
}

struct ChatMarkdownSnapshot: Equatable, Sendable {
    static let empty = ChatMarkdownSnapshot(blocks: [])

    let blocks: [MarkdownMessageBlock]
}

struct ChatStreamAccumulator {
    static let maxLiveTailCharacterCount = 1_800

    /// Two-segment storage. `committedText` only ever grows, and only at stable
    /// block boundaries; `pendingTail` is the unstable remainder (bounded to
    /// ~maxLiveTailCharacterCount by `boundedStableEnd`). The old single
    /// `fullText` storage forced `stablePrefix` to rescan the ENTIRE response
    /// on every render tick — an O(response) per-tick cost that grew with the
    /// reply and helped pin the main thread (2026-06-12 audit, hypothesis H2).
    /// With the split, each tick scans only the bounded tail: O(1) amortized.
    private var committedText = ""
    private var pendingTail = ""
    private var committedBlocks: [MarkdownMessageBlock] = []
    private var pendingCharacterCount = 0
    private var totalCharacterCount = 0
    private var lastRenderCompletedAt = ContinuousClock.now
    /// True when `pendingTail` begins mid-line (a bounded cut at a sentence
    /// boundary rather than a real line start). The scanner must not recognize
    /// block/fence markers ("- ", "# ", "```", …) on that first partial line —
    /// doing so corrupted fence state when a continuation happened to start
    /// with a marker (Codex review finding, 2026-06-12).
    private var tailStartsMidLine = false
    /// True when `committedText` ends inside an open code fence: long fenced
    /// replies are committed in bounded verbatim slices so the live tail stays
    /// O(maxLiveTailCharacterCount) even mid-fence. The scanner resumes
    /// in-fence and the tail renders as code, never as markdown.
    private var tailContinuesCodeFence = false

    /// Full response text. O(n) concatenation — call only at terminal points
    /// (finish/stop/truncation), never per-tick.
    var fullText: String { committedText + pendingTail }

    var liveTailCharacterCount: Int { pendingTail.count }

    mutating func reset() {
        committedText = ""
        pendingTail = ""
        committedBlocks = []
        pendingCharacterCount = 0
        totalCharacterCount = 0
        lastRenderCompletedAt = ContinuousClock.now
        tailStartsMidLine = false
        tailContinuesCodeFence = false
    }

    mutating func append(_ chunk: String) {
        pendingTail.append(chunk)
        pendingCharacterCount += chunk.utf16.count
        totalCharacterCount += chunk.utf16.count
    }

    mutating func append(_ chunk: String, maximumCharacterCount: Int) -> Bool {
        // O(1) cap check via the running UTF-16 count — the old `fullText.count`
        // was an O(response) grapheme walk on EVERY chunk.
        guard totalCharacterCount < maximumCharacterCount else { return true }

        let remaining = maximumCharacterCount - totalCharacterCount
        if chunk.utf16.count <= remaining {
            append(chunk)
            return false
        }

        // Truncate by walking Characters and charging their real UTF-16 width
        // against the budget — `prefix(n)` counts graphemes and could blow past
        // the UTF-16 cap on emoji/combining-heavy content.
        var taken = ""
        var used = 0
        for character in chunk {
            let width = character.utf16.count
            if used + width > remaining { break }
            taken.append(character)
            used += width
        }
        append(taken)
        return true
    }

    mutating func shouldRender(afterAppending chunk: String) -> Bool {
        // Elapsed is measured from the COMPLETION of the previous render
        // (noteRenderCompleted), on a monotonic clock. Measuring from the
        // render *decision* (old behavior, wall clock) meant that once the
        // main thread fell behind, every backlogged chunk saw a huge elapsed
        // and replayed a full render — the saturation feedback loop from the
        // 2026-06-12 audit. Anchoring to completion paces renders to what the
        // main thread can actually drain.
        let sinceRender = ContinuousClock.now - lastRenderCompletedAt
        let elapsed = Double(sinceRender.components.seconds)
            + Double(sinceRender.components.attoseconds) / 1e18
        return ChatStreamRenderPolicy.shouldRender(
            pendingCharacterCount: pendingCharacterCount,
            totalCharacterCount: totalCharacterCount,
            elapsed: elapsed,
            chunk: chunk
        )
    }

    /// Call after the corresponding `render(...)` returns.
    mutating func noteRenderCompleted() {
        pendingCharacterCount = 0
        lastRenderCompletedAt = ContinuousClock.now
    }

    mutating func snapshot(forceFull: Bool) -> ChatMarkdownSnapshot {
        guard totalCharacterCount > 0 else { return .empty }

        if forceFull {
            let full = fullText
            committedText = full
            pendingTail = ""
            tailStartsMidLine = false
            tailContinuesCodeFence = false
            committedBlocks = MarkdownMessageParser.parse(full)
            return ChatMarkdownSnapshot(blocks: committedBlocks)
        }

        // Scan ONLY the bounded pending tail (O(maxLiveTail) per tick, not
        // O(response)). The scanner carries two pieces of cross-tick context:
        // whether the tail starts mid-line and whether it resumes inside an
        // open code fence. A single scan never mixes fence-interior and
        // markdown content in one committed slice (it stops at the boundary),
        // so each commit is either pure markdown or pure code.
        let scan = Self.scanStable(
            in: pendingTail,
            startsMidLine: tailStartsMidLine,
            startsInCodeFence: tailContinuesCodeFence
        )
        if !scan.stable.isEmpty {
            commitStable(
                scan.stable,
                asCodeFenceInterior: tailContinuesCodeFence,
                startsMidLine: tailStartsMidLine
            )
            committedText += scan.stable
            pendingTail.removeFirst(scan.stable.count)
            tailStartsMidLine = scan.endsMidLine
            tailContinuesCodeFence = scan.endsInCodeFence
        }

        let tailBlocks: [MarkdownMessageBlock]
        if pendingTail.isEmpty {
            tailBlocks = []
        } else if tailContinuesCodeFence {
            // Inside an open fence the tail is verbatim code — markdown-parsing
            // it would misread code lines as headings/lists.
            tailBlocks = [.codeBlock(pendingTail)]
        } else {
            tailBlocks = Self.parseMidLineAware(pendingTail, startsMidLine: tailStartsMidLine)
        }
        return ChatMarkdownSnapshot(blocks: mergedDisplayBlocks(with: tailBlocks))
    }

    /// Parse a slice whose first line may be the continuation of a sentence
    /// cut mid-line: that partial first line must never be interpreted as a
    /// block marker ("- ", "# ", "> ", "```") — it is forced to be paragraph
    /// text, and markdown parsing resumes from the next real line start.
    /// (Scanner-side skipping alone was not enough: the parse layer used to
    /// re-read the same partial line and could commit a bogus list/heading —
    /// Codex round-3 finding.)
    private static func parseMidLineAware(_ text: String, startsMidLine: Bool) -> [MarkdownMessageBlock] {
        guard startsMidLine, !text.isEmpty else { return MarkdownMessageParser.parse(text) }

        let head: String
        let rest: String
        if let newline = text.firstIndex(of: "\n") {
            head = String(text[..<newline])
            rest = String(text[text.index(after: newline)...])
        } else {
            head = text
            rest = ""
        }

        var blocks: [MarkdownMessageBlock] = []
        let headTrimmed = head.trimmingCharacters(in: .whitespaces)
        if !headTrimmed.isEmpty {
            blocks.append(.paragraph(head))
        }
        if !rest.isEmpty {
            blocks.append(contentsOf: MarkdownMessageParser.parse(rest))
        }
        return blocks.isEmpty ? [] : blocks
    }

    /// Commit one stable slice. `asCodeFenceInterior` means the slice came
    /// from inside an open fence: append it verbatim to the trailing code
    /// block (creating one if needed) instead of markdown-parsing code text.
    /// `startsMidLine` routes the partial first line through the mid-line-aware
    /// parser so it can never become a bogus block marker in committedBlocks.
    private mutating func commitStable(_ delta: String, asCodeFenceInterior: Bool, startsMidLine: Bool) {
        if asCodeFenceInterior {
            // A fence-interior slice may end with the closing ``` line — strip
            // it (fence markers never appear inside codeBlock content).
            var code = delta
            if let closing = Self.closingFenceRange(in: code) {
                code.removeSubrange(closing)
            }
            if case .codeBlock(let existing) = committedBlocks.last {
                committedBlocks[committedBlocks.count - 1] = .codeBlock(existing + code)
            } else if !code.isEmpty {
                committedBlocks.append(.codeBlock(code))
            }
            return
        }

        guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let parsedBlocks = Self.parseMidLineAware(delta, startsMidLine: startsMidLine)
        for (index, block) in parsedBlocks.enumerated() {
            Self.append(
                block,
                to: &committedBlocks,
                canMergeParagraph: index == 0 && Self.canMergeParagraph(across: committedText),
                separator: Self.paragraphSeparator(across: committedText)
            )
        }
    }

    /// Range covering a trailing "```" closing-fence line (plus its preceding
    /// newline) in a fence-interior slice, if present.
    private static func closingFenceRange(in code: String) -> Range<String.Index>? {
        var scanEnd = code.endIndex
        if code.hasSuffix("\n") { scanEnd = code.index(before: scanEnd) }
        guard scanEnd > code.startIndex else { return nil }

        let lastLineStart: String.Index
        if let newline = code[..<scanEnd].lastIndex(of: "\n") {
            lastLineStart = code.index(after: newline)
        } else {
            lastLineStart = code.startIndex
        }

        guard code[lastLineStart..<scanEnd].trimmingCharacters(in: .whitespaces).hasPrefix("```") else {
            return nil
        }
        // Strip the newline that precedes the closing line too, so committed
        // code text doesn't end with a dangling blank line.
        let rangeStart = lastLineStart == code.startIndex
            ? code.startIndex
            : code.index(before: lastLineStart)
        return rangeStart..<code.endIndex
    }

    struct StableScan {
        let stable: String
        let endsMidLine: Bool
        let endsInCodeFence: Bool
    }

    private static func scanStable(
        in source: String,
        startsMidLine: Bool,
        startsInCodeFence: Bool
    ) -> StableScan {
        if startsInCodeFence {
            return scanFenceInterior(in: source, startsMidLine: startsMidLine)
        }

        var safeEnd = source.startIndex
        var lineStart = source.startIndex
        var skipMarkerChecksOnThisLine = startsMidLine
        var fenceOpenLineStart: String.Index?

        while lineStart < source.endIndex {
            guard let newline = source[lineStart...].firstIndex(of: "\n") else { break }
            let line = String(source[lineStart..<newline])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let completeLineEnd = source.index(after: newline)

            if skipMarkerChecksOnThisLine {
                // Partial first line after a mid-line cut: never interpret
                // block/fence markers here; a completed partial line only
                // counts as a stable boundary when blank.
                if trimmed.isEmpty { safeEnd = completeLineEnd }
                skipMarkerChecksOnThisLine = false
            } else if trimmed.hasPrefix("```") {
                // Fence opens: markdown before it is stable; the fence itself
                // is handled either by closure within this scan or by the
                // bounded fence-interior path on a later tick. Stop the
                // markdown scan at the fence-open line.
                fenceOpenLineStart = lineStart
                break
            } else if trimmed.isEmpty || isStableBlockLine(trimmed) {
                safeEnd = completeLineEnd
            }

            lineStart = completeLineEnd
        }

        if let fenceStart = fenceOpenLineStart {
            // Everything before the fence-open line is stable markdown.
            // If the unclosed fence region grows past the live-tail bound,
            // commit the markdown now (fence handled next tick in-fence) —
            // but first check whether the fence CLOSES within the source; if
            // so the whole fenced block becomes stable via the normal path.
            if let closed = fenceClosureEnd(in: source, fenceOpenLineStart: fenceStart) {
                // Re-scan from after the closed fence for further stability.
                let after = scanStable(in: String(source[closed...]), startsMidLine: false, startsInCodeFence: false)
                let stable = String(source[..<closed]) + after.stable
                return StableScan(stable: stable, endsMidLine: after.endsMidLine, endsInCodeFence: after.endsInCodeFence)
            }
            let fenceRegionLength = source.distance(from: fenceStart, to: source.endIndex)
            if fenceRegionLength > maxLiveTailCharacterCount {
                // Commit markdown prefix + enter the fence: the fence-open
                // line itself is consumed here (it must not be re-parsed),
                // contributing no block content.
                guard let openLineNewline = source[fenceStart...].firstIndex(of: "\n") else {
                    return StableScan(stable: String(source[..<fenceStart]), endsMidLine: false, endsInCodeFence: false)
                }
                let afterOpenLine = source.index(after: openLineNewline)
                return StableScan(stable: String(source[..<afterOpenLine]), endsMidLine: false, endsInCodeFence: true)
            }
            return StableScan(stable: String(source[..<fenceStart]), endsMidLine: false, endsInCodeFence: false)
        }

        let bounded = boundedStableEnd(in: source, safeEnd: safeEnd)
        let endsMidLine = bounded > safeEnd && bounded < source.endIndex
            && source[source.index(before: bounded)] != "\n"
        return StableScan(stable: String(source[..<bounded]), endsMidLine: endsMidLine, endsInCodeFence: false)
    }

    /// Index just past the closing ``` line of a fence that OPENS at
    /// `fenceOpenLineStart`, or nil if it never closes within `source`.
    private static func fenceClosureEnd(in source: String, fenceOpenLineStart: String.Index) -> String.Index? {
        guard let openNewline = source[fenceOpenLineStart...].firstIndex(of: "\n") else { return nil }
        var lineStart = source.index(after: openNewline)
        while lineStart < source.endIndex {
            guard let newline = source[lineStart...].firstIndex(of: "\n") else { return nil }
            let trimmed = source[lineStart..<newline].trimmingCharacters(in: .whitespaces)
            let lineEnd = source.index(after: newline)
            if trimmed.hasPrefix("```") { return lineEnd }
            lineStart = lineEnd
        }
        return nil
    }

    /// Bounded scan while inside an open fence: stable up to the closing
    /// line (exits the fence), else a bounded verbatim slice at the nearest
    /// line start (or mid-line for one giant line) once the tail outgrows
    /// the live bound. Keeps long code replies O(maxLiveTail) per tick too.
    private static func scanFenceInterior(in source: String, startsMidLine: Bool) -> StableScan {
        var lineStart = source.startIndex
        var skipFirstLine = startsMidLine

        while lineStart < source.endIndex {
            guard let newline = source[lineStart...].firstIndex(of: "\n") else { break }
            let trimmed = source[lineStart..<newline].trimmingCharacters(in: .whitespaces)
            let lineEnd = source.index(after: newline)
            if skipFirstLine {
                skipFirstLine = false
            } else if trimmed.hasPrefix("```") {
                // Fence closes: everything through the closing line is stable
                // code (closing marker stripped at commit).
                return StableScan(stable: String(source[..<lineEnd]), endsMidLine: false, endsInCodeFence: false)
            }
            lineStart = lineEnd
        }

        guard source.count > maxLiveTailCharacterCount else {
            return StableScan(stable: "", endsMidLine: false, endsInCodeFence: true)
        }

        let target = source.index(source.endIndex, offsetBy: -maxLiveTailCharacterCount)
        // Prefer the nearest line start at or before target to keep slices
        // line-aligned; fall back to a mid-line cut for one enormous line.
        if let newlineBefore = source[..<target].lastIndex(of: "\n") {
            let cut = source.index(after: newlineBefore)
            if cut > source.startIndex {
                return StableScan(stable: String(source[..<cut]), endsMidLine: false, endsInCodeFence: true)
            }
        }
        return StableScan(stable: String(source[..<target]), endsMidLine: true, endsInCodeFence: true)
    }

    private static func boundedStableEnd(in source: String, safeEnd: String.Index) -> String.Index {
        guard source.distance(from: safeEnd, to: source.endIndex) > maxLiveTailCharacterCount else {
            return safeEnd
        }

        let target = source.index(source.endIndex, offsetBy: -maxLiveTailCharacterCount)
        guard target > safeEnd else { return safeEnd }

        var index = target
        while index > safeEnd {
            let previousIndex = source.index(before: index)
            let character = source[previousIndex]
            if character.isWhitespace || isSentenceBoundary(character) {
                return index
            }
            index = previousIndex
        }

        return target
    }

    private static func isSentenceBoundary(_ character: Character) -> Bool {
        switch character {
        case ".", "!", "?", ";", ":", ",", "。", "！", "？", "；", "：", "，", "、":
            return true
        default:
            return false
        }
    }

    private mutating func appendStableBlocks(from delta: String, previousCommittedText: String) {
        let parsedBlocks = MarkdownMessageParser.parse(delta)
        for (index, block) in parsedBlocks.enumerated() {
            Self.append(
                block,
                to: &committedBlocks,
                canMergeParagraph: index == 0 && Self.canMergeParagraph(across: previousCommittedText),
                separator: Self.paragraphSeparator(across: previousCommittedText)
            )
        }
    }

    private func mergedDisplayBlocks(with tailBlocks: [MarkdownMessageBlock]) -> [MarkdownMessageBlock] {
        guard !tailBlocks.isEmpty else { return committedBlocks }

        var blocks = committedBlocks
        for (index, block) in tailBlocks.enumerated() {
            // While streaming inside a long fence, the committed slices and the
            // live tail are both code — display them as ONE block, not two
            // adjacent code boxes (terminal forceFull reconciles anyway).
            if index == 0, tailContinuesCodeFence,
               case .codeBlock(let tailCode) = block,
               case .codeBlock(let committedCode) = blocks.last {
                blocks[blocks.count - 1] = .codeBlock(committedCode + tailCode)
                continue
            }
            Self.append(
                block,
                to: &blocks,
                canMergeParagraph: index == 0 && Self.canMergeParagraph(across: committedText),
                separator: Self.paragraphSeparator(across: committedText)
            )
        }
        return blocks
    }

    private static func append(
        _ block: MarkdownMessageBlock,
        to blocks: inout [MarkdownMessageBlock],
        canMergeParagraph: Bool,
        separator: String
    ) {
        if canMergeParagraph,
           case .paragraph(let existingText) = blocks.last,
           case .paragraph(let newText) = block {
            blocks[blocks.count - 1] = .paragraph(existingText + separator + newText)
        } else {
            blocks.append(block)
        }
    }

    private static func canMergeParagraph(across previousText: String) -> Bool {
        !previousText.hasSuffix("\n\n")
    }

    private static func paragraphSeparator(across previousText: String) -> String {
        previousText.hasSuffix("\n") && !previousText.hasSuffix("\n\n") ? "\n" : ""
    }

    private static func isStableBlockLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("#")
            || trimmed.hasPrefix("> ")
            || trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
            || trimmed.hasPrefix("+ ")
            || isOrderedListLine(trimmed)
            || isDivider(trimmed)
    }

    private static func isOrderedListLine(_ trimmed: String) -> Bool {
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber {
            index = trimmed.index(after: index)
        }
        guard index > trimmed.startIndex, index < trimmed.endIndex else { return false }
        let delimiter = trimmed[index]
        guard delimiter == "." || delimiter == ")" else { return false }
        let next = trimmed.index(after: index)
        return next < trimmed.endIndex && trimmed[next].isWhitespace
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        let markerCharacters = trimmed.filter { !$0.isWhitespace }
        guard markerCharacters.count >= 3 else { return false }
        return markerCharacters.allSatisfy { $0 == "-" }
            || markerCharacters.allSatisfy { $0 == "*" }
            || markerCharacters.allSatisfy { $0 == "_" }
    }
}

struct StreamingMarkdownMessageView: View {
    /// Streaming renders ONLY the most recent blocks. This is the invariant
    /// that makes per-tick render cost independent of reply length: a long
    /// reply (the 2026-06-12 hangs streamed 150+ block lists) re-typeset the
    /// ENTIRE growing message on every snapshot tick — per-block views and the
    /// flattened single-Text path both scale with total length, and once one
    /// re-typeset exceeded the render interval the commit queue only grew.
    /// With a fixed tail window the cost is O(window) forever; the full
    /// message renders exactly once, after the stream finishes, as a normal
    /// history bubble (cached, flattened when long). The window stays below
    /// MarkdownBlocksView.flattenThreshold so streaming always takes the
    /// styled per-block path.
    static let liveWindowBlockCount = 32

    let snapshot: ChatMarkdownSnapshot
    let fontSize: CGFloat
    let uiScale: CGFloat
    var compact = false

    var body: some View {
        let blocks = snapshot.blocks
        if blocks.count > Self.liveWindowBlockCount {
            VStack(alignment: .leading, spacing: compact ? 4 : 7) {
                Text(verbatim: "…")
                    .font(.cadenza(fontSize, scale: uiScale))
                    .foregroundStyle(.tertiary)
                MarkdownBlocksView(
                    blocks: Array(blocks.suffix(Self.liveWindowBlockCount)),
                    fontSize: fontSize,
                    uiScale: uiScale,
                    compact: compact
                )
            }
        } else {
            MarkdownBlocksView(blocks: blocks, fontSize: fontSize, uiScale: uiScale, compact: compact)
        }
    }
}

enum ChatStreamRenderPolicy {
    static let baseInterval: TimeInterval = 0.12
    static let baseCharacterStride = 96

    static func shouldRender(
        pendingCharacterCount: Int,
        totalCharacterCount: Int,
        elapsed: TimeInterval,
        chunk: String,
        baseInterval: TimeInterval = Self.baseInterval,
        baseCharacterStride: Int = Self.baseCharacterStride
    ) -> Bool {
        let multiplier: Double
        let strideMultiplier: Int
        switch totalCharacterCount {
        case 0..<3_000:
            multiplier = 1.0
            strideMultiplier = 1
        case 3_000..<8_000:
            multiplier = 1.6
            strideMultiplier = 2
        case 8_000..<18_000:
            multiplier = 2.4
            strideMultiplier = 3
        default:
            multiplier = 3.4
            strideMultiplier = 5
        }

        let interval = baseInterval * multiplier
        let stride = baseCharacterStride * strideMultiplier
        let newlineFlush = chunk.contains("\n") && pendingCharacterCount >= max(72, baseCharacterStride)

        return pendingCharacterCount >= stride
            || elapsed >= interval
            || newlineFlush
    }
}
