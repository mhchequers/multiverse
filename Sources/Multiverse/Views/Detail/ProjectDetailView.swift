import SwiftUI

enum DetailTab: String, CaseIterable {
    case description = "Description"
    case notes = "Notes"
    case codePlan = "Code Plan"
    case gitChanges = "Git Changes"
    case fileExplorer = "File Explorer"
    case timeline = "Timeline"
}

extension Notification.Name {
    static let launchClaude = Notification.Name("launchClaude")
    static let openFileInExplorer = Notification.Name("openFileInExplorer")
}

private let codePlanTemplate = """
# Code Plan


## Other important instructions
- Use subagents as you need
"""

struct ProjectDetailView: View {
    @Bindable var project: Project
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirmation = false
    @State private var showRecreateWorktree = false
    @State private var selectedTab: DetailTab = .description
    @State private var isEditing = false
    @FocusState private var editorFocused: Bool
    @State private var terminalHeight: CGFloat = 400

    private var statusColor: Color {
        switch project.status {
        case .inProgress: .green.opacity(0.7)
        case .archived: .red.opacity(0.7)
        }
    }

    private var hasWorktree: Bool {
        if let path = project.worktreePath, !path.isEmpty { return true }
        return false
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

    private func inlineMarkdown(_ source: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }

    private func renderedMarkdown(_ source: String) -> AttributedString {
        var result = AttributedString()
        let lines = source.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            var attributed: AttributedString

            if line.hasPrefix("###### ") {
                attributed = inlineMarkdown(String(line.dropFirst(7)))
                attributed.font = .system(.callout, weight: .bold)
            } else if line.hasPrefix("##### ") {
                attributed = inlineMarkdown(String(line.dropFirst(6)))
                attributed.font = .system(.callout, weight: .bold)
            } else if line.hasPrefix("#### ") {
                attributed = inlineMarkdown(String(line.dropFirst(5)))
                attributed.font = .system(.body, weight: .bold)
            } else if line.hasPrefix("### ") {
                attributed = inlineMarkdown(String(line.dropFirst(4)))
                attributed.font = .system(.title3, weight: .semibold)
            } else if line.hasPrefix("## ") {
                attributed = inlineMarkdown(String(line.dropFirst(3)))
                attributed.font = .system(.title2, weight: .semibold)
            } else if line.hasPrefix("# ") {
                attributed = inlineMarkdown(String(line.dropFirst(2)))
                attributed.font = .system(.title, weight: .bold)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = String(line.dropFirst(2))
                attributed = AttributedString("  \u{2022} ") + inlineMarkdown(content)
            } else if let match = line.range(of: #"^(\d+)\. "#, options: .regularExpression) {
                let number = line[line.startIndex..<line.index(before: match.upperBound)]
                    .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                let content = String(line[match.upperBound...])
                attributed = AttributedString("  \(number). ") + inlineMarkdown(content)
            } else {
                attributed = inlineMarkdown(line)
            }

            result += attributed
            if index < lines.count - 1 {
                result += AttributedString("\n")
            }
        }

        return result
    }

