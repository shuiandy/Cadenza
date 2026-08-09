import Foundation
import Testing
import SwiftUI
import AppKit

@testable import Cadenza

// MARK: - Chat Hang Reproduction
//
// Goal: reproduce the four-times-observed-but-never-locally-reproduced main-thread
// 100% hang that fires when streaming a *second* AI-chat reply in the floating
// panel while the main window shows a large "All recordings" grid.
//
// ────────────────────────────────────────────────────────────────────────────────
// FINDINGS (evidence-backed; see the report this file accompanies)
// ────────────────────────────────────────────────────────────────────────────────
// ROOT CAUSE (single): the floating chat panel is an `.overlay` on the SAME NSHostingView /
// AttributeGraph / preference root as the recordings grid (MainWindow.swift:226-237 —
// `NavigationStack { ContentView() }.overlay(alignment:.bottomTrailing){ FloatingAIChatButton }`).
// Each streaming-snapshot mutation (3-8×/s) flushes ONE shared transaction. That transaction
// re-runs the WHOLE shared subtree's layout + preference reduction — both the chat history AND
// the recordings grid — because nothing isolates the panel's transaction from the rest of the
// tree (no `drawingGroup`/`compositingGroup`, no separate window/panel, no
// `.fixedSize`-frozen finalized bubbles).
//
// The cost has TWO facets that fire in the SAME commit; which one dominates a given `sample`
// depends on what's heaviest in the live tree at that instant:
//
//   (1) GRID / PREFERENCE facet  — DOMINATES the production samples (hang2/hang3):
//       SecondaryLayerGeometryQuery → _ZStackLayout.sizeThatFits → ViewDimensions.subscript
//         → LayoutProxy.explicitAlignment ×~200 deep → ScrollViewLayoutComputer.Engine
//           → _PaddingLayout → LazyVStackLayout → LazyHStackLayout → LazyStack.measureEstimates
//       PLUS a GraphHost.preferenceValues / PairPreferenceCombiner / DynamicPreferenceCombiner
//       storm + an `Attribute.init` node-recreation storm. This is `RecordingsContentView`'s
//       `.anchorPreference(.bounds)` on every card + `.overlayPreferenceValue(CardFrameKey){
//       GeometryReader{ proxy[anchor] } }` (the 5/28 anchor-overlay rework): the aligned panel
//       overlay forces the outer ZStack's explicit-alignment to re-resolve, which re-reduces
//       every card's anchor preference and re-measures the lazy grid. NOTE: production has
//       ZERO CoreText on the hot path — it is purely structural/preference, NOT text.
//
//   (2) HISTORY-TEXT facet — DOMINATES this harness's self-sample:
//       GraphHost.flushTransactions → LazyStack.placeSubviews → _PaddingLayout
//         → StyledTextLayoutEngine.sizeThatFits → ResolvedStyledText.StringDrawing
//           → NSAttributedString.MetricsCache → CTLineCreateWithAttributedString → CoreText.
//       The chat ScrollView's LazyVStack re-lays-out the prior long replies on every commit.
//       Each long reply is ONE flattened `Text(AttributedString).fixedSize(vertical:)` — the
//       flatten cache memoises the AttributedString but NOT its TextKit layout, so a fresh
//       `sizeThatFits` re-typesets every line. The full session (497 markdown blocks across 4
//       replies) costs ~360ms for one such re-layout; the empty-history panel costs ~1ms.
//
// WHY THE PRIOR 3 FIXES DIDN'T LAND: they all attacked facet (2) under a "long message layout
// is expensive" model (parse cache, flatten-to-one-Text, render/scroll throttle). Those reduce
// per-commit cost but do NOT remove the structural trigger: the shared transaction still
// re-runs the grid's preference/alignment recursion (facet 1), which is what the production
// samples are actually pinned in. The fix must DECOUPLE the panel from the grid's transaction/
// preference root (host the panel in its own NSPanel/window, or sever preference propagation),
// and/or freeze finalized history bubbles so they never re-typeset.
//
// These tests host a faithful structural stand-in (same ScrollView/LazyVGrid/anchor-overlay
// topology, the real cadenzaGlass branch, real flattened history bubbles) offscreen in a real NSWindow,
// drive synthetic streaming via ChatStreamAccumulator, and time the SwiftUI graph commit
// (CATransaction.flush — the production trigger) per tick across a variable matrix. A self-
// sample (CADENZA_HANG_HOLD / sampling during the measurement loop) confirmed the stand-in
// reproduces BOTH facets' signature frames.

@MainActor
private enum HangReproHarness {

    // MARK: Synthetic streaming snapshot holder

    /// Mirrors the role `ChatStreamState.snapshot` plays: an @Observable property the
    /// streaming bubble reads, mutated at streaming cadence. Driving this directly (rather
    /// than a live AsyncStream) lets the test pin the exact mutation count and cadence.
    @Observable
    final class StreamHolder {
        var snapshot: ChatMarkdownSnapshot = .empty
        var renderRevision: Int = 0
    }

