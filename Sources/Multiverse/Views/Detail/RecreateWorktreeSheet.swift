import SwiftUI
import SwiftData

struct RecreateWorktreeSheet: View {
    @Bindable var project: Project
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var baseBranch = "main"
    @State private var branches: [GitService.BranchInfo] = []
    @State private var isLoadingBranches = false
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Recreate Worktree")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Branch:")
                        .foregroundStyle(.secondary)
                    Text(project.branchName)
                        .fontWeight(.medium)
                }

                HStack {
                    Text("Base branch:")
                        .foregroundStyle(.secondary)
                    if branches.isEmpty {
                        Picker("", selection: $baseBranch) {
                            Text("main").tag("main")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                        .disabled(true)
                    } else {
                        Picker("", selection: $baseBranch) {
                            ForEach(branches) { branch in
                                Text(branch.name).tag(branch.name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                    if isLoadingBranches {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text("The worktree will be recreated using the existing branch if it still exists, or a new branch from the selected base.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    project.status = .archived
                    try? modelContext.save()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Recreate") {
                    Task { await recreateWorktree() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating)
            }
        }
        .padding()
        .frame(width: 450)
        .onAppear {
            loadBranches()
        }
    }

    private func loadBranches() {
        isLoadingBranches = true
        branches = []
        Task {
            do {
                branches = try await appState.gitService.listBranches(repoPath: project.repoPath)
                if branches.contains(where: { $0.name == "main" }) {
                    baseBranch = "main"
                } else if branches.contains(where: { $0.name == "master" }) {
                    baseBranch = "master"
                } else if let current = branches.first(where: \.isCurrent) {
                    baseBranch = current.name
                } else if let first = branches.first {
                    baseBranch = first.name
                }
            } catch {
                self.error = "Could not load branches: \(error.localizedDescription)"
            }
            isLoadingBranches = false
        }
    }

    private func recreateWorktree() async {
        isCreating = true
        error = nil

        do {
            let worktreePath = try await appState.gitService.createWorktree(
                repoPath: project.repoPath,
                branchName: project.branchName,
                baseBranch: baseBranch
            )
            project.worktreePath = worktreePath
            try? modelContext.save()
            dismiss()
        } catch {
            self.error = "Failed to recreate worktree: \(error.localizedDescription)"
            isCreating = false
        }
    }
}
