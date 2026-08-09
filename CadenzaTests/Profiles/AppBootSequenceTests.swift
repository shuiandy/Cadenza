import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Cadenza

@MainActor
struct AppBootSequenceTests {
    private func context(
        mode: ProfileBootContext.Mode, profile: Profile? = nil
    ) -> ProfileBootContext {
        ProfileBootContext(
            mode: mode, storeURL: nil, chatHistoryDirectory: nil,
            backupsDirectory: nil, profile: profile
        )
    }

    private struct TransferFixture {
        let pending: PendingTransfer
        let target: Profile
    }

    private func makeTransferFixture() -> TransferFixture {
        let now = Date(timeIntervalSince1970: 1_785_900_000)
        let local = Profile(
            id: UUID(), kind: .system, name: "Local", colorHex: nil,
            createdAt: now, lastActiveAt: now,
            audioDirectory: .init(bookmark: nil, path: "/tmp/a", kind: .appManaged),
            boundAccount: nil, lockOnSignOut: false, isLocked: false,
            storeMaterialized: true, sessionDisposition: .active
        )
        var target = local
        target.id = UUID()
        target.kind = .standard
        target.storeMaterialized = false
        return TransferFixture(
            pending: makeTestPendingTransfer(source: local, target: target),
            target: target
        )
    }

    private func makePending() -> PendingTransfer {
        makeTransferFixture().pending
    }

    /// The TestHost branch resolves without ever touching the live
    /// bootstrap (INV-8).
    @Test func testHostRunsWithoutBootstrap() {
        var bootstrapCalls = 0
        let disposition = AppBootSequence.resolve(
            isRunningTests: true,
            bootstrap: { bootstrapCalls += 1; return nil },
            runTransfer: { _ in
                Issue.record("transfer must not run in the TestHost branch")
                return .halted("unreachable")
            }
        )
        guard case .run(nil) = disposition else {
            Issue.record("expected run(nil), got \(disposition)")
            return
        }
        #expect(bootstrapCalls == 0)
    }

    @Test func profileBootRunsWithResolvedContext() {
        let resolved = context(mode: .profile(UUID()))
        let disposition = AppBootSequence.resolve(
            isRunningTests: false,
            bootstrap: { resolved },
            runTransfer: { _ in
                Issue.record("no transfer expected")
                return .halted("unreachable")
            }
        )
        guard case .run(let running) = disposition else {
            Issue.record("expected run, got \(disposition)")
            return
        }
        #expect(running == resolved)
    }

    @Test func bootHaltSurfacesReasonWithoutServices() {
        let disposition = AppBootSequence.resolve(
            isRunningTests: false,
            bootstrap: { self.context(mode: .halted(reason: "registry unreadable")) },
            runTransfer: { _ in
                Issue.record("no transfer expected")
                return .halted("unreachable")
            }
        )
        guard case .halted(let reason) = disposition else {
            Issue.record("expected halted, got \(disposition)")
            return
        }
        #expect(reason == "registry unreadable")
    }

    @Test func transferHaltSurfacesExecutorReason() {
        let disposition = AppBootSequence.resolve(
            isRunningTests: false,
            bootstrap: { self.context(mode: .transfer(self.makePending())) },
            runTransfer: { _ in .halted("target audio verification failed") }
        )
        guard case .halted(let reason) = disposition else {
            Issue.record("expected halted, got \(disposition)")
            return
        }
        #expect(reason == "target audio verification failed")
    }

    /// A completed transfer re-runs bootstrap; its only legitimate
    /// successor is the transferred target in both mode and context row.
    @Test func completedTransferRebootstrapsIntoTheTargetProfile() {
        let fixture = makeTransferFixture()
        let second = context(
            mode: .profile(fixture.target.id), profile: fixture.target
        )
        var bootstrapCalls = 0
        let first = context(mode: .transfer(fixture.pending))
        let disposition = AppBootSequence.resolve(
            isRunningTests: false,
            bootstrap: {
                bootstrapCalls += 1
                return bootstrapCalls == 1 ? first : second
            },
            runTransfer: { _ in .completed(targetProfileID: fixture.target.id) }
        )
        guard case .run(let running) = disposition else {
            Issue.record("expected run, got \(disposition)")
            return
        }
        #expect(running == second)
        #expect(bootstrapCalls == 2)
    }