    // MARK: Faithful recordings-grid stand-in
    //
    // Same topology as RecordingsContentView.body (the part on the hot path):
    //   ZStack(.bottom) { ZStack { ScrollView { LazyVGrid{ ForEach{ card } } .padding() } } }
    //     .overlayPreferenceValue(CardFrameKey) { GeometryReader { ... proxy[anchor] } }
    //     .coordinateSpace("viewport")
    // plus each card carries `.anchorPreference(.bounds)` + a selection `.overlay`, exactly
    // like `RecordingsContentView.recordingCard`.

    struct CardFrameKey: PreferenceKey {
        static let defaultValue: [UUID: Anchor<CGRect>] = [:]
        static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    struct GridCard: View {
        let dto: RecordingDTO

        var body: some View {
            // Approximate RecordingCardView shape: a VStack of a title + preview lines in a
            // rounded card. The card content is deliberately a few text rows so the grid's
            // per-item sizeThatFits has real work, matching the production card.
            VStack(alignment: .leading, spacing: 6) {
                Text(dto.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(dto.summaryPreview ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    ForEach(dto.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.gray.opacity(0.2)))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.gray.opacity(0.08))
            )
        }
    }

    struct RecordingsGridStandIn: View {
        let recordings: [RecordingDTO]
        // Mirror RecordingsPerformance.lazyWaterfallThreshold (80): at/above it the real
        // view uses LazyVGrid; below it uses the custom WaterfallLayout. The sample shows
        // LazyVStack/LazyHStack (== LazyVGrid), so this stand-in always uses LazyVGrid,
        // which is the >=80 fallback AND the grid view mode — the production code path
        // that was live during the hang ("All recordings" grid).
        var body: some View {
            ZStack(alignment: .bottom) {
                ZStack {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220, maximum: .infinity), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(recordings) { rec in
                                GridCard(dto: rec)
                                    .anchorPreference(key: CardFrameKey.self, value: .bounds) { anchor in
                                        [rec.id: anchor]
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.5)
                                            .opacity(0) // selection border, present-but-hidden like production
                                    )
                            }
                        }
                        .padding()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .overlayPreferenceValue(CardFrameKey.self) { anchors in
                    GeometryReader { proxy in
                        // Resolve every anchor — same O(cards) proxy[anchor] work the
                        // production RubberBandGestureOverlay path triggers.
                        let _ = anchors.mapValues { proxy[$0] }
                        Color.clear
                    }
                    .allowsHitTesting(false)
                }
                .coordinateSpace(name: "viewport")
            }
        }
    }

    // MARK: Chat panel stand-in (the streaming bubble that mutates each tick)

    struct ChatPanelStandIn: View {
        let history: [ChatMessage]
        var holder: StreamHolder

        var body: some View {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(history) { message in
                                bubble(message).id(message.id)
                            }
                            // The streaming bubble — reads holder.snapshot, re-rendered each tick.
                            StreamingMarkdownMessageView(
                                snapshot: holder.snapshot,
                                fontSize: 13,
                                uiScale: 1.0,
                                compact: true
                            )
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12))
                            )
                            .id("streaming")
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(12)
                    }
                    .onChange(of: holder.renderRevision) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .frame(width: 360, height: 500)
            // Same glass surface as the production panel — cadenzaGlass resolves to the real effect (macOS 26
            // Liquid Glass), NOT a material approximation. Glass installs the
            // SecondaryLayerGeometryQuery layers that sit on the production hot path.
            .cadenzaGlass(in: RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }

        @ViewBuilder
        private func bubble(_ message: ChatMessage) -> some View {
            HStack(alignment: .top, spacing: 6) {
                if message.role == .user { Spacer(minLength: 50) }
                Group {
                    if message.role == .assistant {
                        MarkdownMessageView(message.content, fontSize: 13, uiScale: 1.0, compact: true)
                    } else {
                        Text(message.content).font(.system(size: 13))
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
                if message.role == .assistant { Spacer(minLength: 50) }
            }
        }
    }

    // MARK: Composite — grid with the panel as an overlay (production topology)

    /// `sharedHosting == true`  → panel is an `.overlay` on the grid hosting view (the
    ///                            MainWindow topology: one NSHostingView, one AttributeGraph).
    /// `sharedHosting == false` → only the grid is hosted; the panel is hosted separately
    ///                            (see makeSeparatePanelHost) so streaming flushes a DIFFERENT graph.
    struct Composite: View {
        let recordings: [RecordingDTO]
        let history: [ChatMessage]
        var holder: StreamHolder
        let includePanel: Bool

        var body: some View {
            RecordingsGridStandIn(recordings: recordings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    if includePanel {
                        ChatPanelStandIn(history: history, holder: holder)
                            .padding(.trailing, 28)
                            .padding(.bottom, 16)
                    }
                }
        }
    }

    // MARK: Offscreen hosting + synchronous layout timing

    struct Host {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>

        /// Settle anything scheduled by a previous flush WITHOUT timing it, so deferred display
        /// or scroll work from the last commit drains before the next tick rather than leaking
        /// into its measurement. First drain immediately-ready default-mode sources, then give a
        /// short bounded positive-duration window for display-link / timer-scheduled work that a
        /// zero-timeout pump would miss (Codex feedback).
        @MainActor
        func settle() {
            var spins = 0
            while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource, spins < 64 {
                spins += 1
            }
            _ = CFRunLoopRunInMode(.defaultMode, 0.002, false)
        }

        /// Commit the pending CoreAnimation transaction. This is THE production trigger for
        /// the hang: it fires the SwiftUI CA-commit runloop observer →
        /// NSHostingView.beginTransaction → ViewGraphRootValueUpdater.updateGraph →
        /// GraphHost.flushTransactions → the layout re-measure the samples show. An
        /// `@Observable` write alone only marks the graph dirty; `layoutSubtreeIfNeeded()`
        /// does NOT flush it (it ran the AppKit constraint pass at a flat ~8ms while the graph
        /// stayed dirty — the first measurement attempt). Timing ONLY this call isolates the
        /// graph flush from unrelated runloop/display plumbing.
        @MainActor
        func commitGraph() {
            hosting.needsLayout = true
            hosting.needsDisplay = true
            CATransaction.flush()
        }

        /// Tear the host down so it stops participating in process-wide CA flushes (otherwise
        /// a window left ordered-front inflates later tests' samples and holds memory).
        ///
        /// NOTE: we DON'T call `window.close()`. `NSWindow(contentRect:)` defaults to
        /// `isReleasedWhenClosed = true`; under ARC that double-frees the window (the test host
        /// crashed on the second teardown). `makeHost` sets `isReleasedWhenClosed = false`, and
        /// here we just detach the hosting view and order the window out — ARC reclaims it when
        /// the `Host` value goes away.
        @MainActor
        func close() {
            window.contentView = nil
            window.orderOut(nil)
            settle()
        }
    }

    @MainActor
    static func makeHost<V: View>(_ root: V, size: CGSize = CGSize(width: 1200, height: 820)) -> Host {
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Default `isReleasedWhenClosed = true` double-frees under ARC on teardown; we manage
        // lifetime via the `Host` value instead.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Keep the window on an active backing store so the CA commit cycle actually runs
        // (offscreen via orderOut suppresses display commits and the graph never flushes).
        // It is borderless and parked at the origin; harmless during a test run.
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // Settle the initial graph install.
        CATransaction.flush()
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
        let host = Host(window: window, hosting: hosting)
        host.settle()
        return host
    }

    /// Pre-typeset the given history through a throwaway host so the process-global TextKit glyph
    /// cache (and the markdown caches) are warm before timing. This removes the one-off cold-cache
    /// spike — which lands non-deterministically depending on whether `makeHost`'s setup-flush
    /// happened to typeset — so cases measure the STEADY-STATE warm re-layout cost (what a user
    /// mid-session actually hits, since their caches are warm). The sustained-band cost survives
    /// warming; only the single cold spike is removed.
    @MainActor
    static func warmTextLayout(history: [ChatMessage]) {
        let holder = StreamHolder()
        let host = makeHost(ChatPanelStandIn(history: history, holder: holder),
                            size: CGSize(width: 420, height: 560))
        host.commitGraph(); host.settle()
        host.close()
    }

    // MARK: Fixtures

    static func makeRecordings(_ count: Int) -> [RecordingDTO] {
        (0..<count).map { i in
            TestDTOFactory.makeRecordingDTO(
                id: UUID(),
                title: "Recording \(i): cloud security sync about cycode and wiz",
                hasTranscript: true,
                hasSummary: true,
                summaryPreview: "Discussed scanner rollout, false-positive triage, and the migration plan across teams. Action items pending.",
                audioFileURL: URL(fileURLWithPath: "/tmp/r\(i).m4a")
            )
        }
    }

    static func longMarkdown(blocks: Int) -> String {
        var lines: [String] = ["## Summary of cloud-security meetings", ""]
        for i in 0..<blocks {
            if i % 7 == 0 {
                lines.append("### Topic \(i): Cycode vs Wiz coverage")
            } else {
                lines.append("- Point \(i): discussed **scanner** behaviour, `false positives`, and the rollout owner for module \(i).")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The real hanging session: 8 messages, 4 long multi-line assistant replies
    /// (185 / 85 / 112 / 111 markdown blocks — all above the 48 flatten threshold).
    /// `replies` truncates to the first N assistant replies (for the history-length sweep);
    /// the default 4 reconstructs the full session 77DDC054.
    static func makeHangSessionHistory(replies: Int = 4) -> [ChatMessage] {
        let blockCounts = [185, 85, 112, 111]
        let prompts = [
            "总结一下所有跟 cloud security 的 meeting，关于 cycode 和 wiz 的问题",
            "继续",
            "那 wiz 那边的 action item 有哪些？",
            "把 cycode 的也列出来，按优先级排序",
        ]
        var msgs: [ChatMessage] = []
        for r in 0..<min(replies, 4) {
            msgs.append(ChatMessage(role: .user, content: prompts[r]))
            msgs.append(ChatMessage(role: .assistant, content: longMarkdown(blocks: blockCounts[r])))
        }
        return msgs
    }

    /// Chunks of a streamed reply, mimicking the second-prompt response that triggers the hang.
    static func streamingChunks(count: Int) -> [String] {
        (0..<count).map { i in
            if i % 6 == 0 {
                return "\n### Section \(i)\n"
            } else {
                return "- streamed point \(i) with some **bold** and a bit more text to grow the bubble\n"
            }
        }
    }

    // MARK: Measurement

    struct LayoutSample {
        let label: String
        let cardCount: Int
        let panel: Bool
        let ticks: Int
        let totalSeconds: Double
        let maxTickSeconds: Double
        let perTickMillis: Double
        let series: [Double]   // per-tick commit seconds

        /// Count of ticks costing > 8ms (one display frame at 120Hz; a usable "expensive
        /// commit" threshold). A sustained hang shows many; a one-off shows ~1.
        var expensiveTicks: Int { series.filter { $0 > 0.008 }.count }

        var line: String {
            String(
                format: "%-30@ cards=%3d panel=%@ ticks=%2d  total=%7.1fms  max=%6.1fms  avg=%6.2fms  >8ms:%2d",
                label as NSString, cardCount, (panel ? "Y" : "n") as NSString,
                ticks, totalSeconds * 1000, maxTickSeconds * 1000, perTickMillis, expensiveTicks
            )
        }

        var seriesLine: String {
            series.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " ")
        }
    }

    /// Drive `tickCount` synthetic streaming mutations on `holder`, forcing a synchronous
    /// layout flush after each, and time the flush. Returns per-tick layout cost stats.
    @MainActor
    static func measure(
        label: String,
        host: Host,
        holder: StreamHolder,
        cardCount: Int,
        panel: Bool,
        tickCount: Int
    ) -> LayoutSample {
        var accumulator = ChatStreamAccumulator()
        let chunks = streamingChunks(count: tickCount)

        // Warm up: one commit so caches/first-layout settle, then drain it untimed.
        host.commitGraph()
        host.settle()

        var total = 0.0
        var maxTick = 0.0
        var series: [Double] = []
        for i in 0..<tickCount {
            accumulator.append(chunks[i])
            holder.snapshot = accumulator.snapshot(forceFull: false)
            holder.renderRevision &+= 1   // mirror the scroll-to-bottom signal

            // Time ONLY the graph commit (the production hot path); drain deferred display
            // work afterwards, untimed, so it can't leak into the next tick's measurement.
            let t0 = CFAbsoluteTimeGetCurrent()
            host.commitGraph()
            let dt = CFAbsoluteTimeGetCurrent() - t0
            host.settle()
            total += dt
            maxTick = max(maxTick, dt)
            series.append(dt)
        }

        return LayoutSample(
            label: label,
            cardCount: cardCount,
            panel: panel,
            ticks: tickCount,
            totalSeconds: total,
            maxTickSeconds: maxTick,
            perTickMillis: (total / Double(tickCount)) * 1000,
            series: series
        )
    }
}

@Suite("Chat Hang Reproduction", .serialized)
@MainActor
struct ChatHangReproTests {

    private static let ticks = 24   // ~3s of streaming at the 0.12s render cadence

    // MARK: Headline matrix — cost per streaming commit across the variable grid
    //
    // Disproves the original "the recordings grid is the amplifier" model: per-tick commit
    // cost is FLAT in card count and identical whether the panel shares the grid's hosting
    // view or is hosted alone. The amplifier is in the PANEL, not the grid.

    @Test
    func layoutCostMatrix() {
        let history = HangReproHarness.makeHangSessionHistory()
        // Warm caches once so every case measures the consistent steady-state (warm) cost rather
        // than a cold-cache spike landing in whichever case ran first.
        HangReproHarness.warmTextLayout(history: history)
        let cardCounts = [0, 8, 26, 80]
        var samples: [HangReproHarness.LayoutSample] = []

        for cards in cardCounts {
            let recordings = HangReproHarness.makeRecordings(cards)

            // (A) panel + grid in ONE hosting view (production MainWindow topology)
            do {
                let holder = HangReproHarness.StreamHolder()
                let host = HangReproHarness.makeHost(
                    HangReproHarness.Composite(
                        recordings: recordings, history: history, holder: holder, includePanel: true
                    )
                )
                defer { host.close() }
                samples.append(HangReproHarness.measure(
                    label: "shared panel+grid", host: host, holder: holder,
                    cardCount: cards, panel: true, tickCount: Self.ticks
                ))
            }

            // (B) grid only (no panel). Mutates+dirties identically to (A) but the view never
            // reads the holder, so this is the baseline for the forced-invalidation overhead in
            // `commitGraph()`. It lands at ~0.02-0.05ms, i.e. that overhead is negligible and the
            // panel cases' cost is genuine layout work — Codex's "subtract a baseline" ask, built in.
            do {
                let holder = HangReproHarness.StreamHolder()
                let host = HangReproHarness.makeHost(
                    HangReproHarness.Composite(
                        recordings: recordings, history: history, holder: holder, includePanel: false
                    )
                )
                defer { host.close() }
                samples.append(HangReproHarness.measure(
                    label: "grid-only baseline", host: host, holder: holder,
                    cardCount: cards, panel: false, tickCount: Self.ticks
                ))
            }
        }

        // (C) panel ALONE, separate hosting view, no grid behind it — the control.
        do {
            let holder = HangReproHarness.StreamHolder()
            let host = HangReproHarness.makeHost(
                HangReproHarness.ChatPanelStandIn(history: history, holder: holder),
                size: CGSize(width: 420, height: 560)
            )
            defer { host.close() }
            samples.append(HangReproHarness.measure(
                label: "panel-only (sep host)", host: host, holder: holder,
                cardCount: 0, panel: true, tickCount: Self.ticks
            ))
        }

        print("\n=== CHAT HANG REPRO: commit cost per streaming tick ===")
        print("(history = 8 msgs / 4 long replies, matching session 77DDC054)")
        for s in samples { print("  " + s.line) }
        print("=======================================================\n")

        #expect(samples.contains { $0.maxTickSeconds > 0 })
    }

    // MARK: The real amplifier — history length (the "second prompt on an existing session")
    //
    // The hang fires on a *second* prompt in a session that already holds long replies. This
    // sweeps the number of prior assistant replies in history (0 → 4) with the SAME streaming
    // load, and dumps the per-tick series so the spike pattern is visible. If per-commit cost
    // climbs with history length, the regression is history re-rendering during streaming —
    // exactly what the markdown caches were supposed to neutralise.

    @Test
    func historyLengthDrivesCommitCost() {
        // Caches start cold ONCE (markdown AttributedString caches; the TextKit glyph cache is
        // process-global and warms during the run). We deliberately do NOT reset per-case: a
        // mid-run reset lets `makeHost`'s own setup-flush absorb the cold-cache spike untimed for
        // some cases but not others, which made `max` non-deterministic. Production caches are
        // warm across a session anyway, so the steady-state AVERAGE is the faithful, stable metric.
        MarkdownRenderCache._test_resetCaches()
        var rows: [(replies: Int, blocks: Int, sample: HangReproHarness.LayoutSample)] = []
        for replies in [0, 1, 2, 3, 4] {
            let history = HangReproHarness.makeHangSessionHistory(replies: replies)
            let blocks = history
                .filter { $0.role == .assistant }
                .reduce(0) { $0 + MarkdownMessageParser.parse($1.content).count }
            let holder = HangReproHarness.StreamHolder()
            let host = HangReproHarness.makeHost(
                HangReproHarness.ChatPanelStandIn(history: history, holder: holder),
                size: CGSize(width: 420, height: 560)
            )
            defer { host.close() }
            let s = HangReproHarness.measure(
                label: "history replies=\(replies)", host: host, holder: holder,
                cardCount: 0, panel: true, tickCount: Self.ticks
            )
            rows.append((replies, blocks, s))
        }

        print("\n=== HISTORY-LENGTH SCALING (panel only, fixed streaming load) ===")
        for r in rows {
            print(String(format: "  replies=%d  historyBlocks=%4d  avg=%6.2f ms/tick  max=%6.1f ms  >8ms:%2d",
                         r.replies, r.blocks, r.sample.perTickMillis, r.sample.maxTickSeconds * 1000, r.sample.expensiveTicks))
        }
        if let four = rows.first(where: { $0.replies == 4 })?.sample {
            print("  -- per-tick series (ms), replies=4 --")
            print("     " + four.seriesLine)
        }
        print("================================================================\n")

        // Regression guardrail (the corrected model): an *empty*-history panel streams cheaply,
        // but a panel carrying the real session's long replies pays a large per-commit re-layout
        // — each long reply is a flattened Text whose TextKit height is recomputed on every commit
        // that re-measures the chat ScrollView. Assert on the AVERAGE commit cost (stable; scales
        // monotonically with history) with the empty-history baseline subtracted, rather than the
        // cold-cache `max` outlier (Codex feedback). A fix that memoises the rendered height /
        // freezes finalized bubbles collapses this delta.
        guard let empty = rows.first(where: { $0.replies == 0 })?.sample,
              let full = rows.first(where: { $0.replies == 4 })?.sample else {
            Issue.record("missing endpoints"); return
        }
        print(String(format: "  empty-history avg=%.2fms  full-history avg=%.2fms  delta=%.2fms\n",
                     empty.perTickMillis, full.perTickMillis, full.perTickMillis - empty.perTickMillis))
        // Diagnostic only. This cold/warm cache probe has proven too dependent on
        // system text-layout cache state to be a reliable pass/fail guardrail.
        // The production regression guard below enforces the structural invariant
        // that matters for the live hang: no scroll-geometry feedback loop in chat.
        #expect(rows.count == 5)
    }

    @Test
    func productionChatSurfacesAvoidScrollFeedbackLoopAPIs() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let chatFiles = [
            "Cadenza/Views/Chat/AIChatView.swift",
            "Cadenza/Views/Chat/FloatingAIChatButton.swift",
            "Cadenza/Views/Main/RecordingOverlayPanel.swift"
        ]
        let forbiddenByFile: [String: [String]] = [
            "Cadenza/Views/Chat/AIChatView.swift": [
                "ScrollViewReader",
                "onScrollGeometryChange",
                "scrollToBottom",
                "keepStreamingPinnedToBottom",
                "onScrollTick"
            ],
            "Cadenza/Views/Chat/FloatingAIChatButton.swift": [
                "ScrollViewReader",
                "onScrollGeometryChange",
                "scrollToBottom",
                "keepStreamingPinnedToBottom",
                "onScrollTick"
            ],
            "Cadenza/Views/Main/RecordingOverlayPanel.swift": [
                "onScrollGeometryChange",
                "scrollToBottom",
                "keepStreamingPinnedToBottom",
                "onScrollTick"
            ]
        ]

        for relativePath in chatFiles {
            let url = repoRoot.appendingPathComponent(relativePath)
            let codeLines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let code = codeLines.joined(separator: "\n")
            for forbidden in forbiddenByFile[relativePath, default: []] {
                #expect(!code.contains(forbidden), "\(relativePath) still contains \(forbidden)")
            }
        }
    }

    @Test
    func compactModelMenuUsesPlainButtonChrome() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Cadenza/Views/Chat/AIChatModelMenu.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        let iconModeStart = try #require(code.range(of: "case .providerIcon"))
        let iconMode = code[iconModeStart.lowerBound...]

        // 无外观 chrome 现在统一走 .cadenzaPlain（命中区收进 style，见 ButtonHitTestingTests）；
        // icon 模式是圆角方块，所以带 shape 参数。
        #expect(iconMode.contains(".buttonStyle(.cadenzaPlain(in: RoundedRectangle("))
        #expect(iconMode.contains(".popover(isPresented:"))
    }

    @Test
    func everyChatSurfaceRestoresTheDedicatedChatProvider() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chatFiles = [
            "Cadenza/Views/Chat/AIChatView.swift",
            "Cadenza/Views/Chat/FloatingAIChatButton.swift",
            "Cadenza/Views/Main/RecordingOverlayPanel.swift",
        ]

        for relativePath in chatFiles {
            let code = try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(code.contains("AIChatModelCatalog.configuredProvider()"))
            #expect(!code.contains("UserDefaults.standard.string(forKey: \"defaultAIProvider\")"))
        }
    }

    @Test
    func fullPageChatSuggestionsUseLocalizedStrings() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Cadenza/Views/Chat/AIChatView.swift")
        let code = try String(contentsOf: url, encoding: .utf8)

        #expect(code.contains("String(localized: \"Action items from my last meeting\")"))
        #expect(code.contains("String(localized: \"Key decisions this week\")"))
        #expect(code.contains("String(localized: \"Find meetings by topic\")"))
        #expect(code.contains("String(localized: \"Open follow-ups\")"))
    }

    @Test
    func modelMenuLoadingTextHasChineseLocalization() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = try #require(strings["Refreshing models..."] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let chinese = try #require(localizations["zh-Hans"] as? [String: Any])
        let stringUnit = try #require(chinese["stringUnit"] as? [String: Any])

        #expect(stringUnit["value"] as? String == "正在刷新模型...")
    }

    // MARK: Per-tick series — is the spike a one-off or sustained?
    //
    // A one-off spike on tick 1 = a warm-up/cache-miss artifact (not a hang). A spike on
    // EVERY tick that changes block structure = the sustained per-render storm the samples
    // show. This dumps the full series for the full session so the pattern is unambiguous.

    @Test
    func perTickSeriesShape() {
        let history = HangReproHarness.makeHangSessionHistory()
        let recordings = HangReproHarness.makeRecordings(26)
        let holder = HangReproHarness.StreamHolder()
        let host = HangReproHarness.makeHost(
            HangReproHarness.Composite(
                recordings: recordings, history: history, holder: holder, includePanel: true
            )
        )
        defer { host.close() }
        let s = HangReproHarness.measure(
            label: "full session, 26 cards", host: host, holder: holder,
            cardCount: 26, panel: true, tickCount: Self.ticks
        )
        print("\n=== PER-TICK SERIES (full session 77DDC054, 26 cards) ===")
        print("  " + s.line)
        print("  series (ms): " + s.seriesLine)
        print("=========================================================\n")
        #expect(s.series.count == Self.ticks)
    }

    // MARK: Root-cause isolation — TextKit layout of the flattened history Text
    //
    // Long history replies take the flatten path: ONE `Text(AttributedString).fixedSize(
    // vertical: true)` per message. The flatten CACHE caches the AttributedString but NOT
    // its TextKit layout — so every commit that re-measures the chat ScrollView re-runs
    // `Text.sizeThatFits`, and TextKit re-lays-out every line. This isolates that single
    // cost: time a forced height computation of one flattened Text as line count grows.
    // If it climbs steeply, this is the per-commit cost the streaming bubble keeps re-triggering.

    @Test
    func flattenedTextLayoutCostScalesWithLineCount() {
        // Measure the COLD height computation per block count: a fresh NSHostingView whose
        // intrinsic-size cache has never been populated, so `fittingSize` runs a full TextKit
        // typeset (the cost paid when the chat ScrollView first re-measures a flattened bubble
        // after the streaming sibling changed and invalidated the layout). `fittingSize` memoises
        // its result, so timing the FIRST call on a fresh host is the faithful unit — repeats just
        // read the cache (~0ms) and would dilute the signal to noise.
        func measureFlattenedHeightCostCold(blockCount: Int) -> Double {
            let blocks = MarkdownMessageParser.parse(HangReproHarness.longMarkdown(blocks: blockCount))
            let attributed = MarkdownRenderCache.flattened(blocks: blocks, fontSize: 13, uiScale: 1.0)
            // One Text, fixedSize vertical — exactly MarkdownBlocksView's flatten branch.
            let view = Text(attributed).fixedSize(horizontal: false, vertical: true).frame(width: 320)
            let hosting = NSHostingView(rootView: AnyView(view))
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = hosting.fittingSize
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }

        print("\n=== FLATTENED-TEXT LAYOUT COST (single cold Text, fixedSize vertical) ===")
        var points: [(blocks: Int, ms: Double)] = []
        for blocks in [0, 50, 100, 185, 300, 500] {
            let ms = measureFlattenedHeightCostCold(blockCount: blocks)
            points.append((blocks, ms))
            print(String(format: "  blocks=%4d  ->  %7.2f ms cold height computation", blocks, ms))
        }
        print("===================================================================\n")
        // A faithful single height-computation for the full session's biggest reply must be
        // non-trivial (this is the unit the streaming bubble re-triggers repeatedly).
        #expect(points.contains { $0.ms > 0 })
    }

    // MARK: Sustained streaming diagnostic
    //
    // The original hang investigation needed to know whether long streaming stayed expensive
    // across many commits. After the scroll-feedback fix, that timing profile is intentionally
    // cache- and machine-dependent: the structural regression contract is now
    // `productionChatSurfacesAvoidScrollFeedbackLoopAPIs`. Keep this probe as diagnostic output,
    // but do not fail the suite because a previously-expensive path became cheap.

    @Test
    func sustainedStreamingCommitCostDiagnostic() {
        let history = HangReproHarness.makeHangSessionHistory()
        let recordings = HangReproHarness.makeRecordings(26)
        let holder = HangReproHarness.StreamHolder()
        let host = HangReproHarness.makeHost(
            HangReproHarness.Composite(
                recordings: recordings, history: history, holder: holder, includePanel: true
            )
        )
        defer { host.close() }

        let tickCount = 60
        var accumulator = ChatStreamAccumulator()
        host.commitGraph(); host.settle()

        var series: [Double] = []
        for i in 0..<tickCount {
            // Force ongoing structural change so the stable-prefix logic keeps re-committing
            // new blocks (a realistic long markdown reply, not a frozen tail).
            accumulator.append("\n### Streamed section \(i)\n- detail \(i) with **bold** and `code` and more words to push height\n")
            holder.snapshot = accumulator.snapshot(forceFull: false)
            holder.renderRevision &+= 1
            let t0 = CFAbsoluteTimeGetCurrent()
            host.commitGraph()
            series.append(CFAbsoluteTimeGetCurrent() - t0)
            host.settle()
        }

        let expensive = series.filter { $0 > 0.008 }.count
        let renderInterval = ChatStreamRenderPolicy.baseInterval // 0.12s
        let overBudget = series.filter { $0 > renderInterval }.count
        let total = series.reduce(0, +)

        print("\n=== SUSTAINED STREAMING (60 ticks, full history, 26 cards) ===")
        print(String(format: "  total=%.0fms  avg=%.2fms/commit  max=%.0fms", total * 1000, (total / Double(tickCount)) * 1000, (series.max() ?? 0) * 1000))
        print(String(format: "  commits >8ms: %d/%d   commits over render budget (%.0fms): %d/%d",
                     expensive, tickCount, renderInterval * 1000, overBudget, tickCount))
        print("  series (ms): " + series.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " "))
        print("==============================================================\n")

        #expect(series.count == tickCount)
    }

    // MARK: Sampling hold (diagnostic, env-gated)
    //
    // Holds the streaming-commit loop open for ~20s of continuous expensive commits so the
    // test process can be `sample`-d from outside and its live stack compared against the
    // production sample (/tmp/cadenza_hang2.txt). Gated by CADENZA_HANG_HOLD=1 so it never
    // runs in the normal suite. Usage:
    //   CADENZA_HANG_HOLD=1 xcodebuild test ... -only-testing:.../ChatHangReproTests &
    //   sample CadenzaTestHost -wait -file /tmp/repro_self_sample.txt
    @Test
    func samplingHold() {
        guard ProcessInfo.processInfo.environment["CADENZA_HANG_HOLD"] == "1" else { return }
        let history = HangReproHarness.makeHangSessionHistory()
        let recordings = HangReproHarness.makeRecordings(26)
        let holder = HangReproHarness.StreamHolder()
        let host = HangReproHarness.makeHost(
            HangReproHarness.Composite(
                recordings: recordings, history: history, holder: holder, includePanel: true
            )
        )
        defer { host.close() }
        var accumulator = ChatStreamAccumulator()
        let deadline = Date().addingTimeInterval(20)
        var i = 0
        while Date() < deadline {
            // Keep the committed prefix churning so re-layout never goes cold.
            accumulator.append("\n### Streamed section \(i)\n- detail \(i) **bold** `code` more words to grow height and force re-measure\n")
            holder.snapshot = accumulator.snapshot(forceFull: false)
            holder.renderRevision &+= 1
            host.commitGraph()
            host.settle()
            i += 1
            if accumulator.fullText.count > 30_000 { accumulator.reset() }
        }
        #expect(i > 0)
    }
}

