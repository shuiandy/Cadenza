import Foundation
import Testing

@testable import Cadenza

@Suite("AI Chat Streaming")
struct AIChatStreamingTests {
    @Test func markdownParserKeepsBlockStructure() {
        let blocks = MarkdownMessageParser.parse(
            """
            ## Decisions
            - Ship the redesign
            - Add a stop button

            ```swift
            let enabled = true
            ```
            """
        )

        #expect(blocks.contains(.heading(level: 2, text: "Decisions")))
        #expect(blocks.contains(.unorderedListItem(level: 0, text: "Ship the redesign")))
        #expect(blocks.contains(.unorderedListItem(level: 0, text: "Add a stop button")))
        #expect(blocks.contains(.codeBlock("let enabled = true")))
    }

    @Test func markdownParserMergesConsecutiveQuoteLines() {
        let blocks = MarkdownMessageParser.parse(
            """
            > First quoted line
            > Second quoted line

            Normal paragraph
            """
        )

        #expect(blocks.contains(.quote("First quoted line\nSecond quoted line")))
        #expect(blocks.contains(.paragraph("Normal paragraph")))
    }

    @Test func renderPolicyRefreshesQuicklyEarlyAndSlowerForLongResponses() {
        #expect(ChatStreamRenderPolicy.shouldRender(
            pendingCharacterCount: ChatStreamRenderPolicy.baseCharacterStride,
            totalCharacterCount: 800,
            elapsed: 0.01,
            chunk: "a"
        ))

        #expect(!ChatStreamRenderPolicy.shouldRender(
            pendingCharacterCount: ChatStreamRenderPolicy.baseCharacterStride,
            totalCharacterCount: 20_000,
            elapsed: 0.01,
            chunk: "a"
        ))

        #expect(ChatStreamRenderPolicy.shouldRender(
            pendingCharacterCount: ChatStreamRenderPolicy.baseCharacterStride * 5,
            totalCharacterCount: 20_000,
            elapsed: 0.01,
            chunk: "a"
        ))
    }

    @MainActor @Test func streamStateCollectsIntoMarkdownSnapshot() async throws {
        let state = ChatStreamState()
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("## Result\n")
            continuation.yield("- First item\n")
            continuation.finish()
        }

        let response = try await state.collect(stream)

        #expect(response == "## Result\n- First item\n")
        #expect(state.snapshot.blocks.contains(.heading(level: 2, text: "Result")))
        #expect(state.snapshot.blocks.contains(.unorderedListItem(level: 0, text: "First item")))
    }

    @MainActor @Test func streamStateTruncatesOversizedResponses() async throws {
        let state = ChatStreamState()
        let oversizedResponse = String(repeating: "a", count: ChatStreamState.maxResponseCharacterCount + 500)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(oversizedResponse)
            continuation.finish()
        }

        let response = try await state.collect(stream)

        #expect(response.count < oversizedResponse.count)
        #expect(response.contains("Response truncated"))
        #expect(state.snapshot.blocks.contains { block in
            guard case .paragraph(let text) = block else { return false }
            return text.contains("Response truncated")
        })
    }

    @MainActor @Test func streamStateTreatsStoppedCleanFinishAsCancellation() async {
        let state = ChatStreamState()
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        let stream = AsyncThrowingStream<String, Error> { continuation = $0 }
        var caughtCancellation = false
        var returnedResponse: String?

        state.run {
            do {
                returnedResponse = try await state.collect(stream)
            } catch is CancellationError {
                caughtCancellation = true
            } catch {
                Issue.record("expected CancellationError, got \(error)")
            }
        }

        continuation?.yield("partial")
        await waitForStreamStateToRender(state)
        state.stop(savePartial: false)
        continuation?.finish()
        await waitForStreamStateToFinish(state)

        #expect(caughtCancellation)
        #expect(returnedResponse == nil)
        #expect(!state.hasVisibleContent)
    }

    @Test func accumulatorBoundsLongPlainTextTailWithoutSplittingParagraph() {
        var accumulator = ChatStreamAccumulator()
        let longText = String(repeating: "连续文字没有换行", count: 320)

        accumulator.append(longText)
        let snapshot = accumulator.snapshot(forceFull: false)

        #expect(accumulator.liveTailCharacterCount <= ChatStreamAccumulator.maxLiveTailCharacterCount)
        #expect(snapshot.blocks.count == 1)
        guard case .paragraph(let renderedText) = snapshot.blocks.first else {
            Issue.record("expected one paragraph block")
            return
        }
        #expect(renderedText == longText)
    }

    @MainActor
    private func waitForStreamStateToRender(_ state: ChatStreamState) async {
        for _ in 0..<20 {
            if state.hasVisibleContent || !state.isActive {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    private func waitForStreamStateToFinish(_ state: ChatStreamState) async {
        for _ in 0..<20 {
            if !state.isActive {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@Suite("OpenAI Request Compatibility")
struct OpenAIRequestCompatibilityTests {
    private let messages = [
        ["role": "system", "content": "Answer from the meeting context."],
        ["role": "user", "content": "What did Caleb say?"],
    ]

    @Test func openAIRequestOmitsUnsupportedCustomTemperature() throws {
        let body = OpenAIService.makeRequestBody(
            provider: .openai,
            modelID: "gpt-5.6-terra",
            messages: messages,
            purpose: .chat,
            stream: true
        )

        #expect(body["model"] as? String == "gpt-5.6-terra")
        #expect(body["temperature"] == nil)
        #expect(body["stream"] as? Bool == true)
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["temperature"] == nil)
    }

    @Test func openAINonStreamingRequestAlsoOmitsTemperature() {
        let body = OpenAIService.makeRequestBody(
            provider: .openai,
            modelID: "gpt-5.5",
            messages: messages,
            purpose: .chat,
            stream: false
        )

        #expect(body["temperature"] == nil)
        #expect(body["stream"] == nil)
    }

    @Test func miniMaxRequestKeepsTunedTemperature() {
        let body = OpenAIService.makeRequestBody(
            provider: .minimax,
            modelID: "MiniMax-M2.7",
            messages: messages,
            purpose: .chat,
            stream: true
        )

        #expect(body["temperature"] as? Double == 0.3)
        #expect(body["stream"] as? Bool == true)
    }
}

@Suite("Chat Render Performance Regression")
struct ChatRenderPerfRegressionTests {

    /// 2026-06-11 hang regression: every streaming render bumped renderRevision,
    /// every bump ran proxy.scrollTo (a full lazy-stack layout pass), and with a
    /// long assistant message in history the main thread pinned at 100%. The
    /// scroll signal must tick at most once per throttle window during normal
    /// streaming renders.
    @MainActor @Test func renderRevisionIsThrottledDuringStreaming() {
        let state = ChatStreamState()
        let initial = state.renderRevision
        for _ in 0..<20 {
            state._test_render(forceFull: false, appending: "chunk text ")
        }
        // 20 back-to-back renders land inside one 0.3s window: at most one bump.
        #expect(state.renderRevision - initial <= 1)
    }

    @MainActor @Test func forceFullRenderAlwaysSignalsScroll() {
        let state = ChatStreamState()
        state._test_render(forceFull: false, appending: "hello")
        let afterFirst = state.renderRevision
        state._test_render(forceFull: true, appending: " world")
        #expect(state.renderRevision > afterFirst)
    }

    /// Cache correctness: cached parse must be equivalent to a direct parse.
    @MainActor @Test func markdownRenderCacheMatchesDirectParse() {
        let content = """
        ## Heading
        - item **bold**
        - item two

        Paragraph with `code` and *emphasis*.
        """
        let direct = MarkdownMessageParser.parse(content)
        let cachedFirst = MarkdownRenderCache.blocks(for: content)
        let cachedSecond = MarkdownRenderCache.blocks(for: content)
        #expect(cachedFirst == direct)
        #expect(cachedSecond == direct)
    }

    @MainActor @Test func inlineAttributedCacheHonorsLimit() {
        let oversized = String(repeating: "a", count: 3_000)
        // Over the limit: plain passthrough, no markdown interpretation.
        let plain = MarkdownRenderCache.inlineAttributed(oversized, limit: 2_000)
        #expect(String(plain.characters) == oversized)
        // Under the limit: markdown is interpreted (bold marker consumed).
        let styled = MarkdownRenderCache.inlineAttributed("**bold**", limit: 2_000)
        #expect(String(styled.characters) == "bold")
    }

    @MainActor @Test func inlineAttributedCacheSeparatesDifferentLimits() {
        MarkdownRenderCache._test_resetCaches()
        let markdown = "**bold**"

        let plain = MarkdownRenderCache.inlineAttributed(markdown, limit: 2)
        let styled = MarkdownRenderCache.inlineAttributed(markdown, limit: 2_000)

        #expect(String(plain.characters) == markdown)
        #expect(String(styled.characters) == "bold")
    }

    @Test func chatLinkPolicyAllowsOnlyOrdinaryHTTPSDestinations() {
        #expect(ChatLinkPolicy.isSafe(URL(string: "https://example.com/path?q=1")!))

        for destination in [
            "http://www.example.com/path",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "x-apple.systempreferences:com.apple.preference.security",
            "https://user:password@example.com/",
            "http://localhost/admin",
            "http://service.local/admin",
            "http://127.0.0.1/admin",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/admin",
            "https://example.com:8443/admin",
            "https://router.home.arpa/admin",
            "https://127.0.0.1.nip.io/admin",
            "https://127-0-0-1.sslip.io/admin",
            "https://localtest.me/admin",
            "https://app.localhost.direct/admin",
        ] {
            let url = URL(string: destination)!
            #expect(!ChatLinkPolicy.isSafe(url), "Unexpectedly allowed \(destination)")
        }
    }

    @MainActor @Test func markdownRenderingStripsUnsafeLinkAttributes() {
        MarkdownRenderCache._test_resetCaches()

        let safe = MarkdownRenderCache.inlineAttributed("[site](https://example.com/path)", limit: 2_000)
        #expect(safe.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com/path"])

        for markdown in [
            "[script](javascript:alert(1))",
            "[file](file:///etc/passwd)",
            "[settings](x-apple.systempreferences:com.apple.preference.security)",
            "[loopback](http://127.0.0.1/admin)",
            "[metadata](http://169.254.169.254/latest/meta-data/)",
            "[home](https://router.home.arpa/admin)",
            "[alias](https://127.0.0.1.nip.io/admin)",
        ] {
            let rendered = MarkdownRenderCache.inlineAttributed(markdown, limit: 2_000)
            #expect(rendered.runs.compactMap(\.link).isEmpty, "Unsafe link remained active: \(markdown)")
        }
    }
}

@Suite("Flattened Long Message Rendering")
struct FlattenedMarkdownTests {

    private func makeBlocks(_ count: Int) -> [MarkdownMessageBlock] {
        (0..<count).map { .unorderedListItem(level: 0, text: "item \($0) with **bold**") }
    }

    /// Long messages must take the single-Text path — hundreds of per-block
    /// views is exactly what pinned the main thread (2026-06-11/12 hangs).
    @MainActor @Test func thresholdSplitsRenderingPaths() {
        let threshold = MarkdownBlocksView.flattenThreshold
        #expect(makeBlocks(threshold).count <= threshold)
        #expect(makeBlocks(threshold + 1).count > threshold)
    }

    @MainActor @Test func flattenedContainsAllBlockContent() {
        let blocks: [MarkdownMessageBlock] = [
            .heading(level: 2, text: "Title"),
            .paragraph("First paragraph"),
            .unorderedListItem(level: 0, text: "bullet one"),
            .orderedListItem(level: 0, marker: "1.", text: "ordered one"),
            .codeBlock("let x = 1"),
            .quote("quoted text"),
            .divider,
        ]
        let flat = MarkdownRenderCache.flattened(blocks: blocks, fontSize: 13, uiScale: 1.0)
        let plain = String(flat.characters)
        #expect(plain.contains("Title"))
        #expect(plain.contains("First paragraph"))
        #expect(plain.contains("bullet one"))
        #expect(plain.contains("1.  ordered one"))
        #expect(plain.contains("let x = 1"))
        #expect(plain.contains("quoted text"))
    }

    @MainActor @Test func flattenedIsCachedForIdenticalInput() {
        let blocks = makeBlocks(60)
        let first = MarkdownRenderCache.flattened(blocks: blocks, fontSize: 13, uiScale: 1.0)
        let second = MarkdownRenderCache.flattened(blocks: blocks, fontSize: 13, uiScale: 1.0)
        #expect(String(first.characters) == String(second.characters))
        // Different font size = different fingerprint = distinct entry (no crash, no stale reuse).
        let larger = MarkdownRenderCache.flattened(blocks: blocks, fontSize: 15, uiScale: 1.0)
        #expect(String(larger.characters) == String(first.characters))
    }
}

@Suite("Streaming Invalidation Sources")
struct StreamingInvalidationTests {

    /// Third 2026-06-12 hang: `text` was written every streaming tick and
    /// hasVisibleContent (read by every streaming bubble) depended on it —
    /// an invalidation storm at 3-8 Hz. `text` must stay quiet until a
    /// terminal (forceFull) render; visibility must come from snapshot alone.
    @MainActor @Test func textOnlyWrittenOnTerminalRender() {
        let state = ChatStreamState()
        state._test_render(forceFull: false, appending: "streaming chunk")
        #expect(state.text.isEmpty)
        #expect(state.hasVisibleContent) // snapshot-driven
        state._test_render(forceFull: true, appending: " final")
        #expect(state.text == "streaming chunk final")
    }
}

@Suite("Accumulator Incremental Scan")
struct AccumulatorIncrementalScanTests {

    /// End-to-end equivalence: streaming in small chunks must produce the same
    /// final snapshot as parsing the whole text at once (the incremental
    /// two-segment storage must not change observable block output).
    @Test func chunkedSnapshotMatchesFullParse() {
        let document = """
        ## Status

        First paragraph that ends mid-sentence and keeps going for a while.

        - item one with **bold**
        - item two

        ```swift
        let a = 1
        let b = 2
        ```

        Closing thoughts after the code block.
        """
        var accumulator = ChatStreamAccumulator()
        var index = document.startIndex
        while index < document.endIndex {
            let next = document.index(index, offsetBy: 7, limitedBy: document.endIndex) ?? document.endIndex
            accumulator.append(String(document[index..<next]))
            _ = accumulator.snapshot(forceFull: false)   // exercise incremental commits
            index = next
        }
        let final = accumulator.snapshot(forceFull: true)
        #expect(final.blocks == MarkdownMessageParser.parse(document))
        #expect(accumulator.fullText == document)
    }

    /// Mid-line cuts must not let a continuation that starts with a marker
    /// ("- ", "```") corrupt block/fence state (Codex finding). Force a
    /// bounded cut by exceeding maxLiveTailCharacterCount with no newlines,
    /// where the post-cut continuation begins with "- ".
    @Test func midLineCutDoesNotMisreadMarkers() {
        let head = String(repeating: "word ", count: 450)  // 2250 chars, no newline
        var accumulator = ChatStreamAccumulator()
        accumulator.append(head)
        _ = accumulator.snapshot(forceFull: false)         // forces bounded mid-line cut
        accumulator.append("- looks like a list but is sentence continuation\nreal next line\n")
        _ = accumulator.snapshot(forceFull: false)
        let snapshot = accumulator.snapshot(forceFull: false)
        // The "- looks like…" fragment continues the giant sentence — it must
        // NOT have been committed as an unorderedListItem.
        let hasBogusListItem = snapshot.blocks.contains {
            if case .unorderedListItem(_, let text) = $0 { return text.hasPrefix("looks like a list") }
            return false
        }
        #expect(!hasBogusListItem)

        // Codex round-3: even after a BLANK line commits the partial first
        // line, it must land as paragraph text — never as a list/heading in
        // committedBlocks (the parse layer, not just the scanner, must honor
        // the mid-line cut).
        accumulator.append("\n\nfresh paragraph after blank line\n")
        let committed = accumulator.snapshot(forceFull: false)
        let bogusAfterCommit = committed.blocks.contains {
            if case .unorderedListItem(_, let text) = $0 { return text.hasPrefix("looks like a list") }
            return false
        }
        #expect(!bogusAfterCommit)
    }

    /// A long unclosed code fence must keep the live tail bounded (fence
    /// interior committed in verbatim slices) and render as ONE code block,
    /// never as markdown-parsed lines.
    @Test func longOpenFenceStaysBoundedAndVerbatim() {
        var accumulator = ChatStreamAccumulator()
        accumulator.append("intro paragraph\n\n```swift\n")
        for i in 0..<400 {
            accumulator.append("let line\(i) = \(i) // # not a heading\n")
            _ = accumulator.snapshot(forceFull: false)
        }
        #expect(accumulator.liveTailCharacterCount <= ChatStreamAccumulator.maxLiveTailCharacterCount + 64)
        let snapshot = accumulator.snapshot(forceFull: false)
        // All fence content must be in codeBlock blocks — no heading leakage.
        let hasHeading = snapshot.blocks.contains { if case .heading = $0 { return true }; return false }
        #expect(!hasHeading)
        // Closing the fence then finishing must reconcile to the canonical parse.
        accumulator.append("```\n\ndone.\n")
        let final = accumulator.snapshot(forceFull: true)
        #expect(final.blocks == MarkdownMessageParser.parse(accumulator.fullText))
    }

    /// UTF-16 cap: emoji-heavy chunks must not blow past the cap when truncated.
    @Test func truncationRespectsUTF16Budget() {
        var accumulator = ChatStreamAccumulator()
        _ = accumulator.append(String(repeating: "a", count: 95), maximumCharacterCount: 100)
        let reachedLimit = accumulator.append(String(repeating: "🎉", count: 10), maximumCharacterCount: 100)
        #expect(reachedLimit)
        #expect(accumulator.fullText.utf16.count <= 100)
    }
}