    private func postTransferDisposition(
        rebootsInto makeSecond: (TransferFixture) -> ProfileBootContext?
    ) -> AppBootDisposition {
        let fixture = makeTransferFixture()
        let second = makeSecond(fixture)
        var bootstrapCalls = 0
        let first = context(mode: .transfer(fixture.pending))
        return AppBootSequence.resolve(
            isRunningTests: false,
            bootstrap: {
                bootstrapCalls += 1
                return bootstrapCalls == 1 ? first : second
            },
            runTransfer: { _ in .completed(targetProfileID: fixture.target.id) }
        )
    }

    /// Every non-target resolution after a completed transfer halts:
    /// a different profile, a matching mode without the context row, a
    /// legacy fallback, no context at all, or a persisted transfer mode.
    @Test func postTransferNonTargetResolutionsHalt() {
        let now = Date(timeIntervalSince1970: 1_785_900_000)
        let other = Profile(
            id: UUID(), kind: .standard, name: "Other", colorHex: nil,
            createdAt: now, lastActiveAt: now,
            audioDirectory: .init(bookmark: nil, path: "/tmp/b", kind: .appManaged),
            boundAccount: nil, lockOnSignOut: false, isLocked: false,
            storeMaterialized: true, sessionDisposition: .active
        )
        let outcomes: [AppBootDisposition] = [
            postTransferDisposition { _ in
                context(mode: .profile(other.id), profile: other)
            },
            postTransferDisposition { fixture in
                context(mode: .profile(fixture.target.id))
            },
            postTransferDisposition { _ in
                context(mode: .legacyFallback(reason: "migration failed"))
            },
            postTransferDisposition { _ in nil },
            postTransferDisposition { _ in
                context(mode: .transfer(makePending()))
            },
        ]
        for disposition in outcomes {
            guard case .halted(let reason) = disposition else {
                Issue.record("expected halted, got \(disposition)")
                continue
            }
            #expect(reason.contains("did not resolve the transferred profile"))
        }
    }

