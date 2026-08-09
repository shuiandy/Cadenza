import SwiftData
import Foundation

/// Safe accessors for SwiftData relationships that may reference invalidated objects.
/// Uses Objective-C exception handling to catch Core Data faults on missing backing data.
/// These are read-only — they never modify the store, just return nil instead of crashing.
extension Recording {
    /// Safely access the transcript relationship. Returns nil if the backing data is missing.
    var safeTranscript: Transcript? {
        var result: Transcript?
        let ok = ObjCExceptionCatch {
            result = self.transcript
            // Force fault-in by touching a property
            _ = result?.fullText
        }
        return ok ? result : nil
    }

    /// Safely access the summary relationship. Returns nil if the backing data is missing.
    var safeSummary: MeetingSummary? {
        var result: MeetingSummary?
        let ok = ObjCExceptionCatch {
            result = self.summary
            _ = result?.overview
        }
        return ok ? result : nil
    }
}
