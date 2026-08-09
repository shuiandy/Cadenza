import AppKit
import AVFoundation
import Foundation

/// Runs system-level diagnostics: audio, database, meeting detection, storage, exports.
@Observable @MainActor
final class SystemDiagnosticRunner {
    static let shared = SystemDiagnosticRunner()

    private(set) var isRunning = false
    private(set) var currentStatus = ""
    private(set) var report = ""

    private init() {}

    func run(store: RecordingsStore, meetingDetector: MeetingDetector?) async {
        guard !isRunning else { return }
        isRunning = true
        report = ""
        defer { isRunning = false; currentStatus = "" }

        let startTime = Date()
        log("=== Cadenza System Diagnostics ===")
        log("Date: \(ISO8601DateFormatter().string(from: startTime))")
        log("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        await runAudioDiagnostic()
        await runDatabaseDiagnostic(store: store)
        runMeetingDetectionDiagnostic(meetingDetector: meetingDetector)
        runStorageDiagnostic()
        await runExportDiagnostic()

        let elapsed = Date().timeIntervalSince(startTime)
        log("")
        log("=== Done in \(String(format: "%.1f", elapsed))s ===")

        do {
            let reportURL = try DiagnosticArtifactStore.shared.writeReport(
                prefix: "system-diagnostic",
                contents: report,
                maximumBytes: 5 * 1_024 * 1_024
            )
            NSLog("[SystemDiag] private report saved: %@", reportURL.lastPathComponent)
        } catch {
            NSLog("[SystemDiag] report save failed: %@", error.localizedDescription)
        }
    }

    // MARK: - 1. Audio Capture

    private func runAudioDiagnostic() async {
        log("")
        log("== AUDIO CAPTURE ==")
        log("")

        // Permissions
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log("Microphone permission: \(permissionLabel(micStatus))")

        let screenOK = CGPreflightScreenCaptureAccess()
        log("Screen Recording permission: \(screenOK ? "granted" : "denied")")

        // Input devices
        let microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        ).devices
        log("Available microphones: \(microphones.count)")
        for mic in microphones {
            log("  - \(mic.localizedName) [\(mic.uniqueID)]")
        }

        let selectedID = UserDefaults.standard.string(forKey: "selectedMicrophoneID") ?? ""
        if selectedID.isEmpty {
            log("Selected mic: System Default")
        } else if let match = microphones.first(where: { $0.uniqueID == selectedID }) {
            log("Selected mic: \(match.localizedName) [OK]")
        } else {
            log("Selected mic: '\(selectedID)' [NOT FOUND — will fall back to default]")
        }

        log("System audio backend: Core Audio process tap")

        // Capture microphone setting
        let captureMic = UserDefaults.standard.bool(forKey: "captureMicrophone")
        log("Capture microphone enabled: \(captureMic)")
    }

    // MARK: - 2. Database Health

    private func runDatabaseDiagnostic(store: RecordingsStore) async {
        log("")
        log("== DATABASE HEALTH ==")
        log("")
        status("Checking database...")

        // Counts
        let allRecordings = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        let trashedRecordings = await store.fetchTrashedRecordings()
        log("Active recordings: \(allRecordings.count)")
        log("Trashed recordings: \(trashedRecordings.count)")

        // Check for recordings without audio files
        var missingAudio = 0
        var hasAudio = 0
        for rec in allRecordings {
            if let detail = await store.fetchRecordingDetail(recordingID: rec.id) {
                if let url = detail.audioFile.flatMap({
                    try? ProfileStorageResolver.current.resolveAudio($0)
                }), FileManager.default.fileExists(atPath: url.path) {
                    hasAudio += 1
                } else if detail.audioFile != nil {
                    missingAudio += 1
                }
            }
        }
        log("With audio file: \(hasAudio)")
        let legacyReferences = await store.countLegacyAudioReferences()
        if legacyReferences > 0 {
            log("Legacy absolute references: \(legacyReferences)")
        }
        if missingAudio > 0 {
            log("Missing audio file: \(missingAudio) [WARNING]")
        }

        // Check for recordings without transcript/summary
        let noTranscript = allRecordings.filter { !$0.hasTranscript }.count
        let noSummary = allRecordings.filter { !$0.hasSummary }.count
        log("Without transcript: \(noTranscript)")
        log("Without summary: \(noSummary)")

        // Orphaned audio files
        status("Scanning for orphaned files...")
        do {
            let trackedPaths = try await store.allTrackedAudioPaths()
            let storageDir = StorageLocationManager.recordingsDirectory
            let (orphanCount, orphanSize, staleSegments) = Self.scanOrphans(
                storageDir: storageDir,
                trackedPaths: trackedPaths
            )
            if orphanCount > 0 {
                log("Orphaned audio files: \(orphanCount) (\(formatBytes(orphanSize))) [WARNING]")
            } else {
                log("Orphaned audio files: 0")
            }
            if staleSegments > 0 {
                log("Stale segment directories: \(staleSegments) [may be from interrupted recordings]")
            }
        } catch {
            log("Orphaned audio scan unavailable: tracked database paths could not be read [WARNING]")
        }
    }