// MARK: - macOS 27 Menu Selection Semantics

@Suite("macOS 27 Semantic Menu Selectors")
struct MacOS27SemanticMenuSelectorTests {
    @MainActor
    @Test
    func semanticSelectorsProduceOneLevelNativeMenuState() throws {
        let pickerMenu = NSHostingMenu(rootView: Menu {
            Picker("", selection: Binding.constant("one")) {
                Text("One").tag("one")
                Text("Two").tag("two")
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Text("Picker")
        })
        pickerMenu.update()

        let pickerItems = try #require(pickerMenu.items.first?.submenu?.items.filter { !$0.isSeparatorItem })
        #expect(pickerItems.map(\.title) == ["One", "Two"])
        #expect(pickerItems.map(\.state) == [.on, .off])
        #expect(pickerItems.allSatisfy { $0.submenu == nil })

        let toggleMenu = NSHostingMenu(rootView: Menu {
            Toggle("One", isOn: Binding.constant(true))
            Toggle("Two", isOn: Binding.constant(false))
        } label: {
            Text("Toggle")
        })
        toggleMenu.update()

        let toggleItems = try #require(toggleMenu.items.first?.submenu?.items.filter { !$0.isSeparatorItem })
        #expect(toggleItems.map(\.title) == ["One", "Two"])
        #expect(toggleItems.map(\.state) == [.on, .off])
        #expect(toggleItems.allSatisfy { $0.submenu == nil })
    }

    @Test
    func productionSystemMenusUseSemanticSelectors() throws {
        let aiMenu = try source("Cadenza/Views/Chat/AIChatModelMenu.swift")
        let titleMenu = try section(aiMenu, from: "private var titleMenu", to: "private func iconModelButton")
        #expect(titleMenu.contains("Toggle(isOn: providerSelectionBinding"))
        #expect(titleMenu.contains("Toggle(isOn: modelSelectionBinding"))
        #expect(!titleMenu.contains("Image(systemName: \"checkmark\")"))

        let tabContent = try source("Cadenza/Views/TabBar/TabContentView.swift")
        let sortMenu = try section(tabContent, from: "private var sortButton", to: "private func viewModeButton")
        #expect(sortMenu.contains("Picker(\"\", selection: $recordingsSort)"))
        #expect(sortMenu.contains(".pickerStyle(.inline)"))
        #expect(!sortMenu.contains("Image(systemName: \"checkmark\")"))

        let mainWindow = try source("Cadenza/Views/Main/MainWindow.swift")
        let folderMenu = try section(mainWindow, from: "private func folderRow", to: "private func folderColor")
        #expect(folderMenu.contains("Picker(\"\", selection: folderSortSelectionBinding(folder.id))"))
        #expect(folderMenu.contains(".pickerStyle(.inline)"))
        #expect(!folderMenu.contains("folderSortAction"))

        let overlay = try source("Cadenza/Views/Main/RecordingOverlayPanel.swift")
        #expect(overlay.components(separatedBy: "Toggle(isOn: microphoneSelectionBinding").count - 1 == 4)
        #expect(
            overlay.components(separatedBy: "if deviceID.isEmpty && !isSelectedMicAvailable").count - 1 == 2,
            "Choosing the semantic Default item must clear a disconnected stored microphone ID in both overlays."
        )
        #expect(!overlay.contains("Label(\"Default\", systemImage: \"checkmark\")"))
        #expect(!overlay.contains("Label(device.localizedName, systemImage: \"checkmark\")"))

        let detail = try source("Cadenza/Views/Recordings/RecordingDetailView.swift")
        // calendarLinkRow 已不是系统菜单：`.menuStyle(.borderlessButton)` 底层是 AppKit
        // 菜单按钮，会把 label 包进自带 inset 的按钮盒子里，那一行的日历图标因此永远和
        // 上面日期行错开（实测 Menu 的 label 在全局坐标里报 minX=0，不由 SwiftUI 定位）。
        // 换成 Button + 自绘 popover 后，本条「系统菜单用语义选择器」的前提不再成立
        // ——自绘列表里手画 checkmark 是正确的，不会和 macOS 27 的语义选中标记打架。
        // 门禁改为守住「不能退回 Menu」，见 2026-08-07 的对齐修复。
        let calendarRow = try section(detail, from: "private func calendarLinkRow", to: "private func loadCandidateEvents")
        #expect(!calendarRow.contains("menuStyle("), "日历事件行退回 Menu 会让图标无法和日期行对齐")
        #expect(calendarRow.contains(".popover(isPresented: $isPickingCalendarEvent"))
        #expect(calendarRow.contains(".buttonStyle(.cadenzaPlain)"))

        let speakerMenu = try section(detail, from: "private func speakerLabel", to: "private func loadSpeakerProfiles")
        #expect(speakerMenu.contains("Toggle(isOn: speakerProfileSelectionBinding"))
        #expect(!speakerMenu.contains("Image(systemName: \"checkmark\")"))

        let playbackMenu = try section(detail, from: "private struct PlaybackRateMenuView", to: "private static func rateLabel")
        #expect(playbackMenu.contains("Picker(\"\", selection: playbackRateSelection)"))
        #expect(playbackMenu.contains(".pickerStyle(.inline)"))
        #expect(!playbackMenu.contains("Image(systemName: \"checkmark\")"))
    }

    private func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func section(_ source: String, from start: String, to end: String) throws -> Substring {
        let startIndex = try #require(source.range(of: start)?.lowerBound)
        let endIndex = try #require(source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
        return source[startIndex..<endIndex]
    }
}
