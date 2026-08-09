import Foundation
import Testing
@testable import Cadenza

/// 覆盖式页面的出口。
///
/// 详情页不在 sidebar 上，关掉它必须知道「从哪来」。旧实现两处都缺：`showDetailCloseButton`
/// 只认 recordingDetail / settings（回顾详情压根没有关闭按钮，进去就是死胡同），
/// `closeRecordingDetail()` 又硬编码回 `.allRecordings`（从回顾、文件夹、标签点进去的
/// 录音，关掉一律掉到「全部录音」）。2026-08-06 修。
@MainActor
@Suite struct NavigationReturnTests {
    /// 每一个不在 sidebar 上的页面都必须要求显式出口 —— toolbar 的关闭按钮
    /// 按这个判据显示，漏一个就意味着那个页面进去出不来。
    @Test func everyPageOffTheSidebarHasAnExit() {
        let everyDestination: [NavigationDestination] = [
            .allRecordings, .calendar, .recaps, .recapDetail(UUID()),
            .aiAssistant(), .settings, .trash, .folder(UUID()),
            .smartFolder("recent"), .tag("cycode"), .recordingDetail(UUID()),
        ]

        for destination in everyDestination where destination.sidebarDestination == nil {
            #expect(
                destination.requiresExplicitExit,
                "\(destination) 不在 sidebar 上又不要求显式出口 —— 进去就没有出口了"
            )
        }
    }

    /// 全页 AI 助手整页接管工作区，无论从哪进都要有返回按钮，
    /// 并且回到刚才那一页而不是「全部录音」。
    @Test func assistantAlwaysHasAnExitEvenFromTheSidebar() {
        #expect(NavigationDestination.aiAssistant().requiresExplicitExit)

        let state = AppState()
        state.navigate(to: .calendar)
        state.navigate(to: .aiAssistant())      // sidebar 点进去

        #expect(state.activeDestination == .aiAssistant())
        #expect(state.navigationReturnStack == [.calendar])

        state.closeDetail()
        #expect(state.activeDestination == .calendar)
    }

    /// sidebar 上连续切换不该把返回栈越堆越深。
    @Test func sidebarHoppingKeepsTheStackShallow() {
        let state = AppState()
        state.navigate(to: .calendar)
        state.navigate(to: .aiAssistant())
        state.navigate(to: .recaps)             // 普通页面：清栈
        #expect(state.navigationReturnStack.isEmpty)

        state.navigate(to: .aiAssistant())
        #expect(state.navigationReturnStack == [.recaps])
    }

    /// 带 initialQuery 的助手页收到 sidebar 那个空 query 的选中值，
    /// 仍然要认出是回声——否则又会白压一层返回栈。
    @Test func assistantEchoIgnoresTheInitialQuery() {
        let withQuery = NavigationDestination.aiAssistant(initialQuery: "cycode 迁移进度")
        #expect(withQuery.isSidebarEcho(of: .aiAssistant()))
        #expect(!withQuery.isSidebarEcho(of: .calendar))
    }

    @Test func recapDetailReturnsToTheRecapList() {
        let state = AppState()
        state.navigate(to: .recaps)

        let recapID = UUID()
        state.present(.recapDetail(recapID))
        #expect(state.activeDestination == .recapDetail(recapID))

        state.closeDetail()
        #expect(state.activeDestination == .recaps)
    }

    /// 回顾 → 回顾详情 → 录音详情，一层一层退回去，不能一步跳回根。
    @Test func nestedDetailUnwindsOneLevelAtATime() {
        let state = AppState()
        state.navigate(to: .recaps)

        let recapID = UUID()
        state.present(.recapDetail(recapID))
        state.openRecordingDetail(recordingID: UUID(), title: "Weekly sync")

        state.closeDetail()
        #expect(state.activeDestination == .recapDetail(recapID))

        state.closeDetail()
        #expect(state.activeDestination == .recaps)
    }

    @Test func recordingOpenedFromAFolderReturnsToThatFolder() {
        let state = AppState()
        let folderID = UUID()
        state.navigate(to: .folder(folderID))

        state.openRecordingDetail(recordingID: UUID(), title: nil)
        state.closeDetail()

        #expect(state.activeDestination == .folder(folderID))
    }

    /// 从当前页展开的全页 AI 助手要能回到原地——它是 sidebar 常驻项，
    /// 靠返回栈非空来决定给不给关闭按钮。
    @Test func fullPageAssistantReturnsToWhereItWasOpenedFrom() {
        let state = AppState()
        state.navigate(to: .calendar)

        state.present(.aiAssistant())
        #expect(!state.navigationReturnStack.isEmpty)

        state.closeDetail()
        #expect(state.activeDestination == .calendar)
    }

    /// sidebar 的选中值是从 `activeDestination` 反向同步出去的；那次变化回到
    /// `onChange(of: selectedDestination)` 时必须被认出是回声，否则会当成用户点了 sidebar。
    @Test func sidebarEchoIsDistinguishedFromARealClick() {
        // 全页 AI 助手在 sidebar 上有位置，所以它才会产生回声。
        #expect(NavigationDestination.aiAssistant().isSidebarEcho(of: .aiAssistant()))
        #expect(!NavigationDestination.aiAssistant().isSidebarEcho(of: .calendar))
        // 详情页不在 sidebar 上，任何 sidebar 选择都是用户的真实点击。
        #expect(!NavigationDestination.recapDetail(UUID()).isSidebarEcho(of: .recaps))
    }

    /// 走一遍 `MainWorkspaceView` 的双向同步：present 之后回声不能把返回栈冲掉，
    /// 否则全页 AI 助手的返回按钮永远不出现（返回栈空 + 它不是 detail page）。
    @Test func returnStackSurvivesSidebarSync() {
        let state = AppState()
        state.navigate(to: .calendar)
        state.present(.aiAssistant())

        // onChange(of: activeDestination) → 写 selectedDestination；
        // 再触发 onChange(of: selectedDestination) → 这一跳必须被回声判定拦下。
        if let echo = state.activeDestination.sidebarDestination,
           !state.activeDestination.isSidebarEcho(of: echo) {
            state.navigate(to: echo)
        }

        #expect(state.navigationReturnStack == [.calendar])
        state.closeDetail()
        #expect(state.activeDestination == .calendar)
    }

    /// sidebar 换的是「当前位置」，之前那条返回链就作废了。
    @Test func sidebarNavigationDropsTheReturnStack() {
        let state = AppState()
        state.navigate(to: .recaps)
        state.present(.recapDetail(UUID()))

        state.navigate(to: .calendar)
        #expect(state.navigationReturnStack.isEmpty)
    }

    /// 没有历史时（状态恢复 / 直接跳转）按页面推兜底目标，不是一律回全部录音。
    @Test func closingWithoutHistoryFallsBackPerPage() {
        let state = AppState()
        state.activeDestination = .recapDetail(UUID())
        state.closeDetail()
        #expect(state.activeDestination == .recaps)

        state.activeDestination = .recordingDetail(UUID())
        state.closeDetail()
        #expect(state.activeDestination == .allRecordings)
    }

    /// 搜索结果里点进详情、退回来，搜索词得还在（`present` 不碰 searchQuery）。
    @Test func presentingADetailKeepsTheSearchQuery() {
        let state = AppState()
        state.navigate(to: .allRecordings)
        state.searchQuery = "cycode"

        state.openRecordingDetail(recordingID: UUID(), title: nil)
        state.closeDetail()

        #expect(state.searchQuery == "cycode")
    }

    /// The NavigationStack push must leave the exact originating root mounted.
    /// Equality here is the state-identity sentinel: changing this value makes
    /// SwiftUI replace the folder/tag/recap subtree and drops its local state.
    @Test func recordingDetailKeepsItsOriginAsTheMountedBackgroundRoot() {
        let origins: [NavigationDestination] = [
            .folder(UUID()),
            .smartFolder("recent"),
            .tag("cycode"),
            .recapDetail(UUID()),
        ]

        for origin in origins {
            let state = AppState(startupPolicy: .testHost)
            state.navigate(to: origin)
            let beforePush = ContentView.rootDestination(
                for: state.activeDestination,
                returnStack: state.navigationReturnStack
            )

            state.openRecordingDetail(recordingID: UUID(), title: "Identity sentinel")
            let whilePushed = ContentView.rootDestination(
                for: state.activeDestination,
                returnStack: state.navigationReturnStack
            )

            #expect(beforePush == origin)
            #expect(whilePushed == beforePush)
        }
    }

    @Test func recordingDetailBackgroundNeverRecursesIntoAnotherDetail() {
        let folderID = UUID()
        let background = ContentView.rootDestination(
            for: .recordingDetail(UUID()),
            returnStack: [.folder(folderID), .recordingDetail(UUID())]
        )

        #expect(background == .folder(folderID))
        #expect(ContentView.rootDestination(for: .recordingDetail(UUID())) == .allRecordings)
    }

    @Test func contentViewWiresTheReturnStackIntoItsBackgroundPolicy() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/TabBar/TabContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("returnStack: appState.navigationReturnStack"))
        #expect(source.contains("for candidate in returnStack.reversed()"))
    }

    @Test func returnStackStaysBounded() {
        let state = AppState()
        for _ in 0..<40 {
            state.present(.recordingDetail(UUID()))
        }
        #expect(state.navigationReturnStack.count <= 8)
    }
}
