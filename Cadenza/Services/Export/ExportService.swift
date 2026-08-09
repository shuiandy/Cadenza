import Foundation

enum ExportError: LocalizedError {
    case recordingNotFound
    case notionDatabaseNotSelected
    case craftNotInstalled
    case craftLinkCreationFailed
    case craftURLHandlerUnavailable
    case craftOpenFailed
    /// Safe fallback for an unexpected implementation detail. The associated
    /// value is diagnostic only and must never cross into visible copy.
    case unexpected(String)

    var errorDescription: String? { localizedMessage() }

    func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .recordingNotFound:
            return LocalizedBundle.string(
                "Recording not found (possibly deleted)",
                locale: locale
            )
        case .notionDatabaseNotSelected:
            return LocalizedBundle.string("Select a Notion database first", locale: locale)
        case .craftNotInstalled:
            return LocalizedBundle.string(
                "Craft is not installed. Install Craft, then try again.",
                locale: locale
            )
        case .craftLinkCreationFailed, .craftURLHandlerUnavailable, .craftOpenFailed:
            return LocalizedBundle.string(
                "Craft couldn't open the document. Make sure Craft is installed, then try again.",
                locale: locale
            )
        case .unexpected:
            return LocalizedBundle.string(
                "Export failed. Check the destination settings and try again.",
                locale: locale
            )
        }
    }
}

/// Fail-closed presentation mapping for export surfaces. Only explicitly
/// reviewed, localized error families retain their specific message; Cocoa,
/// schema, filesystem, and other implementation errors collapse to the
/// stable generic export failure.
enum ExportUserMessage {
    static func message(for error: Error, locale: Locale? = nil) -> String {
        if let exportError = error as? ExportError {
            return exportError.localizedMessage(locale: locale)
        }
        if let apiError = error as? CadenzaAPIError {
            return apiError.localizedMessage(locale: locale)
        }
        if let authError = error as? AuthError {
            return authError.localizedMessage(locale: locale)
        }
        return ExportError.unexpected(String(describing: error))
            .localizedMessage(locale: locale)
    }
}

enum AutoExportDestination: String, CaseIterable, Hashable, Sendable {
    case notion
    case craft
}

/// A privacy-safe summary of one automatic export follow-up. Provider and OS
/// errors stay in diagnostics; callers only receive destination-level status.
struct AutoExportOutcome: Equatable, Sendable {
    let enabledDestinations: Set<AutoExportDestination>
    let succeededDestinations: Set<AutoExportDestination>
    let failedDestinations: Set<AutoExportDestination>

    var hasFailures: Bool { !failedDestinations.isEmpty }
}

struct AutoExportFeedback: Equatable, Sendable {
    let failedDestinations: Set<AutoExportDestination>
    let message: String
}

@MainActor
struct AutoExportDependencies {
    let enabledDestinations: @MainActor () -> Set<AutoExportDestination>
    let isAvailable: @MainActor (AutoExportDestination) -> Bool
    let export: @MainActor (AutoExportDestination, RecordingDetailDTO) async throws -> Void
}

@Observable @MainActor
final class ExportService {
    let notionService: NotionExportService
    let craftService: CraftExportService
    let bulkExporter = BulkExportCoordinator()
    let batchFileExporter = BatchFileExporter()
    let archiveExporter = PortableArchiveExporter()

    @ObservationIgnored
    private let autoExportDependencies: AutoExportDependencies

    /// Exactly one callback is published for each auto-export run that has at
    /// least one failed enabled destination. The message is stable localized
    /// copy and never contains the provider's raw error.
    @ObservationIgnored
    var onAutoExportFeedback: ((AutoExportFeedback) -> Void)?

    init(
        cadenzaAuth: CadenzaAuthService,
        autoExportDependencies: AutoExportDependencies? = nil
    ) {
        let notionService = NotionExportService(cadenzaAuth: cadenzaAuth)
        let craftService = CraftExportService()
        self.notionService = notionService
        self.craftService = craftService
        self.autoExportDependencies = autoExportDependencies ?? AutoExportDependencies(
            enabledDestinations: {
                var destinations: Set<AutoExportDestination> = []
                if UserDefaults.standard.bool(
                    forKey: ActiveProfileDefaults.key("autoExportToNotion")
                ) {
                    destinations.insert(.notion)
                }
                if UserDefaults.standard.bool(
                    forKey: ActiveProfileDefaults.key("autoExportToCraft")
                ) {
                    destinations.insert(.craft)
                }
                return destinations
            },
            isAvailable: { destination in
                switch destination {
                case .notion:
                    return notionService.isConnected
                case .craft:
                    return craftService.isAvailable
                }
            },
            export: { destination, recording in
                switch destination {
                case .notion:
                    try await notionService.exportRecording(recording)
                case .craft:
                    try await craftService.exportRecording(recording)
                }
            }
        )
    }

    var lastExportError: String?
    var isExporting: Bool {
        notionService.isExporting || craftService.isExporting
    }

    func exportToNotion(_ recording: RecordingDetailDTO) async throws {
        lastExportError = nil
        do {
            try await notionService.exportRecording(recording)
        } catch {
            lastExportError = error.localizedDescription
            throw error
        }
    }

    func exportToCraft(_ recording: RecordingDetailDTO) async throws {
        lastExportError = nil
        do {
            try await craftService.exportRecording(recording)
        } catch {
            lastExportError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func autoExportIfNeeded(_ recording: RecordingDetailDTO) async -> AutoExportOutcome {
        let enabledDestinations = autoExportDependencies.enabledDestinations()
        var succeededDestinations: Set<AutoExportDestination> = []
        var failedDestinations: Set<AutoExportDestination> = []
        lastExportError = nil

        for destination in AutoExportDestination.allCases where enabledDestinations.contains(destination) {
            guard autoExportDependencies.isAvailable(destination) else {
                failedDestinations.insert(destination)
                NSLog(
                    "[ExportService] Auto-export destination unavailable: %@",
                    destination.rawValue
                )
                continue
            }

            do {
                try await autoExportDependencies.export(destination, recording)
                succeededDestinations.insert(destination)
            } catch {
                failedDestinations.insert(destination)
                NSLog(
                    "[ExportService] Auto-export to %@ failed: %@",
                    destination.rawValue,
                    String(describing: error)
                )
            }
        }

        let outcome = AutoExportOutcome(
            enabledDestinations: enabledDestinations,
            succeededDestinations: succeededDestinations,
            failedDestinations: failedDestinations
        )
        if outcome.hasFailures {
            let message = ExportError.unexpected("auto-export failure")
                .localizedMessage()
            lastExportError = message
            onAutoExportFeedback?(
                AutoExportFeedback(
                    failedDestinations: failedDestinations,
                    message: message
                )
            )
        }
        return outcome
    }
}
