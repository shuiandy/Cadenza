import Testing
import Darwin
import Foundation
import AVFoundation
import CoreVideo
import CryptoKit
@testable import Cadenza

@Suite("AudioSegmentMerger trim", .serialized)
struct AudioSegmentMergerTests {

    @Test func onlyCompletedWriterStatusCanSucceed() {
        #expect(AudioSegmentMerger.isCompletedWriterStatus(.completed))
        #expect(!AudioSegmentMerger.isCompletedWriterStatus(.cancelled))
        #expect(!AudioSegmentMerger.isCompletedWriterStatus(.failed))
        #expect(!AudioSegmentMerger.isCompletedWriterStatus(.unknown))
        #expect(!AudioSegmentMerger.isCompletedWriterStatus(.writing))
    }

    @Test func manuallyConstructedResultCannotClaimCompleteValidation() {
        let result = AudioSegmentMerger.MergeResult(
            mergedDuration: 1,
            trimmedCount: 0,
            skippedCount: 0
        )

        #expect(!result.completedFullValidation)
    }

    @Test func completeValidationProofIsBoundToCreatedOutputContent() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = try await toneSegment(in: dir, index: 0)
        let out = dir.appendingPathComponent("out.m4a")
        let result = try await AudioSegmentMerger.merge(
            segments: [segment],
            outputURL: out
        )
        var originalStatus = stat()
        #expect(Darwin.lstat(out.path, &originalStatus) == 0)
        let originalBytes = try Data(contentsOf: out)
        let originalDigest = SHA256.hash(data: originalBytes)
        #expect(result.validatedOutputMatches(
            originalStatus,
            digest: originalDigest
        ))

        // Mutate the existing inode without changing its size. Device, inode,
        // and length alone cannot prove this is still the decoded output.
        let replacementBytes = Data(repeating: 0xA5, count: originalBytes.count)
        let outputHandle = try FileHandle(forWritingTo: out)
        try outputHandle.seek(toOffset: 0)
        try outputHandle.write(contentsOf: replacementBytes)
        try outputHandle.truncate(atOffset: UInt64(replacementBytes.count))
        try outputHandle.synchronize()
        try outputHandle.close()

        var replacementStatus = stat()
        #expect(Darwin.lstat(out.path, &replacementStatus) == 0)
        #expect(SegmentObjectIdentity(originalStatus).matches(
            replacementStatus,
            includingSize: true
        ))
        #expect(!result.validatedOutputMatches(
            replacementStatus,
            digest: SHA256.hash(data: replacementBytes)
        ))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("merger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 2s mono tone segment.
    private func toneSegment(in dir: URL, index: Int) async throws -> URL {
        let url = dir.appendingPathComponent("segment-\(index).m4a")
        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(count: 16000 * 2, amplitude: 0.1)], to: url)
        return url
    }

    /// 2s mono silent segment.
    private func silentSegment(in dir: URL, index: Int) async throws -> URL {
        let url = dir.appendingPathComponent("segment-\(index).m4a")
        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.silence(count: 16000 * 2)], to: url)
        return url
    }

    private func zeroDurationAudioSegment(in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("zero-duration.m4a")
        try await AudioTestFixtures.writeM4A(tracks: [[]], to: url)
        return url
    }

    private func videoOnlySegment(in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("video-only.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? AudioTestFixtures.FixtureError.osStatus("video start", -1)
        }
        writer.startSession(atSourceTime: .zero)
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw AudioTestFixtures.FixtureError.osStatus("pixel buffer", status)
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
            throw writer.error ?? AudioTestFixtures.FixtureError.osStatus("video append", -2)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? AudioTestFixtures.FixtureError.osStatus("video finish", -3)
        }
        return url
    }

    @Test func trimsTrailingSilentSegments() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [
            try await toneSegment(in: dir, index: 0),
            try await silentSegment(in: dir, index: 1),
            try await silentSegment(in: dir, index: 2),
        ]
        let out = dir.appendingPathComponent("out.m4a")
        let result = try await AudioSegmentMerger.merge(segments: segments, outputURL: out)
        #expect(result.trimmedCount == 2)
        #expect(result.completedFullValidation)
        #expect(abs(result.mergedDuration - 2.0) < 0.3)
        let assetDuration = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(assetDuration - 2.0) < 0.3)
    }

    @Test func allSilentSegmentsAreNotTrimmed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [
            try await silentSegment(in: dir, index: 0),
            try await silentSegment(in: dir, index: 1),
            try await silentSegment(in: dir, index: 2),
        ]
        let out = dir.appendingPathComponent("out.m4a")
        let result = try await AudioSegmentMerger.merge(segments: segments, outputURL: out)
        #expect(result.trimmedCount == 0)
        #expect(abs(result.mergedDuration - 6.0) < 0.5)
    }

    @Test func noSilentTailNothingTrimmed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [
            try await toneSegment(in: dir, index: 0),
            try await toneSegment(in: dir, index: 1),
        ]
        let out = dir.appendingPathComponent("out.m4a")
        let result = try await AudioSegmentMerger.merge(segments: segments, outputURL: out)
        #expect(result.trimmedCount == 0)
        #expect(abs(result.mergedDuration - 4.0) < 0.4)
    }

    @Test func singleSegmentCopyPathNotTrimmed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [try await silentSegment(in: dir, index: 0)]
        let out = dir.appendingPathComponent("out.m4a")
        let result = try await AudioSegmentMerger.merge(segments: segments, outputURL: out)
        #expect(result.trimmedCount == 0)
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(abs(result.mergedDuration - 2.0) < 0.3)
    }

    @Test func micOnlyAudibleTailSegmentKept() async throws {
        // Segment 1's mic track is speaking (system silent) — must be kept.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let micOnly = dir.appendingPathComponent("segment-1.m4a")
        try await AudioTestFixtures.writeM4A(
            tracks: [
                AudioTestFixtures.silence(count: 16000 * 2),
                AudioTestFixtures.sine(count: 16000 * 2, amplitude: 0.1),
            ], to: micOnly)
        let segments = [
            try await toneSegment(in: dir, index: 0),
            micOnly,
            try await silentSegment(in: dir, index: 2),
        ]
        let out = dir.appendingPathComponent("out.m4a")
        let result = try await AudioSegmentMerger.merge(segments: segments, outputURL: out)
        #expect(result.trimmedCount == 1)
        #expect(abs(result.mergedDuration - 4.0) < 0.4)
    }

    @Test func trimToSingleSegmentUsesCopyPath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [
            try await toneSegment(in: dir, index: 0),
            try await silentSegment(in: dir, index: 1),
        ]
        let out = dir.appendingPathComponent("out.m4a")
        let result = try await AudioSegmentMerger.merge(segments: segments, outputURL: out)
        #expect(result.trimmedCount == 1)
        #expect(abs(result.mergedDuration - 2.0) < 0.3)
    }

    @Test(arguments: [0, 1, 2])
    func corruptRequiredSegmentRejectsWholeMerge(corruptIndex: Int) async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var segments: [URL] = []
        for index in 0..<3 {
            if index == corruptIndex {
                let corrupt = dir.appendingPathComponent("segment-\(index).m4a")
                try Data([0x00, 0x01, 0x02, 0x03]).write(to: corrupt)
                segments.append(corrupt)
            } else {
                segments.append(try await toneSegment(in: dir, index: index))
            }
        }
        let out = dir.appendingPathComponent("out.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioSegmentMerger.merge(segments: segments, outputURL: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func zeroDurationInputRejectsWholeMerge() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zeroDuration = try await zeroDurationAudioSegment(in: dir)
        let out = dir.appendingPathComponent("out.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioSegmentMerger.merge(segments: [zeroDuration], outputURL: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func zeroDurationInputInMultiSegmentRejectsWholeMerge() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [
            try await toneSegment(in: dir, index: 0),
            try await zeroDurationAudioSegment(in: dir),
            try await toneSegment(in: dir, index: 2),
        ]
        let out = dir.appendingPathComponent("out.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioSegmentMerger.merge(segments: segments, outputURL: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func inputWithoutAudioTrackRejectsWholeMerge() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoOnly = try await videoOnlySegment(in: dir)
        let out = dir.appendingPathComponent("out.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioSegmentMerger.merge(segments: [videoOnly], outputURL: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func preexistingOutputIsNeverOverwritten() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = try await toneSegment(in: dir, index: 0)
        let out = dir.appendingPathComponent("out.m4a")
        let marker = Data("existing-final-marker".utf8)
        try marker.write(to: out)

        await #expect(throws: (any Error).self) {
            try await AudioSegmentMerger.merge(segments: [segment], outputURL: out)
        }
        #expect(try Data(contentsOf: out) == marker)
    }

    @Test func completeMergePreservesEverySourceByte() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [
            try await toneSegment(in: dir, index: 0),
            try await toneSegment(in: dir, index: 1),
        ]
        let sourceBytes = try segments.map { try Data(contentsOf: $0) }
        let out = dir.appendingPathComponent("out.m4a")

        let result = try await AudioSegmentMerger.merge(segments: segments, outputURL: out)

        #expect(result.skippedCount == 0)
        #expect(result.completedFullValidation)
        #expect(result.mergedDuration > 0)
        #expect(try segments.map { try Data(contentsOf: $0) } == sourceBytes)
        let outputDuration = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(outputDuration.isFinite && outputDuration > 0)
    }

    @Test func timeoutLeavesSourcesAndExistingMarkerUntouched() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = try await toneSegment(in: dir, index: 0)
        let sourceBytes = try Data(contentsOf: segment)
        let out = dir.appendingPathComponent("out.m4a")
        let marker = Data("existing-final-marker".utf8)
        try marker.write(to: out)

        await #expect(throws: (any Error).self) {
            try await AudioSegmentMerger.merge(
                segments: [segment],
                outputURL: out,
                timeoutSeconds: 0
            )
        }
        #expect(try Data(contentsOf: segment) == sourceBytes)
        #expect(try Data(contentsOf: out) == marker)
    }

    @Test func cancelledMergeLeavesSourcesUntouchedAndNoOutput() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments = [
            try await toneSegment(in: dir, index: 0),
            try await toneSegment(in: dir, index: 1),
        ]
        let sourceBytes = try segments.map { try Data(contentsOf: $0) }
        let out = dir.appendingPathComponent("out.m4a")
        let mergeTask = Task {
            try await AudioSegmentMerger.merge(segments: segments, outputURL: out)
        }
        mergeTask.cancel()

        await #expect(throws: (any Error).self) {
            try await mergeTask.value
        }
        #expect(try segments.map { try Data(contentsOf: $0) } == sourceBytes)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func writerCreationFailurePreservesSource() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = try await toneSegment(in: dir, index: 0)
        let sourceBytes = try Data(contentsOf: segment)
        let out = dir.appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("out.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioSegmentMerger.merge(segments: [segment], outputURL: out)
        }
        #expect(try Data(contentsOf: segment) == sourceBytes)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func partiallyTruncatedRequiredInputRejectsWholeMerge() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let valid = try await toneSegment(in: dir, index: 0)
        let validBytes = try Data(contentsOf: valid)
        let truncated = dir.appendingPathComponent("segment-1.m4a")
        try validBytes.prefix(max(1, validBytes.count / 2)).write(to: truncated)
        let out = dir.appendingPathComponent("out.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioSegmentMerger.merge(
                segments: [valid, truncated],
                outputURL: out
            )
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try Data(contentsOf: valid) == validBytes)
    }
}
