import Foundation
import Testing
@testable import Cadenza

/// Localization gates for the Settings surface (including the account error
/// banner): an explicit zh-Hans checklist, plus runtime tests that drive the
/// production formatting paths — catalog-only checks cannot catch code that
/// bypasses lookup. Add new visible Settings keys to the checklist.
@Suite("Settings Localization")
struct SettingsLocalizationTests {

    private static let settingsKeysNeedingChinese: [String] = [
        "Choose",
        "Connected.",
        "Diagnostics",
        "Model",
        "Model ID for live captions. Leave empty for the default.",
        "Model ID for %@ transcription. Leave empty for the default.",
        "Model could not be deleted. Please try again.",
        "Open main window after login",
        "When Launch at login is enabled, show the main window after sign in",
        "Required for reliable Teams auto-start and auto-stop.",
        "Window-based meeting detection is available.",
        "Microphone access is required for automatic meeting recording. Auto-record stays on and will resume once access is granted.",
        "Deleted recordings move to Trash and are removed from the active library after the selected number of days. Cadenza-owned audio files and derived data are included; imported source files remain in their original location. Automatic recovery backups may retain copies until rotation or explicit deletion.",
        "AI chat searches",
        "How far back chat looks when your question doesn't name a time range. Asking e.g. \"last week\" always narrows to that period.",
        "Last 30 days",
        "Last 90 days",
        "Calendar Color",
        "Default",
        "Red",
        "Orange",
        "Yellow",
        "Green",
        "Cyan",
        "Blue",
        "Indigo",
        "Purple",
        "Pink",
        "%@ (API key missing)",
        "%@ was your default AI provider for summaries and AI chat. Because you disconnected it, the default was switched to %@.",
        "Lets connected AI tools preview and import meeting notes from other services. Imports never create duplicate entries, keep source history, and do not require provider API tokens.",
        "External import recipe",
        "Copy a preview-first prompt for your AI agent. It lists source metadata incrementally, shows a dry run, and fetches full notes only after review. Cadenza never stores your provider tokens.",
        // Storage errors (formatted via StorageSettingsMessage, tested below)
        "Failed to set directory: %@",
        "Migration error: %@",
        // Profile storage migration fallback notice
        "Storage upgrade did not complete. The app is continuing with your existing storage layout and will retry on next launch. You can export a backup anytime from Settings → General → Export & Backup.",
        // Directory-change gate and migration failures
        "Storage location can't be changed while recording or processing.",
        "\"%@\" already exists in the destination folder.",
        "Could not list the folder: %@",
        "Copy verification failed for \"%@\".",
        "The source and destination folders overlap.",
        "Recording is unavailable while the storage location is being changed.",
        "Transcription is unavailable while the storage location is being changed.",
        // Every AuthError message (rendered by AuthErrorBanner)
        "Sign-in cancelled.",
        "Couldn't open browser.",
        "Sign-in timed out.",
        "Another sign-in is already in progress.",
        "Security check failed. Please try again.",
        "Authorization was denied.",
        "Sign-in completed with an invalid response.",
        "Couldn't save your session locally.",
        "Sign-in returned an unexpected format.",
        "Your session expired — please sign in again.",
        "Your recordings move into the account profile and Local starts over empty. Nothing is uploaded by this step.",
        "Reconnect %@ to keep using it.",
        "Cadenza server error (%lld).",
        "Network error — please check your connection.",
        "Sign-in failed.",
        // The profiles/session surface key inventory: every visible
        // login, binding, consent, switcher, sign-out, and transition
        // string ships with zh-Hans (keep in step with the surface)
        "%@ — session expired, sign in to resume sync",
        "%@ — signed out",
        "A profile change didn't finish. Quit and reopen Cadenza to continue.",
        "Accounts, switching, and history sync consent",
        "All Profiles",
        "Another profile operation is in progress — try again when it finishes.",
        "Ask for this account's sign-in before opening the profile again",
        "Audio uploads also require the audio upload switch in Integrations.",
        "Cadenza can't open your data safely",
        "Cadenza couldn't pause background work — nothing changed. Try again.",
        "Cadenza couldn't restart itself. The switch was undone — please quit and reopen to try again.",
        "Cadenza will switch to that profile and restart.",
        "Copy Local Recordings",
        "Create Account Profile",
        "Current Profile",
        "Don't sync them",
        "Finish or stop the current recording before switching profiles.",
        "History Sync",
        "Include audio",
        "Keep Local Separate",
        "Link %@",
        "Link This Profile",
        "Link this profile's recordings to the account, or keep them separate in a new profile.",
        "Linking never uploads existing recordings by itself. Choose what may sync — you can change this later in Settings.",
        "Lock on sign out",
        "Locked — sign in with its account to unlock",
        "Move Local Recordings…",
        "Move recordings out of Local?",
        "Move to New Profile",
        "Not linked to an account",
        "Pausing background work…",
        "Profile action failed",
        "Profile settings couldn't be read. Try again.",
        "Profiles",
        "Quit Cadenza",
        "Profiles are unavailable until the storage upgrade completes.",
        "Recordings made before this profile was linked sync only with your explicit consent.",
        "Recordings stay on this Mac. Cadenza switches back to the Local profile and restarts.",
        "Restart needed",
        "Restarting…",
        "Sign In Again",
        "Sign In to Unlock…",
        "Sign In…",
        "Sign Out",
        "Sign Out…",
        "Sign in to sync transcripts and summaries",
        "Sign in to sync transcripts and summaries. Audio upload stays off until you turn it on.",
        "Sign in with this profile's account to unlock and switch to it.",
        "Sign out of this profile.",
        "Sign out of this profile?",
        "Sign-in didn't finish",
        "Sign-out was not saved — nothing changed.",
        "Signed in as %@",
        "Switch",
        "Switch and Restart",
        "Switching restarts Cadenza.",
        "Switching restarts Cadenza. Sign in from a profile to link an account; signing in with an account that already has a profile switches to it.",
        "Sync existing recordings?",
        "Sync recordings made before linking",
        "Sync transcripts and summaries",
        "Sync with audio",
        "That profile is already active.",
        "That profile is locked. Sign in with its account to unlock it.",
        "That profile no longer exists.",
        "That sign-in belongs to a different account than this profile.",
        "The Local profile is missing — sign-out cannot continue.",
        "The Local profile stays account-free. The account gets its own new profile.",
        "The active profile is missing from the registry.",
        "The change couldn't be saved — try again.",
        "The change couldn't be verified. Quit and reopen Cadenza, then check this setting.",
        "The profile changed — sign out again to retry.",
        "The profile list is unavailable.",
        "The new profile starts empty. You can bring your Local recordings along, or keep them where they are.",
        "The profile switch was not saved — nothing changed.",
        "The transfer couldn't start — nothing changed. Try again.",
        "This account already has the profile “%@”.",
        "To keep your recordings safe, Cadenza will make no further changes in this session. Quit and reopen to resume; if this keeps happening, contact support with the details below.",
        "What about your Local recordings?",
        "This profile has no linked account yet — use Sign In from Profiles to link one.",
        "This profile is locked.",
        "This profile is no longer active, so the change was not saved.",
        "Transcripts and summaries only",
        "Wait for the storage location change to finish before switching profiles.",
        "Wait for transcription and summary to finish before switching profiles.",
        "Waiting for the browser sign-in…",
        "Your session couldn't be securely cleared. Quit and reopen Cadenza, then try again.",
        // Multi-account UX: backend identity and add-or-switch entry
        "Add or switch account",
        "Adds a new account profile or switches to that account's existing profile.",
        "Sign In with Another Account…",
        "Sign in with another account. It gets its own profile, or Cadenza switches to its existing one.",
        "Unknown account",
        "You're already signed in with this account.",
        "“%@” is the active profile, so nothing changed.",
        // Per-recording legacy audio relink repair
        "Audio relinked.",
        "Found a matching file:",
        "Locate File…",
        "No file with this name was found in the current storage folder.",
        "Relinking…",
        "Search Again",
        "Searching the storage folder…",
        "Several files share this name. Choose the exact one:",
        "The file couldn't be relinked — try again.",
        "This recording still points at its old location outside the storage folder. Relink it to keep everything in one place.",
        "Use This File",
        // Audio-root bookmark relink repair
        "Access restored.",
        "Cadenza can no longer access this profile's recordings folder. Choose the same folder again to restore access — recordings stay where they are.",
        "Choose the original recordings folder to restore access",
        "Recordings folder access lost",
        "Relink Folder…",
        "The recorded storage folder changed before the repair could save, so nothing was updated.",
        "The selected folder doesn't match the recorded one, so nothing was changed. Choose the folder at the exact path shown.",
    ]

