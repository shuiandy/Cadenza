import Testing
import Foundation
@testable import Cadenza

@Suite("GoogleEventParser")
struct GoogleEventParserTests {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesRecurringInstanceWithAllFields() throws {
        let json = """
        {"items":[
          {"id":"abc_20260701T090000Z","summary":"Weekly Sync",
           "start":{"dateTime":"2026-07-01T09:00:00Z"},"end":{"dateTime":"2026-07-01T09:30:00Z"},
           "recurringEventId":"abc","originalStartTime":{"dateTime":"2026-07-01T09:00:00Z"},
           "transparency":"opaque","status":"confirmed",
           "organizer":{"email":"boss@x.com","displayName":"Boss"},
           "attendees":[
             {"email":"me@x.com","self":true,"responseStatus":"accepted"},
             {"email":"boss@x.com","organizer":true,"responseStatus":"accepted"}]}
        ]}
        """
        let events = GoogleEventParser.parse(data(json))
        #expect(events.count == 1)
        let e = try #require(events.first)
        #expect(e.source == .google)
        #expect(e.id == "google_abc_20260701T090000Z")
        #expect(e.providerEventID == "abc")
        #expect(e.isRecurring == true)
        #expect(e.occurrenceAnchor == ISO8601DateFormatter().date(from: "2026-07-01T09:00:00Z"))
        #expect(e.availability == .busy)
        #expect(e.myResponseStatus == .accepted)
        #expect(e.attendees.contains { $0.isCurrentUser && $0.email == "me@x.com" })
        #expect(e.organizer == "Boss")
    }

    @Test func transparentIsFree_andNonRecurringHasNoAnchor() throws {
        let json = """
        {"items":[
          {"id":"solo1","summary":"Focus","start":{"dateTime":"2026-07-01T10:00:00Z"},
           "end":{"dateTime":"2026-07-01T11:00:00Z"},"transparency":"transparent"}
        ]}
        """
        let e = try #require(GoogleEventParser.parse(data(json)).first)
        #expect(e.availability == .free)
        #expect(e.isRecurring == false)
        #expect(e.occurrenceAnchor == nil)
        #expect(e.providerEventID == "")           // 无显式 → resolved 从 id 剥前缀
        #expect(e.resolvedProviderEventID == "solo1")
    }

    @Test func outOfOfficeEventType() throws {
        let json = """
        {"items":[
          {"id":"ooo1","summary":"OOO","eventType":"outOfOffice",
           "start":{"dateTime":"2026-07-01T00:00:00Z"},"end":{"dateTime":"2026-07-01T23:00:00Z"}}
        ]}
        """
        let e = try #require(GoogleEventParser.parse(data(json)).first)
        #expect(e.availability == .outOfOffice)
    }

    @Test func skipsCancelledEvents() {
        let json = """
        {"items":[
          {"id":"c1","summary":"Cancelled","status":"cancelled",
           "start":{"dateTime":"2026-07-01T09:00:00Z"},"end":{"dateTime":"2026-07-01T09:30:00Z"}}
        ]}
        """
        #expect(GoogleEventParser.parse(data(json)).isEmpty)
    }
}
