import EventKit
import Testing

@testable import Cadenza

/// EKEventStore.authorizationStatus can keep serving its pre-grant value for
/// the rest of the process after the TCC sheet succeeds. The service must
/// treat the sheet's own result as authoritative once it is adopted.
@Suite("CalendarService in-process authorization adoption")
@MainActor
struct CalendarServiceAuthorizationTests {
    @Test func staleClassStatusReadsUnauthorized() {
        let service = CalendarService(authorizationStatusProvider: { .notDetermined })
        #expect(!service.isAuthorized)
    }

    @Test func adoptedGrantOverridesStaleClassStatus() {
        let service = CalendarService(authorizationStatusProvider: { .notDetermined })
        service.adoptAuthorizationGrantedInProcess()
        #expect(service.isAuthorized)
    }

    @Test func freshClassStatusNeedsNoAdoption() {
        let service = CalendarService(authorizationStatusProvider: { .fullAccess })
        #expect(service.isAuthorized)
    }

    @Test func adoptionIsInertWithoutExternalAccess() {
        let service = CalendarService(
            externalAccessEnabled: false,
            authorizationStatusProvider: { .fullAccess }
        )
        service.adoptAuthorizationGrantedInProcess()
        #expect(!service.isAuthorized)
    }
}
