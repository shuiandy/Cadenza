import Foundation

@MainActor @Observable
final class ChatHistoryManager {
    /// Where sessions persist. Construction starts `disabled` (in-memory
    /// only, no filesystem touch): startup wiring decides the directory
    /// AFTER the profile bootstrap, so neither the TestHost nor a profile
    /// boot with an unavailable directory ever writes the legacy location.
    enum Storage: Equatable {
        case disabled
        case directory(URL)
    }

    var sessions: [ChatSession] = []

    private var storage: Storage = .disabled
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The pre-profile session directory, used only for the pre-commit
    /// legacy fallback boot.
    static var legacyDirectory: URL {
        let appSupport = DebugDataRoot.applicationSupportDirectory()
        return appSupport.appendingPathComponent("Cadenza/ChatHistory", isDirectory: true)
    }

    /// Points persistence at a directory. Called during startup wiring,
    /// before any session is loaded or saved.
    func configure(directory url: URL) {
        storage = .directory(url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

#if DEBUG
    var storageForTesting: Storage { storage }
#endif

    // MARK: - Public

    func save(_ session: ChatSession) {
        if case .directory = storage {
            guard let url = fileURL(for: session.id) else { return }
            do {
                let data = try encoder.encode(session)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[ChatHistoryManager] Failed to save session \(session.id): \(error)")
                return
            }
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sortSessions()
    }

    func load(id: UUID) -> ChatSession? {
        guard let url = fileURL(for: id) else {
            return sessions.first { $0.id == id }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(ChatSession.self, from: data)
    }

    func loadAll() {
        guard case .directory(let directoryURL) = storage else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        var loaded: [ChatSession] = []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let session = try? decoder.decode(ChatSession.self, from: data) {
                loaded.append(session)
            }
        }

        sessions = loaded
        sortSessions()
    }

    func delete(id: UUID) {
        if let url = fileURL(for: id) {
            try? FileManager.default.removeItem(at: url)
        }
        sessions.removeAll { $0.id == id }
    }

    func deleteAll() {
        for session in sessions {
            if let url = fileURL(for: session.id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        sessions.removeAll()
    }

    // MARK: - Private

    private func fileURL(for id: UUID) -> URL? {
        guard case .directory(let directoryURL) = storage else { return nil }
        return directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func sortSessions() {
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }
}
