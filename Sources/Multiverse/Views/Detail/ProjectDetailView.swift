import SwiftUI

struct ProjectDetailView: View {
    @Bindable var project: Project
    @Environment(AppState.self) private var appState
    @State private var terminalView: MonitoredTerminalView?

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
            // Project info header
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.title2)
                    .fontWeight(.bold)

                if !project.projectDescription.isEmpty {
                    Text(project.projectDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

            Divider()

            // Terminal or placeholder
            if let dir = terminalDirectory {
                TerminalRepresentable(
                    workingDirectory: dir,
                    terminalView: $terminalView
                )
                .onAppear {
                    if let tv = terminalView {
                        appState.registerTerminal(tv)
                    }
                }
                .onDisappear {
                    if let tv = terminalView {
                        appState.unregisterTerminal(tv)
                        tv.terminateProcessGroup()
                    }
                    terminalView = nil
                }
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
