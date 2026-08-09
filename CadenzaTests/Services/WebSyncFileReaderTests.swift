import CryptoKit
import Foundation
import Testing
@testable import Cadenza

@Suite("Web sync file reader")
struct WebSyncFileReaderTests {
    @Test
    func fingerprintsAndReadsBoundedChunks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data((0..<(300 * 1_024)).map { UInt8($0 % 251) })
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = WebSyncFileReader()
        let fingerprint = try await reader.fingerprint(url: url)
        let chunk = try await reader.readChunk(url: url, offset: 0, length: 256 * 1_024)

        #expect(fingerprint.size == Int64(data.count))
        #expect(chunk.data == data.prefix(256 * 1_024))
        let expected = SHA256.hash(data: chunk.data).map { String(format: "%02x", $0) }.joined()
        #expect(chunk.sha256 == expected)
    }

    @Test
    func missingFileFails() async {
        let reader = WebSyncFileReader()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: WebSyncFileError.self) {
            try await reader.fingerprint(url: url)
        }
    }

    @Test
    func detectsFileReplacementAfterFingerprinting() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: 32).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = WebSyncFileReader()
        let fingerprint = try await reader.fingerprint(url: url)
        try Data(repeating: 2, count: 32).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)],
            ofItemAtPath: url.path
        )

        await #expect(throws: WebSyncFileError.changed) {
            try await reader.validateFingerprint(fingerprint, url: url)
        }
    }
}
