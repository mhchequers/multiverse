import SwiftUI
import SwiftData

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 390, max: 500)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if let project = appState.selectedProject {
                ProjectDetailView(project: project)
            } else {
                ContentUnavailableView(
                    "No Project Selected",
                    systemImage: "folder",
                    description: Text("Select a project from the sidebar or create a new one.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.isCreatingProject = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New Project")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(white: 0.35))
                    .foregroundStyle(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("New Project (⌘N)")
            }
        }
        .sheet(isPresented: $state.isCreatingProject) {
            NewProjectSheet()
        }
        .task {
            appState.commitWatcher.start(modelContext: modelContext)
        }
    }
}
