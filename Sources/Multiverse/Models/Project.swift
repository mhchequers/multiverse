import Foundation
import SwiftData

@Model
final class Project {
    var id: UUID
    var name: String
    var projectDescription: String
    var deletedAt: Date?

    init(
        name: String,
        description: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.projectDescription = description
        self.deletedAt = nil
    }
}