    private func loadCatalogStrings() throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        return try #require(catalog["strings"] as? [String: Any])
    }

    @Test func settingsKeysHaveChineseLocalization() throws {
        let strings = try loadCatalogStrings()
        for key in Self.settingsKeysNeedingChinese {
            let entry = strings[key] as? [String: Any]
            let value = (((entry?["localizations"] as? [String: Any])?["zh-Hans"]
                as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(value?.isEmpty == false, "missing zh-Hans for key: \(key)")
        }
    }

    /// Drives AuthError.localizedMessage itself with an injected zh-Hans
    /// locale — asserting only non-emptiness or embedded arguments would
    /// also pass for a bare-English implementation.
    @Test func authErrorMessagesResolveChineseThroughProductionPath() {
        let zh = Locale(identifier: "zh-Hans")
        #expect(AuthError.unknown.localizedMessage(locale: zh) == "登录失败。")
        #expect(AuthError.sessionExpired.localizedMessage(locale: zh) == "会话已过期，请重新登录。")
        #expect(AuthError.cancelled.localizedMessage(locale: zh) == "已取消登录。")
        let reconnect = AuthError.integrationReauthRequired(provider: "Zoom").localizedMessage(locale: zh)
        #expect(reconnect.contains("Zoom") && reconnect.contains("重新连接"), "got: \(reconnect)")
        let server = AuthError.server(status: 503).localizedMessage(locale: zh)
        #expect(server.contains("503") && server.contains("服务器错误"), "got: \(server)")

        #expect(AuthError.bindingFlowRequired.localizedMessage(locale: zh).contains("配置档案"))
        #expect(AuthError.accountMismatch.localizedMessage(locale: zh).contains("另一个账号"))
        #expect(AuthError.sessionCleanupFailed.localizedMessage(locale: zh).contains("安全清除"))

        let allCases: [AuthError] = [
            .cancelled, .browserOpenFailed, .callbackTimeout, .alreadyInProgress,
            .stateMismatch, .authorizationDenied, .invalidCallback,
            .localPersistenceFailed("x"), .decoding("x"), .sessionExpired,
            .sessionCleanupFailed, .bindingFlowRequired, .accountMismatch,
            .integrationReauthRequired(provider: "Zoom"), .server(status: 503),
            .network(.timedOut), .unknown,
        ]
        for error in allCases {
            #expect(!error.localizedMessage(locale: zh).isEmpty, "empty zh message for \(error)")
            #expect(error.errorDescription?.isEmpty == false, "empty description for \(error)")
        }
    }

    /// The transition overlay resolves its copy through the shared
    /// helper; both phases must produce translated text.
    @Test func transitionOverlayCopyResolvesChineseThroughProductionPath() {
        let zh = Locale(identifier: "zh-Hans")
        #expect(ProfileTransitionOverlayCopy.statusText(for: .preparing, locale: zh)
            == "正在暂停后台工作…")
        #expect(ProfileTransitionOverlayCopy.statusText(for: .relaunching, locale: zh)
            == "正在重新启动…")
    }

    /// Root-write failures surface through RootWriteError's production
    /// localization path.
    @Test func rootWriteErrorsResolveChineseThroughProductionPath() {
        let zh = Locale(identifier: "zh-Hans")
        let retryable = ProfileAudioRootWriter.RootWriteError
            .saveNotCommitted("detail").localizedMessage(locale: zh)
        #expect(retryable.contains("重试"), "got: \(retryable)")
        let indeterminate = ProfileAudioRootWriter.RootWriteError
            .commitIndeterminate("detail").localizedMessage(locale: zh)
        #expect(indeterminate.contains("重新打开"), "got: \(indeterminate)")
        let rootChanged = ProfileAudioRootWriter.RootWriteError
            .rootChanged.localizedMessage(locale: zh)
        #expect(rootChanged.contains("未更新"), "got: \(rootChanged)")
    }

    /// Runtime zh-Hans resolution for the relink surface copy that a
    /// dynamic string constructor would silently bypass; the source gate
    /// in AudioRootRelinkTests pins the literal constructors.
    @Test func legacyRelinkCopyResolvesChineseThroughProductionPath() {
        let zh = Locale(identifier: "zh-Hans")
        #expect(LocalizedBundle.string("Found a matching file:", locale: zh)
            == "找到匹配的文件：")
        #expect(LocalizedBundle.string(
            "Several files share this name. Choose the exact one:", locale: zh
        ) == "多个文件同名。请选择确切的那一个：")
        #expect(LocalizedBundle.string("Searching the storage folder…", locale: zh)
            == "正在搜索存储文件夹…")
        #expect(LocalizedBundle.string("Relinking…", locale: zh) == "正在重新关联…")
        #expect(LocalizedBundle.string(
            "This recording still points at its old location outside the storage folder. Relink it to keep everything in one place.",
            locale: zh
        ) == "此录音仍指向存储文件夹之外的旧位置。重新关联可将所有内容集中在一处。")
    }

    /// The presenter's empty-identity placeholder is built dynamically
    /// through LocalizedBundle, so it needs a runtime production-path
    /// check rather than a catalog presence check alone.
    @Test func accountIdentityPlaceholderResolvesChineseThroughProductionPath() {
        let zh = Locale(identifier: "zh-Hans")
        let empty = Profile.BoundAccount(
            userID: "u", originKey: "k", issuerOrigin: "https://cadenzapp.com:443",
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "", displayName: "", boundAt: Date(timeIntervalSince1970: 0)
        )
        #expect(AccountIdentityPresenter.identity(for: empty, locale: zh) == "未知账号")
    }

    /// Drives StorageSettingsMessage itself with an injected zh-Hans locale;
    /// re-implementing String(localized:) in the test would not cover the
    /// production path.
    @Test func storageErrorMessagesResolveChineseThroughProductionPath() {
        let zh = Locale(identifier: "zh-Hans")
        let detail = "PROBE-42"
        let setFailure = StorageSettingsMessage.failedToSetDirectory(detail, locale: zh)
        #expect(setFailure.contains(detail) && setFailure.contains("设置目录失败"), "got: \(setFailure)")
        let migration = StorageSettingsMessage.migrationError(detail, locale: zh)
        #expect(migration.contains(detail) && migration.contains("迁移出错"), "got: \(migration)")
    }

    @Test func trashRetentionPolicyResolvesChineseThroughProductionPath() {
        let zh = Locale(identifier: "zh-Hans")
        #expect(
            RecordingSettingsMessage.trashRetentionPolicy(locale: zh)
                == "删除的录音会移入废纸篓，并在超过所选天数后从当前资料库中移除，包括 Cadenza 创建的音频文件和派生数据；导入的源文件仍保留在原始位置。自动恢复备份可能会保留副本，直到备份轮换或被明确删除。"
        )
    }

    @Test func calendarColorNamesResolveChineseThroughProductionPath() throws {
        let zh = Locale(identifier: "zh-Hans")
        let expected: [CalendarColorOption: String] = [
            .red: "红色",
            .orange: "橙色",
            .yellow: "黄色",
            .green: "绿色",
            .cyan: "青色",
            .blue: "蓝色",
            .indigo: "靛蓝色",
            .purple: "紫色",
            .pink: "粉色",
        ]
        for option in CalendarColorOption.allCases {
            #expect(option.localizedName(locale: zh) == expected[option])
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainWindow = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Main/MainWindow.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(mainWindow.contains("label: option.localizedName"))
        #expect(settings.contains("CalendarColorSwatchButton("))
        #expect(settings.contains(".accessibilityLabel(Text(option.localizedName))"))
        #expect(!settings.contains(".onTapGesture {\n                                selectedOption = option"))
    }
}

