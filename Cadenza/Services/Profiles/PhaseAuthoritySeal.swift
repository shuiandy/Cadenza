import Foundation

/// Durable phase-authority seal: records that this installation crossed
/// the release boundary past which authority beyond the M1 storage shape
/// may exist (Local establishment, bindings, per-profile roots) — it is
/// written before the first session-stage mutation, so a sealed marker
/// means such authority is possible, not that every mutation succeeded.
/// A single versioned marker, not a progress journal: the
/// unreadable-registry recovery consults it so an M1 journal rebuild can
/// never erase later authority, including the promoted-Local shape the
/// directory residue scan cannot distinguish from plain M1. Contains
/// nothing sensitive.
struct PhaseAuthoritySealDocument: Codable, Sendable, Equatable {
    var version: Int
    var phase: Int
    var sealedAt: Date
}

struct PhaseAuthoritySealStore {
    let paths: ProfilePaths
    let fileOperations: FileOperations

    static let filename = "phase-authority.json"

    var url: URL {
        paths.migrationDirectory.appendingPathComponent(Self.filename)
    }

    enum Classification: Equatable {
        case sealed
        case absent
        /// Unreadable, malformed, or unsupported content: authority
        /// state unknown — every consumer fails closed.
        case unknown(String)
    }

    func classify() -> Classification {
        // Trusted-root and lstat presence first: the live read seam does
        // not distinguish a missing file from other open failures, and a
        // symlinked seal or migration root must never be followed.
        do {
            try requireTrustedMigrationRoot(
                at: paths.migrationDirectory, fileOperations: fileOperations
            )
        } catch {
            return .unknown("migration root untrusted: \(error)")
        }
        do {
            try requireRegularFile(at: url, fileOperations: fileOperations)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            return .unknown("seal presence: \(error)")
        }
        let data: Data
        do {
            data = try fileOperations.read(from: url)
        } catch {
            return .unknown("seal unreadable: \(error)")
        }
        let document: PhaseAuthoritySealDocument
        do {
            document = try ProfileRegistryCoding.makeDecoder().decode(
                PhaseAuthoritySealDocument.self, from: data
            )
        } catch {
            return .unknown("seal malformed: \(error)")
        }
        guard document.version == 1, document.phase == 2 else {
            return .unknown("seal unsupported: version \(document.version) phase \(document.phase)")
        }
        return .sealed
    }

    enum EnsureOutcome: Equatable {
        case committed
        /// The write provably did not land; the seal is still absent and
        /// no session-stage mutation may run.
        case notCommitted(String)
        case unknown(String)
    }

    /// Idempotent durable write, classified like every commit-point
    /// artifact: a throw re-reads and proves sealed, proves absent, or
    /// stays unknown.
    func ensureSealed(now: Date) -> EnsureOutcome {
        switch classify() {
        case .sealed:
            return .committed
        case .unknown(let detail):
            return .unknown(detail)
        case .absent:
            break
        }
        let document = PhaseAuthoritySealDocument(version: 1, phase: 2, sealedAt: now)
        let data: Data
        do {
            data = try ProfileRegistryCoding.makeEncoder().encode(document)
        } catch {
            return .unknown("seal unencodable: \(error)")
        }
        do {
            try fileOperations.createDirectory(at: paths.migrationDirectory)
            try fileOperations.atomicReplace(data, at: url)
            return .committed
        } catch {
            switch classify() {
            case .sealed:
                return .committed
            case .absent:
                return .notCommitted(String(describing: error))
            case .unknown(let detail):
                return .unknown(detail)
            }
        }
    }
}
