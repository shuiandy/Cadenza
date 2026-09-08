import Foundation

/// Asymmetric scheduling between audio capture and post-processing work.
///
/// Recording owns one exclusive lease from the beginning of start-up through
/// durable stop finalization, and it is never refused because processing is
/// running: live capture must be available the moment the next meeting
/// starts, so a recording claim only competes with other recording claims and
/// reserved intents. Post-processing owns one lease per automatic or manual
/// operation; processing leases may overlap with each other and with a live
/// recording, but no *new* processing claim is granted while a recording
/// lease or reserved intent is present — heavy transcription work yields to
/// capture and drains at the next all-idle edge. MainActor confinement makes
/// every claim and the normal-stop recording-to-processing handoff a single,
/// non-suspending state transition.
@MainActor
final class RecordingProcessingGate {
    struct RecordingIntent: Sendable, Equatable {
        fileprivate let ownerID: UUID
        fileprivate let id: UUID
    }

    struct RecordingLease: Sendable, Equatable {
        fileprivate let ownerID: UUID
        fileprivate let id: UUID
    }

    struct ProcessingLease: Sendable, Equatable {
        fileprivate let ownerID: UUID
        fileprivate let id: UUID
    }

    private let id = UUID()
    private let workPriority: ProcessingWorkPriority
    private var recordingIntentID: UUID?
    private var recordingLeaseID: UUID? {
        didSet { workPriority.setRecordingActive(recordingLeaseID != nil) }
    }

    init(workPriority: ProcessingWorkPriority = .shared) {
        self.workPriority = workPriority
    }
    private var processingLeaseIDs: Set<UUID> = []
    private var allIdleObservers: [UUID: @MainActor () -> Void] = [:]
    private var isNotifyingLeaseIdle = false
    private var needsAnotherLeaseIdleNotification = false

    var hasRecordingIntent: Bool {
        recordingIntentID != nil
    }

    var hasRecordingLease: Bool {
        recordingLeaseID != nil
    }

    var hasProcessingLeases: Bool {
        !processingLeaseIDs.isEmpty
    }

    var isAllIdle: Bool {
        recordingIntentID == nil
            && recordingLeaseID == nil
            && processingLeaseIDs.isEmpty
    }

    /// Reserves the next exclusive recording claim while existing processing
    /// finishes. Processing already in flight is unaffected, but no new
    /// processing claim can overtake this intent.
    func reserveRecordingIntent() -> RecordingIntent? {
        guard recordingIntentID == nil else { return nil }
        let intentID = UUID()
        recordingIntentID = intentID
        return RecordingIntent(ownerID: id, id: intentID)
    }

    /// Claims recording exclusively against other recordings and reserved
    /// intents. Processing leases already in flight never refuse this claim.
    /// Balance with `releaseRecording`, or use
    /// `transitionRecordingToProcessing` during a successful normal stop.
    func claimRecording() -> RecordingLease? {
        guard recordingIntentID == nil,
              recordingLeaseID == nil else { return nil }
        let leaseID = UUID()
        recordingLeaseID = leaseID
        return RecordingLease(ownerID: id, id: leaseID)
    }

    /// Atomically consumes a previously reserved recording intent and turns it
    /// into the live recording lease. A stale or foreign intent cannot claim;
    /// processing leases already in flight never refuse the consumption.
    func claimRecording(consuming intent: RecordingIntent) -> RecordingLease? {
        guard intent.ownerID == id,
              recordingIntentID == intent.id,
              recordingLeaseID == nil else { return nil }
        let leaseID = UUID()
        recordingIntentID = nil
        recordingLeaseID = leaseID
        return RecordingLease(ownerID: id, id: leaseID)
    }

    /// Claims one processing operation. Processing operations may run in
    /// parallel, but a live recording lease or reserved recording intent
    /// refuses every new processing claim: transcription work yields to
    /// capture and is deferred by the caller until the next all-idle edge.
    func claimProcessing() -> ProcessingLease? {
        guard recordingIntentID == nil, recordingLeaseID == nil else { return nil }
        let leaseID = UUID()
        processingLeaseIDs.insert(leaseID)
        return ProcessingLease(ownerID: id, id: leaseID)
    }

    /// Atomically hands a live recording lease to one post-processing
    /// operation. Observers never see an all-idle gap between the two phases.
    func transitionRecordingToProcessing(
        _ lease: RecordingLease
    ) -> ProcessingLease? {
        guard lease.ownerID == id, recordingLeaseID == lease.id else { return nil }
        let processingLeaseID = UUID()
        processingLeaseIDs.insert(processingLeaseID)
        recordingLeaseID = nil
        return ProcessingLease(ownerID: id, id: processingLeaseID)
    }

    func releaseRecording(_ lease: RecordingLease?) {
        guard let lease,
              lease.ownerID == id,
              recordingLeaseID == lease.id else { return }
        recordingLeaseID = nil
        notifyAllIdleIfNeeded()
    }

    /// Cancels an intent that can no longer become a recording. If leases are
    /// already idle, observers receive another opportunity immediately so
    /// deferred processing cannot remain stranded behind the cancelled intent.
    func cancelRecordingIntent(_ intent: RecordingIntent?) {
        guard let intent,
              intent.ownerID == id,
              recordingIntentID == intent.id else { return }
        recordingIntentID = nil
        notifyAllIdleIfNeeded()
    }

    func releaseProcessing(_ lease: ProcessingLease?) {
        guard let lease, lease.ownerID == id else { return }
        guard processingLeaseIDs.remove(lease.id) != nil else { return }
        notifyAllIdleIfNeeded()
    }

    func ownsProcessing(_ lease: ProcessingLease) -> Bool {
        lease.ownerID == id && processingLeaseIDs.contains(lease.id)
    }

    /// Observers are called when active leases become idle. A recording intent
    /// may still be present, so callers must claim through the gate rather than
    /// treating this callback as permission to start work.
    @discardableResult
    func observeAllIdle(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let observerID = UUID()
        allIdleObservers[observerID] = observer
        return observerID
    }

    func removeAllIdleObserver(_ observerID: UUID?) {
        guard let observerID else { return }
        allIdleObservers.removeValue(forKey: observerID)
    }

    private func notifyAllIdleIfNeeded() {
        guard recordingLeaseID == nil, processingLeaseIDs.isEmpty else { return }
        if isNotifyingLeaseIdle {
            needsAnotherLeaseIdleNotification = true
            return
        }

        isNotifyingLeaseIdle = true
        repeat {
            needsAnotherLeaseIdleNotification = false
            let observers = Array(allIdleObservers.values)
            for observer in observers {
                observer()
            }
        } while needsAnotherLeaseIdleNotification
            && recordingLeaseID == nil
            && processingLeaseIDs.isEmpty
        isNotifyingLeaseIdle = false
    }
}
