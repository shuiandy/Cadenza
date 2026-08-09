import Foundation
import WhisperKit

typealias WhisperModelDownloadOperation = @Sendable (
    _ modelName: String,
    _ progressCallback: @escaping @Sendable (Progress) -> Void
) async throws -> URL

/// Manages local Whisper model lifecycle: enumerate, download, delete, resolve paths.
@Observable @MainActor
final class WhisperModelManager {
    static let shared = WhisperModelManager(
        externalModelAccessAllowed: {
            !DebugDataRoot.blocksLiveAccess && !AppState.isRunningTests
        }
    )

    /// Available model variants ordered by size.
    static let allModels: [WhisperModel] = [
        WhisperModel(name: "tiny", displayName: String(localized: "Tiny"), sizeDescription: "~40 MB", description: String(localized: "Fastest. Best for English only."), isDefault: false),
        WhisperModel(name: "base", displayName: String(localized: "Base"), sizeDescription: "~80 MB", description: String(localized: "Good balance for English. Limited other languages."), isDefault: true),
        WhisperModel(name: "small", displayName: String(localized: "Small"), sizeDescription: "~250 MB", description: String(localized: "Good accuracy across many languages."), isDefault: false),
        WhisperModel(name: "medium", displayName: String(localized: "Medium"), sizeDescription: "~800 MB", description: String(localized: "Highest accuracy. May be slow on older Macs."), isDefault: false),
    ]

    /// Current download progress per model name (0.0 to 1.0).
    var downloadProgress: [String: Double] = [:]

    /// The model catalog is process-wide, so only one download may mutate it at
    /// a time. Keeping the task until cancellation is acknowledged prevents a
    /// stale model A task from clearing model B's state.
    private var activeDownloadTask: Task<Void, Never>?
    private var activeDownloadModel: String?
    private var activeDownloadID: UUID?

    private static let modelRepo = "argmaxinc/whisperkit-coreml"
    private static let selectedModelKey = "whisperLocal.selectedModel"
    /// UserDefaults key prefix for storing downloaded model paths.
    private static let pathKeyPrefix = "whisperLocal.modelPath."
    private let defaults: UserDefaults
    private let externalModelAccessAllowed: @Sendable () -> Bool
    private let downloadOperation: WhisperModelDownloadOperation

    init(
        defaults: UserDefaults = .standard,
        externalModelAccessAllowed: @escaping @Sendable () -> Bool,
        downloadOperation: @escaping WhisperModelDownloadOperation = { name, progressCallback in
            try await WhisperKit.download(
                variant: "openai_whisper-\(name)",
                from: WhisperModelManager.modelRepo,
                progressCallback: progressCallback
            )
        }
    ) {
        self.defaults = defaults
        self.externalModelAccessAllowed = externalModelAccessAllowed
        self.downloadOperation = downloadOperation
        // Restore selection from UserDefaults
        let saved = defaults.string(forKey: Self.selectedModelKey) ?? "base"
        _selectedModel = saved
    }

    // MARK: - Selected Model

    /// Stored property so @Observable can properly track changes and trigger SwiftUI updates.
    var selectedModel: String = "base" {
        didSet {
            defaults.set(selectedModel, forKey: Self.selectedModelKey)
        }
    }

    // MARK: - Paths

    nonisolated static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Cadenza/Models", isDirectory: true)
    }

    /// Returns the on-disk path for a downloaded model, or nil if not available.
    /// Required CoreML model files for a complete Whisper model.
    private static let requiredModelFiles = [
        "AudioEncoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    func modelPath(for name: String) -> URL? {
        // Check persisted download path
        if let savedPath = defaults.string(forKey: Self.pathKeyPrefix + name) {
            let url = URL(fileURLWithPath: savedPath)
            if isModelComplete(at: url) {
                return url
            }
            // Incomplete or missing — clean up stale entry
            defaults.removeObject(forKey: Self.pathKeyPrefix + name)
            NSLog("[WhisperModelManager] model '%@' incomplete or missing at %@, cleared path", name, savedPath)
        }
        return nil
    }

    /// Checks that the directory exists and contains all required CoreML files.
    private func isModelComplete(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        return Self.requiredModelFiles.allSatisfy { file in
            fm.fileExists(atPath: url.appendingPathComponent(file).path)
        }
    }

    private func saveModelPath(_ url: URL, for name: String) {
        defaults.set(url.path, forKey: Self.pathKeyPrefix + name)
    }

    // MARK: - Status

    func isAvailable(_ name: String) -> Bool {
        modelPath(for: name) != nil
    }

    func isDownloading(_ name: String) -> Bool {
        activeDownloadModel == name
    }

    var isDownloadInProgress: Bool {
        activeDownloadTask != nil
    }

    // MARK: - Download

    /// Error message from the last failed model operation, shown to user.
    var modelError: String?

    func download(model name: String, externalAccessEnabled: Bool) {
        // This is the deepest boundary before WhisperKit. The explicit UI
        // policy protects fixtures even when this manager is injected in
        // tests, while the process policy independently closes accidental
        // calls from an isolated/debug or test-host process.
        guard externalAccessEnabled,
              externalModelAccessAllowed(),
              activeDownloadTask == nil else { return }

        let downloadID = UUID()
        activeDownloadID = downloadID
        activeDownloadModel = name
        downloadProgress[name] = 0
        modelError = nil

        activeDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeDownloadID == downloadID {
                    self.activeDownloadTask = nil
                    self.activeDownloadModel = nil
                    self.activeDownloadID = nil
                }
            }

            let progressCallback: @Sendable (Progress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.activeDownloadID == downloadID else { return }
                    self.downloadProgress[name] = progress.fractionCompleted
                }
            }

            do {
                try Task.checkCancellation()
                let downloadedURL = try await self.downloadOperation(name, progressCallback)
                try Task.checkCancellation()

                self.saveModelPath(downloadedURL, for: name)
                self.downloadProgress[name] = 1.0
                NSLog("[WhisperModelManager] downloaded model '%@' to %@", name, downloadedURL.path)
            } catch is CancellationError {
                self.downloadProgress.removeValue(forKey: name)
                NSLog("[WhisperModelManager] download cancelled: %@", name)
            } catch {
                self.downloadProgress.removeValue(forKey: name)
                self.modelError = Self.downloadFailureMessage()
                NSLog("[WhisperModelManager] download failed for '%@': %@", name, error.localizedDescription)
            }
        }
    }

    nonisolated static func downloadFailureMessage(locale: Locale? = nil) -> String {
        LocalizedBundle.string(
            "Model download failed. Check your network connection and try again.",
            locale: locale
        )
    }

    func cancelDownload() {
        activeDownloadTask?.cancel()
    }

    // MARK: - Delete

    func delete(model name: String) throws {
        guard let path = modelPath(for: name) else { return }
        try FileManager.default.removeItem(at: path)
        defaults.removeObject(forKey: Self.pathKeyPrefix + name)
        NSLog("[WhisperModelManager] deleted model: %@", name)

        if selectedModel == name {
            // Fallback to first available model, or "base" (will auto-download on use)
            let fallback = Self.allModels.first { isAvailable($0.name) }?.name ?? "base"
            selectedModel = fallback
        }
    }
}

// MARK: - WhisperModel

struct WhisperModel: Identifiable, Sendable {
    let name: String
    let displayName: String
    let sizeDescription: String
    let description: String
    /// Whether this is the default model (auto-downloaded on first use).
    let isDefault: Bool

    var id: String { name }
}
