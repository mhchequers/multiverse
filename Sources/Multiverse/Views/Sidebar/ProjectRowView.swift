import SwiftUI

struct ProjectRowView: View {
    @Bindable var project: Project
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.body)
                .fontWeight(.semibold)
                .lineLimit(1)

            if !project.projectDescription.isEmpty {
                Text(project.projectDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete \"\(project.name)\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let repoPath = project.repoPath
                let worktreePath = project.worktreePath
                if appState.selectedProject?.id == project.id {
                    appState.selectedProject = nil
                }
                modelContext.delete(project)
                try? modelContext.save()
                if let worktreePath, !worktreePath.isEmpty, !repoPath.isEmpty {
                    Task {
                        try? await appState.gitService.removeWorktree(repoPath: repoPath, worktreePath: worktreePath)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This project will be removed from your list.")
        }
    }
}