    // MARK: - 3. Meeting Detection

    private func runMeetingDetectionDiagnostic(meetingDetector: MeetingDetector?) {
        log("")
        log("== MEETING DETECTION ==")
        log("")

        guard let detector = meetingDetector else {
            log("MeetingDetector not available")
            return
        }

        // State
        let state = detector.sessionState
        log("Session state: \(sessionStateLabel(state))")
        if let app = state.currentApp {
            log("Active app: \(app.rawValue)")
        }

        // Running meeting apps
        let runningApps = detector.runningMeetingApps
        log("Running meeting apps: \(runningApps.count)")
        for app in runningApps {
            log("  - \(app.name) [\(app.id)] pid=\(app.pid)")
        }

        // Calendar
        if let event = detector.currentCalendarMeeting {
            log("Calendar match: \(event.title) (\(event.startDate)–\(event.endDate))")
        } else {
            log("Calendar match: none")
        }

        // Mic activity
        let systemMicActive = detector.checkMicrophoneActivity()
        log("System mic active: \(systemMicActive)")

        // Detection settings
        let autoRecord = UserDefaults.standard.bool(forKey: "autoRecordMeetings")
        let cooldown = UserDefaults.standard.double(forKey: "detectionCooldownUntil")
        log("Auto-record enabled: \(autoRecord)")
        if cooldown > Date().timeIntervalSinceReferenceDate {
            let remaining = cooldown - Date().timeIntervalSinceReferenceDate
            log("Detection cooldown: \(String(format: "%.0f", remaining))s remaining")
        }
    }

    // MARK: - 4. Storage Health

    private func runStorageDiagnostic() {
        log("")
        log("== STORAGE HEALTH ==")
        log("")
        status("Analyzing storage...")

        let storageDir = StorageLocationManager.recordingsDirectory
        log("Storage path: \(storageDir.path)")

        // Cloud service
        if let cloud = StorageLocationManager.detectedCloudService {
            log("Cloud sync: \(cloud)")
        } else {
            log("Cloud sync: none detected")
        }

        // Total size breakdown
        let stats = Self.scanStorage(storageDir: storageDir)

        log("Total storage: \(formatBytes(stats.total))")
        log("Audio files: \(stats.audioCount) (\(formatBytes(stats.audioSize)))")
        log("  Compressed (m4a/aac/mp3): \(stats.compressedCount)")
        log("  Uncompressed (wav/aiff/caf): \(stats.uncompressedCount)")
        log("Other files: \(formatBytes(stats.otherSize))")

        // Storage limit
        let limitMB = UserDefaults.standard.integer(forKey: "storageLimitMB")
        if limitMB > 0 {
            let limitBytes = Int64(limitMB) * 1024 * 1024
            let usage = Double(stats.total) / Double(limitBytes) * 100
            log("Storage limit: \(limitMB) MB (\(String(format: "%.0f", usage))% used)")
        } else {
            log("Storage limit: unlimited")
        }

        // Auto-discard threshold
        let threshold = UserDefaults.standard.double(forKey: "autoDiscardThreshold")
        log("Auto-discard threshold: \(threshold > 0 ? "\(Int(threshold))s" : "30s (default)")")
    }

    // MARK: - 5. Export Connectivity

