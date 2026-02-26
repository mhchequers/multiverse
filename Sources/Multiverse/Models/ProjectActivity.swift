import Foundation
import SwiftUI
import SwiftData

@Model
final class ProjectActivity {
    var id: UUID
    var timestamp: Date
    var eventTypeRaw: String
    var detail: String?
    var project: Project?

    var eventType: EventType {
        EventType(rawValue: eventTypeRaw) ?? .projectCreated
    }

    init(type: EventType, detail: String? = nil, project: Project) {
        self.id = UUID()
        self.timestamp = Date()
        self.eventTypeRaw = type.rawValue
        self.detail = detail
        self.project = project
    }

    enum EventType: String {
        case projectCreated
        case statusChanged
        case descriptionEdited
        case notesEdited
        case codePlanExecuted
        case codePlanReset
        case worktreeCreated
        case worktreeCleared
        case commitDetected

        var label: String {
            switch self {
            case .projectCreated: "Project created"
            case .statusChanged: "Status changed"
            case .descriptionEdited: "Description edited"
            case .notesEdited: "Notes edited"
            case .codePlanExecuted: "Code plan executed"
            case .codePlanReset: "Code plan reset"
            case .worktreeCreated: "Worktree created"
            case .worktreeCleared: "Worktree cleared"
            case .commitDetected: "Commit"
            }
        }

        var icon: String {
            switch self {
            case .projectCreated: "plus.circle"
            case .statusChanged: "arrow.triangle.2.circlepath"
            case .descriptionEdited: "doc.text"
            case .notesEdited: "note.text"
            case .codePlanExecuted: "play.fill"
            case .codePlanReset: "arrow.counterclockwise"
            case .worktreeCreated: "folder.badge.plus"
            case .worktreeCleared: "folder.badge.minus"
            case .commitDetected: "arrow.triangle.branch"
            }
        }

        var color: Color {
            switch self {
            case .projectCreated: .green
            case .statusChanged: .orange
            case .descriptionEdited: .blue
            case .notesEdited: .blue
            case .codePlanExecuted: .purple
            case .codePlanReset: .gray
            case .worktreeCreated: .green
            case .worktreeCleared: .orange
            case .commitDetected: .cyan
            }
        }
    }
}

func logActivity(_ type: ProjectActivity.EventType, detail: String? = nil,
                 for project: Project, in context: ModelContext) {
    let activity = ProjectActivity(type: type, detail: detail, project: project)
    context.insert(activity)
    try? context.save()
}
