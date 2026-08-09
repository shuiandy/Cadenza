import CryptoKit
import Foundation

struct WebSyncAudioFingerprint: Codable, Sendable, Equatable {
    let size: Int64
    let modifiedAt: Int64

    var value: String { "\(size):\(modifiedAt)" }
}

struct WebSyncAudioChunk: Sendable {
    let data: Data
    let sha256: String
}

enum WebSyncFileError: Error, LocalizedError {
    case missing
    case invalidRange
    case changed

    var errorDescription: String? {
        switch self {
        case .missing: return "The local audio file is missing."
        case .invalidRange: return "The requested audio range is invalid."
        case .changed: return "The local audio file changed during upload."
        }
    }
}

actor WebSyncFileReader {
    func fingerprint(url: URL) throws -> WebSyncAudioFingerprint {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: url.path) else { throw WebSyncFileError.missing }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else { throw WebSyncFileError.missing }
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        return WebSyncAudioFingerprint(
            size: number.int64Value,
            modifiedAt: Int64((modified.timeIntervalSince1970 * 1_000_000_000).rounded())
        )
    }

    func readChunk(url: URL, offset: UInt64, length: Int) throws -> WebSyncAudioChunk {
        try Task.checkCancellation()
        guard length > 0 else { throw WebSyncFileError.invalidRange }
        guard FileManager.default.fileExists(atPath: url.path) else { throw WebSyncFileError.missing }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length else { throw WebSyncFileError.changed }
        try Task.checkCancellation()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return WebSyncAudioChunk(data: data, sha256: hash)
    }

    func validateFingerprint(_ expected: WebSyncAudioFingerprint, url: URL) throws {
        guard try fingerprint(url: url) == expected else { throw WebSyncFileError.changed }
    }
}