    private func executeCodePlan() {
        logActivity(.codePlanExecuted, for: project, in: modelContext)

        let escaped = project.codePlan.replacingOccurrences(of: "'", with: "'\\''")
        let command = "claude '\(escaped)' --model opus --permission-mode plan --allowed-tools 'Read,Glob,Grep,WebSearch,WebFetch,Task,Bash(git:*)'"

        NotificationCenter.default.post(
            name: .launchClaude,
            object: nil,
            userInfo: [
                "command": command,
                "projectId": project.id.uuidString,
            ]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.title)
                    .fontWeight(.bold)

                HStack {
                    Menu {
                        ForEach(Project.ProjectStatus.allCases, id: \.self) { status in
                            Button(status.label) {
                                project.status = status
                                logActivity(.statusChanged, detail: status.label, for: project, in: modelContext)
                                if status == .inProgress && !hasWorktree && !project.repoPath.isEmpty {
                                    showRecreateWorktree = true
                                }
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

                    Button {
                        let repoPath = project.repoPath
                        let worktreePath = project.worktreePath
                        Task {
                            if let worktreePath, !worktreePath.isEmpty, !repoPath.isEmpty {
                                try? await appState.gitService.removeWorktree(repoPath: repoPath, worktreePath: worktreePath)
                            }
                            await MainActor.run {
                                project.worktreePath = nil
                                logActivity(.worktreeCleared, for: project, in: modelContext)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.minus")
                            Text("Clear Worktree")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(hasWorktree && project.status == .archived ? 0.8 : 0.3))
                        .foregroundStyle(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasWorktree || project.status != .archived)
                    .help(project.status != .archived ? "Archive project first to clear worktree" : hasWorktree ? "Remove git worktree" : "Worktree already cleared")

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

                    Spacer()
                }

                HStack(spacing: 8) {
                    if let dir = terminalDirectory {
                        Text(dir)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if project.status == .archived && !hasWorktree {
                        Label("Worktree cleared", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green.opacity(0.8))
                    }
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
                    let repoPath = project.repoPath
                    let worktreePath = project.worktreePath
                    appState.markProjectDeleted(project.id.uuidString)
                    appState.selectedProject = nil
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

            Divider()

            // Tabbed content area
            VStack(spacing: 0) {
                // Tab bar
                HStack(spacing: 0) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            HStack(spacing: 4) {
                                Text(tab.rawValue)
                                    .font(.headline)
                                    .fontWeight(selectedTab == tab ? .semibold : .regular)

                                if selectedTab == tab && tab != .timeline && tab != .gitChanges && tab != .fileExplorer {
                                    Button {
                                        if isEditing {
                                            try? modelContext.save()
                                        }
                                        isEditing.toggle()
                                    } label: {
                                        Image(systemName: isEditing ? "checkmark" : "pencil")
                                            .font(.system(size: 9))
                                            .foregroundStyle(isEditing ? Color.accentColor : .secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(isEditing ? "Done editing" : "Edit")
                                }
                            }
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
                    if isEditing {
                        TextEditor(text: $project.projectDescription)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .focused($editorFocused)
                            .onAppear { editorFocused = true }
                            .onChange(of: project.projectDescription) {
                                try? modelContext.save()
                            }
                    } else {
                        ScrollView {
                            if project.projectDescription.isEmpty {
                                Text("No description.")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding()
                            } else {
                                Text(renderedMarkdown(project.projectDescription))
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding()
                            }
                        }
                        .onTapGesture(count: 2) {
                            isEditing = true
                        }
                    }
                case .notes:
                    if isEditing {
                        TextEditor(text: $project.notes)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .focused($editorFocused)
                            .onAppear { editorFocused = true }
                            .onChange(of: project.notes) {
                                try? modelContext.save()
                            }
                    } else {
                        ScrollView {
                            if project.notes.isEmpty {
                                Text("No notes yet.")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding()
                            } else {
                                Text(renderedMarkdown(project.notes))
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding()
                            }
                        }
                        .onTapGesture(count: 2) {
                            isEditing = true
                        }
                    }
                case .codePlan:
                    VStack(spacing: 0) {
                        if isEditing {
                            TextEditor(text: $project.codePlan)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .focused($editorFocused)
                                .onAppear { editorFocused = true }
                                .onChange(of: project.codePlan) {
                                    try? modelContext.save()
                                }
                        } else {
                            ScrollView {
                                Text(renderedMarkdown(project.codePlan))
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding()
                            }
                            .onTapGesture(count: 2) {
                                isEditing = true
                            }
                        }

                        Divider()

                        HStack {
                            Spacer()
                            Button {
                                project.codePlan = codePlanTemplate
                                logActivity(.codePlanReset, for: project, in: modelContext)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("Reset Plan")
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.gray.opacity(0.3))
                                .foregroundStyle(.white)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)

                            Button {
                                executeCodePlan()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.fill")
                                    Text("Execute Plan")
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .disabled(project.codePlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || terminalDirectory == nil)
                            .padding(10)
                        }
                    }
                case .gitChanges:
                    GitChangesView(project: project)
                case .fileExplorer:
                    FileExplorerView(project: project)
                case .timeline:
                    TimelineView(project: project)
                }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: selectedTab) {
                if selectedTab == .codePlan && project.codePlan.isEmpty {
                    project.codePlan = codePlanTemplate
                    try? modelContext.save()
                }
            }
            .onChange(of: editorFocused) {
                if !editorFocused && isEditing {
                    try? modelContext.save()
                    switch selectedTab {
                    case .description:
                        logActivity(.descriptionEdited, for: project, in: modelContext)
                    case .notes:
                        logActivity(.notesEdited, for: project, in: modelContext)
                    default:
                        break
                    }
                    isEditing = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFileInExplorer)) { notification in
                guard let targetId = notification.userInfo?["projectId"] as? String,
                      targetId == project.id.uuidString else { return }
                selectedTab = .fileExplorer
            }

            // Draggable divider
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let delta = -value.translation.height
                            terminalHeight = max(100, min(600, terminalHeight + delta))
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }

            // Terminal panel
            if let dir = terminalDirectory {
                TerminalPanelView(workingDirectory: dir, projectId: project.id.uuidString)
                    .id(dir)
                    .frame(height: terminalHeight)
            } else {
                ContentUnavailableView(
                    "No Repository",
                    systemImage: "terminal",
                    description: Text("This project has no git repository configured.")
                )
                .frame(height: terminalHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showRecreateWorktree) {
            RecreateWorktreeSheet(project: project)
                .environment(appState)
        }
    }
}
