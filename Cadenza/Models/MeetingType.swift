import Foundation

enum MeetingType: String, Codable, CaseIterable, Sendable {
    case oneOnOne, standup, interview, clientMeeting, brainstorm
    case allHands, sprintPlanning, retrospective, designReview, general

    var displayName: String {
        switch self {
        case .oneOnOne: "1:1"
        case .standup: String(localized: "Standup")
        case .interview: String(localized: "Interview")
        case .clientMeeting: String(localized: "Client")
        case .brainstorm: String(localized: "Brainstorm")
        case .allHands: String(localized: "All Hands")
        case .sprintPlanning: String(localized: "Sprint Planning")
        case .retrospective: String(localized: "Retro")
        case .designReview: String(localized: "Design Review")
        case .general: String(localized: "General")
        }
    }

    var summaryGuidance: String {
        switch self {
        case .oneOnOne:
            "This is a 1:1 meeting. Focus on personal feedback, career development topics, individual action items, and blockers discussed."
        case .standup:
            "This is a daily standup. Be concise. Focus on per-person progress, blockers, and plans for the day."
        case .interview:
            "This is an interview. Focus on candidate assessment, key questions asked and responses, strengths/weaknesses observed, and hiring recommendation."
        case .clientMeeting:
            "This is a client meeting. Focus on requirements discussed, deliverables agreed upon, client feedback, and follow-up commitments."
        case .brainstorm:
            "This is a brainstorming session. Focus on ideas generated, pros/cons discussed, and next steps for promising ideas."
        case .allHands:
            "This is an all-hands or town hall meeting. Focus on company announcements, key updates, and Q&A highlights."
        case .sprintPlanning:
            "This is a sprint planning session. Focus on stories committed, effort estimates, team capacity, and sprint goals."
        case .retrospective:
            "This is a sprint retrospective. Focus on what went well, what needs improvement, and action items for the next sprint."
        case .designReview:
            "This is a design review. Focus on design decisions made, feedback given, and iterations or changes needed."
        case .general:
            ""
        }
    }
}
