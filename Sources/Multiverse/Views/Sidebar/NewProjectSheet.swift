import SwiftUI
import SwiftData

struct NewProjectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var repoPath = ""
    @State private var baseBranch = "main"
    @State private var branchName = ""
    @State private var branches: [GitService.BranchInfo] = []
    @State private var isLoadingBranches = false
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("New Project")
                .font(.headline)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $description)
                .font(.body)
                .frame(height: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Description (optional)")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            Divider()

            // Git worktree section
            VStack(alignment: .leading, spacing: 10) {
                Text("Git Repository")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    TextField("Repository path (optional)", text: $repoPath)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.message = "Select a git repository"
                        panel.directoryURL = URL(fileURLWithPath: "/Users/mattchequers/repos")
                        if panel.runModal() == .OK, let url = panel.url {
                            repoPath = url.path
                            loadBranches()
                        }
                    }
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

                HStack {
                    Text("Branch name:")
                        .foregroundStyle(.secondary)
                    TextField("e.g. feature/my-branch", text: $branchName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    Task { await createProject() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty ||
                    (!repoPath.isEmpty && branchName.trimmingCharacters(in: .whitespaces).isEmpty) ||
                    isCreating
                )
            }
        }
        .padding()
        .frame(width: 900, height: 525)
        .onChange(of: repoPath) {
            if !repoPath.isEmpty {
                loadBranches()
            } else {
                branches = []
            }
        }
    }

    private func loadBranches() {
        isLoadingBranches = true
        branches = []
        Task {
            do {
                branches = try await appState.gitService.listBranches(repoPath: repoPath)
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

    private func createProject() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isCreating = true
        error = nil

        let trimmedBranch = branchName.trimmingCharacters(in: .whitespaces)

        let project = Project(
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespaces),
            repoPath: repoPath,
            branchName: !repoPath.isEmpty ? trimmedBranch : ""
        )
        modelContext.insert(project)
        logActivity(.projectCreated, for: project, in: modelContext)

        if !repoPath.isEmpty && !trimmedBranch.isEmpty {
            do {
                let worktreePath = try await appState.gitService.createWorktree(
                    repoPath: repoPath,
                    branchName: trimmedBranch,
                    baseBranch: baseBranch
                )
                project.worktreePath = worktreePath
                logActivity(.worktreeCreated, detail: worktreePath, for: project, in: modelContext)
            } catch {
                self.error = "Project created, but worktree failed: \(error.localizedDescription)"
                isCreating = false
                try? modelContext.save()
                appState.selectedProject = project
                return
            }
        }

        try? modelContext.save()
        appState.selectedProject = project
        dismiss()
    }
}