    /// The user-facing halt copy is deliberately independent from the
    /// developer diagnostic. A transfer can halt after durable progress,
    /// so the recovery guidance must never claim that nothing changed.
    @Test func bootHaltPresentationResolvesChineseThroughProductionPath() {
        let zh = Locale(identifier: "zh-Hans")
        #expect(BootHaltPresentation.title(locale: zh) == "Cadenza 无法安全打开你的数据")
        #expect(
            BootHaltPresentation.recoveryInstructions(locale: zh)
                == "为保护你的录音，Cadenza 已在打开资料库前停止。退出并重新打开应用即可继续；若问题持续出现，请复制诊断信息并联系支持。"
        )
        #expect(BootHaltPresentation.copyDiagnosticsLabel(locale: zh) == "复制诊断信息")
        #expect(BootHaltPresentation.copiedConfirmation(locale: zh) == "已复制")
        #expect(BootHaltPresentation.quitLabel(locale: zh) == "退出 Cadenza")
    }

    @Test func bootHaltPresentationShipsEverySupportedLocalization() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogData = try Data(contentsOf: repoRoot.appendingPathComponent(
            "Cadenza/Resources/Localizable.xcstrings"
        ))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])
        let keys = [
            "Cadenza can't open your data safely",
            "To protect your recordings, Cadenza stopped before opening your library. Quit and reopen to resume. If this keeps happening, copy the diagnostics and contact support.",
            "Copy Diagnostics",
            "Copied",
            "Quit Cadenza",
        ]
        let locales = ["de", "es", "fr", "ja", "ko", "zh-Hans"]

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in locales {
                let localization = try #require(localizations[locale] as? [String: Any])
                let unit = try #require(localization["stringUnit"] as? [String: Any])
                let value = try #require(unit["value"] as? String)
                #expect(!value.isEmpty, "missing \(locale) for boot halt key: \(key)")
            }
        }
    }

    /// Source-to-sink canary: the internal detail may propagate in memory so
    /// the user can explicitly copy it, but it is never rendered, localized,
    /// or automatically logged by either startup layer.
    @Test func internalBootDiagnosticOnlyEntersUserInitiatedClipboard() throws {
        let canary = "INTERNAL-BOOT-DIAGNOSTIC-CANARY /private/profile-registry.json"
        let disposition = AppBootSequence.resolve(
            isRunningTests: false,
            bootstrap: { self.context(mode: .halted(reason: canary)) },
            runTransfer: { _ in
                Issue.record("no transfer expected")
                return .halted("unreachable")
            }
        )
        guard case .halted(let diagnostic) = disposition else {
            Issue.record("expected halted, got \(disposition)")
            return
        }
        #expect(diagnostic == canary)

        let zh = Locale(identifier: "zh-Hans")
        let visibleCopy = [
            BootHaltPresentation.title(locale: zh),
            BootHaltPresentation.recoveryInstructions(locale: zh),
            BootHaltPresentation.copyDiagnosticsLabel(locale: zh),
            BootHaltPresentation.copiedConfirmation(locale: zh),
            BootHaltPresentation.quitLabel(locale: zh),
        ]
        #expect(visibleCopy.allSatisfy { !$0.contains(canary) })

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Cadenza/App/AppBootSequence.swift"),
            encoding: .utf8
        )
        let diagnosticUses = source.split(separator: "\n")
            .filter { $0.contains("diagnosticReason") }
        #expect(diagnosticUses.count == 4)
        #expect(source.contains("copyDiagnosticsOverride(diagnosticReason)"))
        #expect(source.contains("diagnosticsCopied = NSPasteboard.general.setString("))
        #expect(!source.contains("Text(diagnosticReason"))
        #expect(!source.contains("Label(diagnosticReason"))
        #expect(!source.contains("LocalizedBundle.string(diagnosticReason"))
        #expect(!source.contains("NSLog(\"[AppBootSequence] Boot halted: %@\""))
        #expect(!source.contains("nothing was changed"))

        let appSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )
        #expect(appSource.contains(
            "NSLog(\"[CadenzaApp] Boot halted before opening the library\")"
        ))
        let branchStart = try #require(appSource.range(of: "if case .halted(let reason) = plan"))
        let branchEnd = try #require(appSource.range(
            of: "return .halted(reason: reason)",
            range: branchStart.upperBound..<appSource.endIndex
        ))
        let haltedBranch = appSource[branchStart.lowerBound..<branchEnd.upperBound]
        #expect(!haltedBranch.contains("%@"))
        #expect(
            haltedBranch.split(separator: "\n").filter { $0.contains("reason") }.count == 2
        )
    }

    @Test func maximumSupportedScaleUsesTheStackedActionLayout() {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        #expect(abs(scale - 3.105) < 0.000_1)
        #expect(BootHaltLayoutPolicy.stacksActions(scale: scale))
        #expect(BootHaltLayoutPolicy.minimumActionHeight(scale: scale) >= 44)
    }

    @Test func bootHaltViewFitsAndExecutesRealActionsAtMaximumScaleInEveryLocale() throws {
        let productScale = UIScalePreset.large.scaleFactor
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: productScale,
            dynamicTypeSize: .accessibility5
        )
        let locales = ["de", "es", "fr", "ja", "ko", "zh-Hans"]
        let eventWindow = BootHaltButtonEventWindow.shared
        var retainedHosts: [NSView] = []
        defer { eventWindow.reset() }

        for localeIdentifier in locales {
            let diagnostic = "INTERNAL-GEOMETRY-CANARY-\(localeIdentifier)"
            let probe = BootHaltGeometryProbe()
            let actions = BootHaltButtonActionState()
            let root = BootHaltView(
                reason: diagnostic,
                productScaleOverride: productScale,
                geometryProbe: probe,
                copyDiagnosticsOverride: { reason in
                    actions.copiedDiagnostics.append(reason)
                    return false
                },
                quitOverride: {
                    actions.quitCount += 1
                }
            )
            .environment(\.dynamicTypeSize, .accessibility5)
            .environment(\.locale, Locale(identifier: localeIdentifier))
            let host = NSHostingView(rootView: root)
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()

            let fittingSize = host.fittingSize
            host.frame = NSRect(origin: .zero, size: fittingSize)
            host.layoutSubtreeIfNeeded()
            eventWindow.install(host, size: fittingSize)
            retainedHosts.append(host)

            #expect(fittingSize.width == BootHaltLayoutPolicy.width)
            #expect(fittingSize.height.isFinite)
            #expect(fittingSize.height > 0)

            let contentView = try #require(probe.view(for: .content))
            let contentFrame = contentView.convert(contentView.bounds, to: host)
            #expect(abs(contentFrame.width - fittingSize.width) < 0.5)
            #expect(abs(contentFrame.height - fittingSize.height) < 0.5)

            let copyView = try #require(probe.view(for: .copyAction))
            let quitView = try #require(probe.view(for: .quitAction))
            let copyFrame = copyView.convert(copyView.bounds, to: host)
            let quitFrame = quitView.convert(quitView.bounds, to: host)
            let actionFrames = [copyFrame, quitFrame]

            #expect(abs(copyFrame.midY - quitFrame.midY) > 1)
            for (view, frame) in zip([copyView, quitView], actionFrames) {
                #expect(frame.width > 0)
                #expect(
                    frame.height >= BootHaltLayoutPolicy.minimumActionHeight(
                        scale: effectiveScale
                    )
                )
                #expect(frame.minX >= -0.5)
                #expect(frame.minY >= -0.5)
                #expect(frame.maxX <= host.bounds.maxX + 0.5)
                #expect(frame.maxY <= host.bounds.maxY + 0.5)

                let localCenter = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
                #expect(view.hitTest(localCenter) == nil)
            }

            for (index, corner) in BootHaltControlCorner.allCases.enumerated() {
                let point = corner.point(in: copyFrame)
                let hitView = host.hitTest(point)
                #expect(hitView != nil)
                #expect(hitView !== copyView)
                #expect(hitView !== quitView)
                #expect(eventWindow.click(at: point, in: host))
                #expect(
                    actions.copiedDiagnostics
                        == Array(repeating: diagnostic, count: index + 1)
                )
            }
            #expect(actions.copiedDiagnostics == Array(repeating: diagnostic, count: 4))

            for (index, corner) in BootHaltControlCorner.allCases.enumerated() {
                let point = corner.point(in: quitFrame)
                let hitView = host.hitTest(point)
                #expect(hitView != nil)
                #expect(hitView !== copyView)
                #expect(hitView !== quitView)
                #expect(eventWindow.click(at: point, in: host))
                #expect(actions.quitCount == index + 1)
            }
            #expect(actions.quitCount == 4)
        }
    }

}

