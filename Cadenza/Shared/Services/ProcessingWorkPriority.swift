import Foundation
import os

/// Priority for background transcription and diarization work, lowered while a
/// recording lease is held.
///
/// A previous meeting's transcription used to run at `.userInitiated` next to
/// the live capture path: the background job outranked the recording it was
/// competing with for CPU. Nothing here defers, blocks or cancels processing;
/// only the CPU order changes while the two genuinely collide.
///
/// Scope, stated plainly: the priority is applied where a stage task is
/// created (transcription root, summary generation, the local Whisper worker,
/// the diarization decode). A task keeps the priority it started with, and a
/// child that a higher-priority task awaits is escalated to the awaiter's
/// priority, so this is not a dynamic throttle for work already in flight. The
/// capture path's queue QoS and the export queues' `.utility` are the
/// unconditional part; a true per-chunk budget is the validation-first item
/// T5 of the performance review.
final class ProcessingWorkPriority: Sendable {
    static let shared = ProcessingWorkPriority()

    private let recordingActive = OSAllocatedUnfairLock(initialState: false)

    var isRecordingActive: Bool { recordingActive.withLock { $0 } }

    var current: TaskPriority { isRecordingActive ? .utility : .userInitiated }

    func setRecordingActive(_ active: Bool) {
        recordingActive.withLock { $0 = active }
    }
}
