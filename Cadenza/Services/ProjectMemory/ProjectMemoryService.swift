import Foundation

/// Builds folder-scoped AI prompts from structured folder context.
/// Separate from library search -- this assembles context packets for AI, not UI rows.
enum ProjectMemoryService {

    /// Build a system prompt for folder-scoped AI chat.
    static func buildSystemPrompt(context: FolderContextDTO) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var prompt = """
        You are an AI assistant for the folder "\(context.folderName)".
        Answer questions based ONLY on the folder data provided below.
        Be concise and practical. If information is not in the data, say so.
        When referencing information, mention which meeting it came from.
        """

        prompt += AIContextAssembler.identityBlock()

        prompt += """


        Folder: \(context.folderName)
        Status: \(context.folderStatus)
        Total meetings: \(context.totalRecordingCount)
        """

        if !context.knownSpeakers.isEmpty {
            prompt += "\nKnown participants: \(context.knownSpeakers.joined(separator: ", "))"
        }

        // Recent meetings with summaries
        if !context.recentMeetings.isEmpty {
            prompt += "\n\n=== Recent Meetings ===\n"
            for meeting in context.recentMeetings {
                let date = dateFormatter.string(from: meeting.date)
                prompt += "\n--- \(meeting.title) (\(date), \(meeting.durationMinutes)m) ---\n"
                if !meeting.overview.isEmpty {
                    prompt += "Overview: \(meeting.overview)\n"
                }
                if !meeting.keyPoints.isEmpty {
                    prompt += "Key Points: \(meeting.keyPoints.joined(separator: "; "))\n"
                }
                if !meeting.decisions.isEmpty {
                    prompt += "Decisions: \(meeting.decisions.joined(separator: "; "))\n"
                }
                if !meeting.followUps.isEmpty {
                    prompt += "Follow-ups: \(meeting.followUps.joined(separator: "; "))\n"
                }
                if !meeting.actionItems.isEmpty {
                    let items = meeting.actionItems.map { item in
                        var s = "- \(item.task)"
                        if let assignee = item.assignee, !assignee.isEmpty { s += " (@\(assignee))" }
                        if let deadline = item.deadline, !deadline.isEmpty { s += " [due: \(deadline)]" }
                        if item.isCompleted { s += " [DONE]" }
                        return s
                    }
                    prompt += "Action Items:\n\(items.joined(separator: "\n"))\n"
                }
            }
        }

        // Open action items across all folder meetings
        if !context.openActionItems.isEmpty {
            prompt += "\n=== Open Action Items (across all meetings) ===\n"
            for entry in context.openActionItems {
                var s = "- \(entry.item.task)"
                if let assignee = entry.item.assignee, !assignee.isEmpty { s += " (@\(assignee))" }
                if let deadline = entry.item.deadline, !deadline.isEmpty { s += " [due: \(deadline)]" }
                s += " (from: \(entry.sourceRecordingTitle))"
                prompt += "\(s)\n"
            }
        }

        // Recent decisions
        if !context.recentDecisions.isEmpty {
            prompt += "\n=== Recent Decisions ===\n"
            for entry in context.recentDecisions {
                prompt += "- \(entry.text) (from: \(entry.sourceRecordingTitle))\n"
            }
        }

        // Follow-ups
        if !context.followUps.isEmpty {
            prompt += "\n=== Follow-ups ===\n"
            for entry in context.followUps {
                prompt += "- \(entry.text) (from: \(entry.sourceRecordingTitle))\n"
            }
        }

        return prompt
    }

    /// Build a system prompt specifically for generating a one-shot folder brief.
    static func buildBriefPrompt(context: FolderContextDTO) -> String {
        let base = buildSystemPrompt(context: context)
        return base + """

        \nYou are generating a folder status brief. Summarize the current state of this folder in a clear, structured format:
        1. Current Status -- What's the latest progress?
        2. Key Decisions -- What was recently decided?
        3. Open Action Items -- What needs to be done, by whom?
        4. Blockers & Follow-ups -- What's unresolved?
        5. Next Steps -- What should happen next?

        Be concise. Use bullet points. Reference specific meetings when relevant.
        """
    }
}