// MARK: - Complete-surface extraction for the Profiles pane

/// Source-to-catalog extraction over the profiles pane: every
/// `String(localized:)` and `Text("...")` literal in the pane must carry a
/// nonempty zh-Hans value; interpolations map to their `%@` catalog keys.
@Suite struct ProfilesSurfaceLocalizationTests {
    @Test func everyProfilesPaneStringHasChinese() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = repoRoot.appendingPathComponent(
            "Cadenza/Views/Settings/ProfilesSettingsSection.swift"
        )
        let source = try String(contentsOf: file, encoding: .utf8)
        let catalogURL = repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])

        var keys: Set<String> = []
        let patterns = [
            #"String\(localized: \"((?:[^\"\\]|\\.)+)\""#,
            #"Text\(\"((?:[^\"\\]|\\.)+)\"\)"#,
        ]
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            regex.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let match, let keyRange = Range(match.range(at: 1), in: source) else {
                    return
                }
                var key = String(source[keyRange])
                // Swift interpolations become %@ in the extracted catalog key.
                while let open = key.range(of: "\\(") {
                    guard let close = key[open.upperBound...].firstIndex(of: ")") else { break }
                    key.replaceSubrange(open.lowerBound...close, with: "%@")
                }
                key = key.replacingOccurrences(of: "\\\"", with: "\"")
                keys.insert(key)
            }
        }
        #expect(keys.count > 30)
        for key in keys.sorted() {
            let entry = strings[key] as? [String: Any]
            let value = (((entry?["localizations"] as? [String: Any])?["zh-Hans"]
                as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(value?.isEmpty == false, "missing zh-Hans for: \(key)")
        }
    }
}