@MainActor
private final class BootHaltButtonActionState {
    var copiedDiagnostics: [String] = []
    var quitCount = 0
}

private enum BootHaltControlCorner: CaseIterable {
    case bottomLeading
    case bottomTrailing
    case topLeading
    case topTrailing

    func point(in frame: NSRect) -> NSPoint {
        // Stay inside the rounded AppKit/SwiftUI button hit shape while still
        // exercising all four edges of the reported action frame.
        let inset = min(12, max(4, min(frame.width, frame.height) * 0.2))
        switch self {
        case .bottomLeading:
            return NSPoint(x: frame.minX + inset, y: frame.minY + inset)
        case .bottomTrailing:
            return NSPoint(x: frame.maxX - inset, y: frame.minY + inset)
        case .topLeading:
            return NSPoint(x: frame.minX + inset, y: frame.maxY - inset)
        case .topTrailing:
            return NSPoint(x: frame.maxX - inset, y: frame.maxY - inset)
        }
    }
}

/// Process-lifetime hidden event surface. Keeping one alpha-zero window avoids
/// SwiftUI/NSWindow teardown races while still routing real mouse events through
/// the hosted Button controls. `reset()` removes all test content after use.
@MainActor
private final class BootHaltButtonEventWindow {
    static let shared = BootHaltButtonEventWindow()

    private let window: NSWindow
    private var nextEventNumber = 1

    private init() {
        window = BootHaltActionTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
    }

    func install(_ host: NSView, size: NSSize) {
        window.orderOut(nil)
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func click(at point: NSPoint, in host: NSView) -> Bool {
        let windowPoint = host.convert(point, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let downNumber = nextEventNumber
        let upNumber = nextEventNumber + 1
        nextEventNumber += 2

        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: downNumber,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: upNumber,
            clickCount: 1,
            pressure: 0
        ) else {
            return false
        }

        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    func reset() {
        window.orderOut(nil)
        window.contentView = NSView(frame: .zero)
    }
}

/// Borderless windows normally refuse key status. Allowing this hidden,
/// test-only surface to become key makes AppKit route its synthetic mouse
/// sequence through the same responder path as an interactive Button click.
private final class BootHaltActionTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
