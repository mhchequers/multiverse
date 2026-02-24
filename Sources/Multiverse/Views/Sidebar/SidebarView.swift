import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var projects: [Project]

    var body: some View {
        @Bindable var state = appState

        List(selection: $state.selectedProject) {
            if !filteredProjects.isEmpty {
                ForEach(filteredProjects) { project in
                    ProjectRowView(project: project)
                        .tag(project)
                }
            } else if !appState.searchText.isEmpty {
                ContentUnavailableView.search(text: appState.searchText)
            } else {
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "folder",
                    description: Text("Press ⌘N to create your first project.")
                )
            }
        }
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "Search projects...")
    }

    private var filteredProjects: [Project] {
        let active = projects.filter { $0.deletedAt == nil }
        if appState.searchText.isEmpty { return active }
        let query = appState.searchText.lowercased()
        return active.filter {
            $0.name.lowercased().contains(query) ||
            $0.projectDescription.lowercased().contains(query)
        }
    }
}
