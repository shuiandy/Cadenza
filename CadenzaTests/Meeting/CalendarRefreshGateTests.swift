import Foundation
import Testing

@testable import Cadenza

@Suite("Calendar refresh publication gate")
struct CalendarRefreshGateTests {
    @Test func onlyLatestRefreshMayPublish() {
        var gate = CalendarRefreshGate()
        let first = gate.begin()
        let second = gate.begin()

        #expect(!gate.accepts(first))
        #expect(gate.accepts(second))
    }

    @Test func invalidationRejectsPreviouslyCurrentRefresh() {
        var gate = CalendarRefreshGate()
        let refresh = gate.begin()

        gate.invalidate()

        #expect(!gate.accepts(refresh))
    }
}

@Suite("Calendar external access")
struct CalendarExternalAccessTests {
    @MainActor
    @Test func policyDefaultsToEnabledAndUsesAnInjectedResourceFactory() {
        var constructionCount = 0
        let policy = CalendarExternalAccessPolicy()

        let resource = policy.makeResource {
            constructionCount += 1
            return "fixture"
        }

        #expect(policy.isEnabled)
        #expect(resource == "fixture")
        #expect(constructionCount == 1)
    }

    @MainActor
    @Test func disabledPolicyNeverConstructsAnExternalResource() {
        var constructionCount = 0
        let policy = CalendarExternalAccessPolicy(isEnabled: false)

        let resource: String? = policy.makeResource {
            constructionCount += 1
            return "must-not-be-created"
        }

        #expect(!policy.isEnabled)
        #expect(resource == nil)
        #expect(constructionCount == 0)
    }

    @MainActor
    @Test func disabledCalendarServiceNeverMonitorsOrReadsEventKit() async {
        let service = CalendarService(
            externalAccessEnabled: false,
            eventStoreFactory: {
                fatalError("Disabled calendar access must not construct EKEventStore")
            }
        )
        let now = Date()

        #expect(!service.externalAccessEnabled)
        #expect(!service.isAuthorized)
        #expect(!(await service.requestAccess()))
        #expect(service.availableCalendars().isEmpty)
        #expect(service.fetchEvents(from: now, to: now.addingTimeInterval(60)).isEmpty)

        service.startMonitoring(pollInterval: 0.001)
        service.refreshMeetings()

        #expect(!service.isMonitoring)
        #expect(service.upcomingMeetings.isEmpty)
        #expect(service.currentMeeting == nil)
        #expect(service.nextMeetingStartingSoon(withinMinutes: 15) == nil)
    }

    @MainActor
    @Test func disabledManagerCannotBypassIsolationThroughMonitoringOrRefresh() async {
        let manager = CalendarManager(externalAccessEnabled: false)
        let now = Date()

        #expect(!manager.externalAccessEnabled)
        #expect(!manager.appleCalendarService.externalAccessEnabled)
        #expect(manager.hasCompletedInitialRefresh)

        manager.startMonitoring(pollInterval: 0.001)
        manager.refreshAll()
        manager.refreshCurrentMeetingFromCache()

        #expect(!manager.isMonitoring)
        #expect(manager.hasCompletedInitialRefresh)
        #expect(manager.upcomingMeetings.isEmpty)
        #expect(manager.currentMeeting == nil)
        #expect(manager.availableCalendars().isEmpty)
        #expect(manager.fetchEvents(from: now, to: now.addingTimeInterval(60)).isEmpty)
        #expect(manager.nextMeetingStartingSoon(withinMinutes: 15) == nil)
        #expect(manager.currentMeetingForDetectionContext(now: now) == nil)

        let autoLink = await manager.fetchEventsForAutoLink(
            from: now,
            to: now.addingTimeInterval(60)
        )
        #expect(autoLink.events.isEmpty)
        #expect(!autoLink.canConcludeNoMatch)
    }

    @MainActor
    @Test func successfulRemoteRefreshClearsTransientProviderErrors() {
        let manager = CalendarManager(externalAccessEnabled: false)
        manager.googleCalendarService.error = "transient Google failure"
        manager.zoomMeetingService.error = "transient Zoom failure"

        manager.recordSuccessfulRemoteRefresh(for: .google)
        #expect(manager.googleCalendarService.error == nil)
        #expect(manager.zoomMeetingService.error == "transient Zoom failure")

        manager.recordSuccessfulRemoteRefresh(for: .zoom)
        #expect(manager.zoomMeetingService.error == nil)
    }
}
