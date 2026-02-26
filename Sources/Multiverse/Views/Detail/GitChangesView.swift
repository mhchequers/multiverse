import SwiftUI

struct GitChangesView: View {
    let project: Project
    @Environment(AppState.self) private var appState
    @State private var viewModel: GitChangesViewModel?

    private var workingDirectory: String? {
        if let wt = project.worktreePath, !wt.isEmpty { return wt }
        if !project.repoPath.isEmpty { return project.repoPath }
        return nil
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                HSplitView {
                    fileListPanel(vm: vm)
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 400)

                    Group {
                        if vm.showSideBySide {
                            SideBySideDiffView(
                                lines: vm.sideBySideLines,
                                filename: vm.selectedFile?.path ?? ""
                            )
                        } else {
                            DiffView(
                                lines: vm.diffLines,
                                filename: vm.selectedFile?.path ?? ""
                            )
                        }
                    }
                    .frame(minWidth: 300)
                }
            } else {
                ContentUnavailableView(
                    "No Repository",
                    systemImage: "arrow.triangle.branch",
                    description: Text("This project has no git repository configured.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let dir = workingDirectory {
                let vm = GitChangesViewModel(gitService: appState.gitService, directory: dir)
                viewModel = vm
                Task { await vm.refresh() }
            }
        }
        .onChange(of: project.id) {
            if let dir = workingDirectory {
                let vm = GitChangesViewModel(gitService: appState.gitService, directory: dir)
                viewModel = vm
                Task { await vm.refresh() }
            } else {
                viewModel = nil
            }
        }
    }

    @ViewBuilder
    private func fileListPanel(vm: GitChangesViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changes")
                    .font(.headline)
                Spacer()
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await vm.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh git status")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if vm.fileChanges.isEmpty && !vm.isLoading {
                ContentUnavailableView(
                    "Working Tree Clean",
                    systemImage: "checkmark.circle",
                    description: Text("No staged or unstaged changes.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !vm.stagedChanges.isEmpty {
                            sectionHeader("Staged Changes", count: vm.stagedChanges.count)
                            ForEach(vm.stagedChanges) { file in
                                fileRow(file, vm: vm)
                            }
                        }
                        if !vm.unstagedChanges.isEmpty {
                            sectionHeader("Changes", count: vm.unstagedChanges.count)
                            ForEach(vm.unstagedChanges) { file in
                                fileRow(file, vm: vm)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func fileRow(_ file: FileChange, vm: GitChangesViewModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: file.status.icon)
                .foregroundStyle(file.status.color)
                .font(.system(size: 12))

            Text(file.filename)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            if !file.directory.isEmpty {
                Text(file.directory)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(String(file.status.label.prefix(1)))
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(file.status.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(vm.selectedFile == file ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task { await vm.doubleClickFile(file) }
        }
        .onTapGesture(count: 1) {
            Task { await vm.selectFile(file) }
        }
    }
}
