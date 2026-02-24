import Foundation

@Observable
@MainActor
final class AppState {
    var selectedProject: Project?
    var isCreatingProject = false
    var searchText = ""
}
