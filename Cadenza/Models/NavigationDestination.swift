import Foundation

enum NavigationDestination: Hashable {
    case allRecordings
    case calendar
    case recaps
    case recapDetail(UUID)
    case aiAssistant(initialQuery: String? = nil)
    case settings
    case trash
    case folder(UUID)
    case smartFolder(String)
    case tag(String)
    case recordingDetail(UUID)

    var title: String {
        switch self {
        case .allRecordings: String(localized: "All Recordings")
        case .calendar: String(localized: "Calendar")
        case .recaps: String(localized: "Recaps")
        case .recapDetail: String(localized: "Recap")
        case .aiAssistant: String(localized: "AI Assistant")
        case .settings: String(localized: "Settings")
        case .trash: String(localized: "Trash")
        case .folder: String(localized: "Folder")
        case .smartFolder: String(localized: "Smart Folder")
        case .tag(let name): name
        case .recordingDetail: String(localized: "Recording")
        }
    }

    var icon: String {
        switch self {
        case .allRecordings: "waveform.circle"
        case .calendar: "calendar"
        case .recaps: "calendar.badge.clock"
        case .recapDetail: "calendar.badge.clock"
        case .aiAssistant: "bubble.left.and.text.bubble.right"
        case .settings: "gearshape"
        case .trash: "trash"
        case .folder: "folder"
        case .smartFolder: "sparkles"
        case .tag: "tag"
        case .recordingDetail: "waveform"
        }
    }

    /// Whether this destination uses the glass container layout.
    var usesGlassContainer: Bool {
        switch self {
        case .allRecordings, .smartFolder, .tag, .trash: return false
        default: return true
        }
    }

    /// Sidebar-visible destination (nil for recording detail / recap detail).
    var sidebarDestination: NavigationDestination? {
        if case .recordingDetail = self { return nil }
        if case .recapDetail = self { return nil }
        return self
    }

    /// toolbar 必须给出口的页面：
    /// - recordingDetail / recapDetail / settings 不在 sidebar 上，没有关闭按钮就是死胡同
    ///   （recap 详情曾经就是，2026-08-06）；
    /// - aiAssistant 虽然在 sidebar 上有位置，但它整页接管工作区，用户期待一个明确的退出
    ///   （2026-08-07）。
    ///
    /// **`sidebarDestination == nil` 的 destination 必须在这里出现**，门禁
    /// `NavigationReturnTests.everyPageOffTheSidebarHasAnExit` 会拦。
    var requiresExplicitExit: Bool {
        switch self {
        case .recordingDetail, .recapDetail, .settings, .aiAssistant: true
        default: false
        }
    }

    /// sidebar 的选中值变成 `selection` 时，这是不是当前页反向同步出去的回声？
    /// 回声不能当成用户点了 sidebar —— `navigate(to:)` 会清空返回栈，
    /// 从浮层展开的全页 AI 助手就再也回不去了。
    func isSidebarEcho(of selection: NavigationDestination) -> Bool {
        guard let position = sidebarDestination else { return false }
        // AI 助手带 `initialQuery` 关联值，而 sidebar 那一项永远是空 query 的那个，
        // 值比较会漏判——按「同一个 sidebar 位置」认。
        if case .aiAssistant = position, case .aiAssistant = selection { return true }
        return position == selection
    }

    /// 返回栈为空时（状态恢复 / 直接跳转）的兜底返回目标。
    var fallbackReturnTarget: NavigationDestination {
        switch self {
        case .recapDetail: .recaps
        default: .allRecordings
        }
    }
}
