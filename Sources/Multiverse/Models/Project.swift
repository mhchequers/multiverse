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
    var deletedAt: Date?

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
        self.deletedAt = nil
    }
}
