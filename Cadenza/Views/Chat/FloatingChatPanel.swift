import SwiftUI

// MARK: - Chat Sidebar State
//
// The expanded AI chat is an IN-WINDOW right-side sidebar (Craft-style), mounted inline in
// `MainWorkspaceView` as a sibling of the `NavigationSplitView` (NOT inside ContentView's
// overlay). Its streaming @State lives in `FloatingChatPanelRoot`'s subtree and never touches
// the recordings grid's `overlayPreferenceValue(CardFrameKey)` chain — so the 0.1s streaming
// commits no longer re-run the grid's anchorPreference reduction + re-measure (the old
// main-thread hang; see ARCHITECTURE §12.2). This replaces the previous isolated-NSPanel
// approach: the GraphHost isn't physically separate anymore, but the sibling-subtree topology
// keeps streaming invalidation off the grid, and SwiftUI's native `.move(edge:.trailing)`
// transition gives a clean slide that an NSPanel could never do.

/// Holds only the expand/collapse state for the in-window chat sidebar. `@Observable @MainActor`,
/// held by `AppState`. `MainWorkspaceView` reads `isExpanded` to show/hide the sidebar with a
/// SwiftUI transition; the capsule button and the panel's close/Esc drive expand()/collapse().
@Observable @MainActor
final class FloatingChatPanelController {
    /// Whether the chat sidebar is currently shown. Drives the capsule's hide and the sidebar's
    /// slide-in transition.
    private(set) var isExpanded = false

    /// Show the sidebar. (Takes `appState` for call-site compatibility with the old NSPanel API;
    /// the in-window sidebar reads AppState from the environment, so it's unused here.)
    func expand(appState: AppState) { isExpanded = true }

    /// Hide the sidebar. `MainWorkspaceView`'s `if isExpanded` unmounts `FloatingChatPanelRoot`
    /// after the slide-out, so local `@State` (messages / input / stream) ends; completed turns
    /// were already persisted to `appState.chatHistory` and are restorable from history.
    func collapse() { isExpanded = false }

    func toggle(appState: AppState) { isExpanded.toggle() }

    /// Full dismissal (window/app teardown). Same effect as collapse for the in-window sidebar.
    func dismiss() { isExpanded = false }
}
