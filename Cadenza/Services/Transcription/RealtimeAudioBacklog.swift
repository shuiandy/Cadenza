import Foundation

/// 24 kHz mono PCM16 audio kept in stream order, bounded by dropping the oldest
/// bytes. `TranscriptionManager` keeps one for the audio a live session was sent
/// until the provider finalizes it, and one for audio captured while a dropped
/// session reconnects, so that a drop delays captions instead of losing words.
struct RealtimeAudioBacklog: Sendable {
    /// Appends coalesce into blocks of about one second. Capture delivers ~20 ms
    /// buffers, and a replay queued as hundreds of those would trip the send
    /// queue's chunk-count limit, which keeps only the newest chunks.
    static let blockBytes = 48_000

    let capacity: Int
    private(set) var blocks: [Data] = []
    private(set) var byteCount = 0
    /// Stream offset of the first retained byte.
    private(set) var startOffset = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    var isEmpty: Bool { byteCount == 0 }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        if let last = blocks.indices.last, blocks[last].count < Self.blockBytes {
            blocks[last].append(data)
        } else {
            blocks.append(Data(data))
        }
        byteCount += data.count
        if byteCount > capacity {
            dropFirst(byteCount - capacity)
        }
    }

    mutating func append(contentsOf other: RealtimeAudioBacklog) {
        for block in other.blocks {
            append(block)
        }
    }

    /// Forgets everything before stream offset `offset`.
    mutating func discard(before offset: Int) {
        dropFirst(offset - startOffset)
    }

    private mutating func dropFirst(_ count: Int) {
        // Whole samples only, so what remains stays sample-aligned.
        var remaining = min(max(0, count), byteCount) & ~1
        startOffset += remaining
        byteCount -= remaining
        while remaining > 0, let first = blocks.first {
            if first.count <= remaining {
                remaining -= first.count
                blocks.removeFirst()
            } else {
                blocks[0] = Data(first.dropFirst(remaining))
                remaining = 0
            }
        }
    }
}
