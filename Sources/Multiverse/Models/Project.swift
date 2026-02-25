import Foundation
import SwiftData

@Model
final class Project {
    var id: UUID
    var name: String
    var projectDescription: String
    var repoPath: String = ""
    var branchName: String = ""
    var worktreePath: String?
    var notes: String = ""
    var codePlan: String = ""
    var statusRaw: String = "in_progress"

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRaw) ?? .inProgress }
        set { statusRaw = newValue.rawValue }
    }

    init(
        name: String,
        description: String = "",
        repoPath: String = "",
        branchName: String = "",
        worktreePath: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.projectDescription = description
        self.repoPath = repoPath
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.statusRaw = ProjectStatus.inProgress.rawValue
    }

    enum ProjectStatus: String, CaseIterable {
        case inProgress = "in_progress"
        case archived = "archived"

        var label: String {
            switch self {
            case .inProgress: "In Progress"
            case .archived: "Archived"
            }
        }
    }
}
