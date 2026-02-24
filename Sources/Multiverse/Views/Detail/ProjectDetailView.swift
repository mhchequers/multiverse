import SwiftUI

enum DetailTab: String, CaseIterable {
    case description = "Description"
}

struct ProjectDetailView: View {
    @Bindable var project: Project
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirmation = false
    @State private var selectedTab: DetailTab = .description

    private var statusColor: Color {
        switch project.status {
        case .inProgress: .green.opacity(0.7)
        case .archived: .red.opacity(0.7)
        }
    }

    private var terminalDirectory: String? {
        if let worktreePath = project.worktreePath, !worktreePath.isEmpty {
            return worktreePath
        }
        if !project.repoPath.isEmpty {
            return project.repoPath
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(project.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    Menu {
                        ForEach(Project.ProjectStatus.allCases, id: \.self) { status in
                            Button(status.label) {
                                project.status = status
                                try? modelContext.save()
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(project.status.label)
                                .font(.caption)
                                .fontWeight(.medium)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor)
                        .foregroundStyle(.white)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Delete")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.red.opacity(0.8))
                        .foregroundStyle(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Delete project")
                }

                if let dir = terminalDirectory {
                    Text(dir)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .confirmationDialog(
                "Delete \"\(project.name)\"?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    project.deletedAt = Date()
                    appState.selectedProject = nil
                    try? modelContext.save()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This project will be removed from your list.")
            }

            Divider()

            // Tabbed content area
            VStack(spacing: 0) {
                // Tab bar
                HStack(spacing: 0) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            Text(tab.rawValue)
                                .font(.subheadline)
                                .fontWeight(selectedTab == tab ? .semibold : .regular)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(selectedTab == tab ? Color.white.opacity(0.1) : Color.clear)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Divider()

                // Tab content
                switch selectedTab {
                case .description:
                    ScrollView {
                        Text(project.projectDescription.isEmpty ? "No description." : project.projectDescription)
                            .font(.body)
                            .foregroundStyle(project.projectDescription.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding()
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Terminal panel
            if let dir = terminalDirectory {
                TerminalPanelView(workingDirectory: dir)
                    .frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Repository",
                    systemImage: "terminal",
                    description: Text("This project has no git repository configured.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
