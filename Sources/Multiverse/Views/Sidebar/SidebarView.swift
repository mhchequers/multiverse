import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var projects: [Project]

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            Picker("Status", selection: $state.statusFilter) {
                ForEach(Project.ProjectStatus.allCases, id: \.self) { status in
                    Text(status.label).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

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
        }
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "Search projects...")
    }

    private var filteredProjects: [Project] {
        let active = projects.filter { $0.status == appState.statusFilter }
        let filtered: [Project]
        if appState.searchText.isEmpty {
            filtered = active
        } else {
            let query = appState.searchText.lowercased()
            filtered = active.filter {
                $0.name.lowercased().contains(query) ||
                $0.projectDescription.lowercased().contains(query)
            }
        }
        return filtered.sorted {
            let t0 = $0.activities.map(\.timestamp).max() ?? .distantPast
            let t1 = $1.activities.map(\.timestamp).max() ?? .distantPast
            return t0 > t1
        }
    }
}