    private func runExportDiagnostic() async {
        log("")
        log("== EXPORT CONNECTIVITY ==")
        log("")
        status("Checking export services...")

        let keychain = KeychainManager.shared

        // Notion — uses OAuthTokenManager, token stored as JSON in Keychain
        let notionTokenJSON = keychain.get("oauth.tokens.notion")
        if let json = notionTokenJSON, !json.isEmpty {
            log("Notion: OAuth token present")
            // Extract access_token from stored JSON to ping API
            if let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = dict["accessToken"] as? String ?? dict["access_token"] as? String {
                status("Testing Notion API...")
                var request = URLRequest(url: URL(string: "https://api.notion.com/v1/users/me")!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
                request.timeoutInterval = 10
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200 {
                        log("Notion API: connected [OK]")
                    } else if code == 401 {
                        log("Notion API: token expired/invalid (401) [ERROR]")
                    } else {
                        log("Notion API: HTTP \(code)")
                    }
                } catch {
                    log("Notion API: \(error.localizedDescription) [ERROR]")
                }
            } else {
                log("Notion: token data unreadable [WARNING]")
            }
        } else {
            log("Notion: not configured")
        }

        // Craft — uses local x-callback-url, no API token
        log("Craft: uses local x-callback-url (no token to validate)")
        let craftInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.lukilabs.lukiapp") != nil
        log("Craft app installed: \(craftInstalled)")

        // Google Calendar
        let gcalTokenJSON = keychain.get("oauth.tokens.google")
        if let json = gcalTokenJSON, !json.isEmpty {
            log("Google Calendar: OAuth token present")
            if let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = dict["accessToken"] as? String ?? dict["access_token"] as? String {
                status("Testing Google Calendar API...")
                var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=1")!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 10
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200 {
                        log("Google Calendar API: connected [OK]")
                    } else if code == 401 {
                        log("Google Calendar API: token expired (401) — re-auth needed [ERROR]")
                    } else {
                        log("Google Calendar API: HTTP \(code)")
                    }
                } catch {
                    log("Google Calendar API: \(error.localizedDescription) [ERROR]")
                }
            } else {
                log("Google Calendar: token data unreadable [WARNING]")
            }
        } else {
            log("Google Calendar: not configured")
        }

        // AI provider API keys
        log("")
        log("AI Provider Keys:")
        for provider in [AIProvider.openai, .gemini, .claude, .minimax] {
            let hasKey = keychain.hasAPIKey(for: provider)
            log("  \(provider.displayName): \(hasKey ? "configured" : "not set")")
        }
    }

    // MARK: - File System Scanning (nonisolated to avoid async enumerator restriction)

    private nonisolated static func scanOrphans(storageDir: URL, trackedPaths: Set<String>) -> (count: Int, size: Int64, staleSegments: Int) {
        var orphanCount = 0
        var orphanSize: Int64 = 0
        let audioExtensions: Set<String> = ["m4a", "wav", "aac", "mp3", "caf", "aiff"]
        if let enumerator = FileManager.default.enumerator(at: storageDir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            for case let fileURL as URL in enumerator {
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { continue }
                guard audioExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                if !trackedPaths.contains(fileURL.path) {
                    orphanCount += 1
                    orphanSize += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }
        }
        var staleSegments = 0
        let segmentsBase = storageDir.appendingPathComponent("segments")
        if FileManager.default.fileExists(atPath: segmentsBase.path) {
            staleSegments = (try? FileManager.default.contentsOfDirectory(at: segmentsBase, includingPropertiesForKeys: nil))?.count ?? 0
        }
        return (orphanCount, orphanSize, staleSegments)
    }

    private nonisolated static func scanStorage(storageDir: URL) -> (total: Int64, audioSize: Int64, audioCount: Int, compressedCount: Int, uncompressedCount: Int, otherSize: Int64) {
        var totalSize: Int64 = 0
        var audioSize: Int64 = 0
        var audioCount = 0
        var otherSize: Int64 = 0
        var compressedCount = 0
        var uncompressedCount = 0
        let compressedExts: Set<String> = ["m4a", "aac", "mp3"]
        let uncompressedExts: Set<String> = ["wav", "aiff", "caf"]
        if let enumerator = FileManager.default.enumerator(at: storageDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                totalSize += size
                let ext = fileURL.pathExtension.lowercased()
                if compressedExts.contains(ext) {
                    audioSize += size; audioCount += 1; compressedCount += 1
                } else if uncompressedExts.contains(ext) {
                    audioSize += size; audioCount += 1; uncompressedCount += 1
                } else {
                    otherSize += size
                }
            }
        }
        return (totalSize, audioSize, audioCount, compressedCount, uncompressedCount, otherSize)
    }

    // MARK: - Helpers

    private func log(_ text: String) {
        report += text + "\n"
    }

    private func status(_ text: String) {
        currentStatus = text
    }

    private func permissionLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not requested"
        @unknown default: "unknown"
        }
    }

    private func sessionStateLabel(_ state: MeetingSessionState) -> String {
        switch state {
        case .idle: "idle"
        case .detected(let since, let app): "detected (\(app.rawValue), \(String(format: "%.0f", -since.timeIntervalSinceNow))s ago)"
        case .active(let app): "active (\(app.rawValue))"
        case .ending(let since, let app): "ending (\(app.rawValue), \(String(format: "%.0f", -since.timeIntervalSinceNow))s in grace)"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return "\(bytes / 1024) KB" }
        let mb = Double(bytes) / 1_048_576
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}
