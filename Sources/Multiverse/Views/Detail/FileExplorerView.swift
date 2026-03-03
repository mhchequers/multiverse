import SwiftUI

struct FileExplorerView: View {
    let project: Project
    @Environment(AppState.self) private var appState
    @State private var viewModel: FileExplorerViewModel?

    private var workingDirectory: String? {
        if let wt = project.worktreePath, !wt.isEmpty { return wt }
        if !project.repoPath.isEmpty { return project.repoPath }
        return nil
    }

    private func ensureViewModel() {
        let projectId = project.id.uuidString
        if let cached = appState.fileExplorerVM(for: projectId) {
            viewModel = cached
        } else if let dir = workingDirectory {
            let vm = FileExplorerViewModel(gitService: appState.gitService, directory: dir)
            viewModel = vm
            appState.cacheFileExplorerVM(vm, for: projectId)
            Task { await vm.loadFileTree() }
        } else {
            viewModel = nil
        }
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                HSplitView {
                    fileTreePanel(vm: vm)
                        .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)

                    editorPanel(vm: vm)
                        .frame(minWidth: 300)
                }
            } else {
                ContentUnavailableView(
                    "No Repository",
                    systemImage: "folder",
                    description: Text("This project has no git repository configured.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { ensureViewModel() }
        .onChange(of: project.id) { _, _ in ensureViewModel() }
    }

    @ViewBuilder
    private func fileTreePanel(vm: FileExplorerViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Explorer")
                    .font(.headline)
                Spacer()
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await vm.loadFileTree() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh file tree")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.rootNodes) { node in
                        fileNodeView(node: node, vm: vm, depth: 0)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func fileNodeView(node: FileNode, vm: FileExplorerViewModel, depth: Int) -> AnyView {
        if node.isDirectory {
            return AnyView(
                DisclosureGroup(isExpanded: Binding(
                    get: { vm.expandedDirectories.contains(node.id) },
                    set: { isExpanded in
                        if isExpanded { vm.expandedDirectories.insert(node.id) }
                        else { vm.expandedDirectories.remove(node.id) }
                    }
                )) {
                    ForEach(node.children) { child in
                        fileNodeView(node: child, vm: vm, depth: depth + 1)
                    }
                } label: {
                    fileLabel(node: node, vm: vm)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if vm.expandedDirectories.contains(node.id) {
                                vm.expandedDirectories.remove(node.id)
                            } else {
                                vm.expandedDirectories.insert(node.id)
                            }
                        }
                }
                .padding(.leading, CGFloat(depth) * 12)
                .padding(.horizontal, 8)
            )
        } else {
            return AnyView(
                fileLabel(node: node, vm: vm)
                    .padding(.leading, CGFloat(depth) * 12 + 20)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await vm.openFile(node) }
                    }
            )
        }
    }

    private func fileLabel(node: FileNode, vm: FileExplorerViewModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(for: node.name))
                .foregroundStyle(node.isDirectory ? .yellow : .secondary)
                .font(.system(size: 12))

            Text(node.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            Spacer()

            if let status = node.gitStatus {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                    .font(.system(size: 10))
            }
        }
        .padding(.vertical, 3)
        .background(
            vm.selectedTab?.filePath == node.path
                ? Color.accentColor.opacity(0.2)
                : Color.clear
        )
    }

    @ViewBuilder
    private func editorPanel(vm: FileExplorerViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !vm.tabs.isEmpty {
                tabBar(vm: vm)
                Divider()

                if vm.selectedTab != nil {
                    CodeEditorView(
                        text: Binding(
                            get: { vm.currentContent },
                            set: {
                                vm.currentContent = $0
                                vm.contentDidChange()
                            }
                        ),
                        filename: vm.currentFilename,
                        annotations: vm.currentAnnotations,
                        onSave: { vm.saveCurrentTab() }
                    )
                    .id(vm.selectedTabId)
                }
            } else {
                ContentUnavailableView(
                    "No File Selected",
                    systemImage: "doc.text",
                    description: Text("Select a file from the tree to view and edit.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func tabBar(vm: FileExplorerViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(vm.tabs) { tab in
                    tabView(tab: tab, vm: vm)
                }
            }
        }
        .background(.white.opacity(0.03))
    }

    private func tabView(tab: EditorTab, vm: FileExplorerViewModel) -> some View {
        let isSelected = vm.selectedTabId == tab.id
        return HStack(spacing: 5) {
            Image(systemName: fileIcon(for: tab.filename))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(tab.filename)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)

            if tab.isDirty {
                Circle()
                    .fill(.white.opacity(0.6))
                    .frame(width: 6, height: 6)
            }

            Button {
                vm.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? .white.opacity(0.08) : .clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            vm.selectTab(tab.id)
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "curlybraces"
        case "json": return "curlybraces.square"
        case "md", "txt": return "doc.text"
        case "yml", "yaml", "toml": return "gearshape"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "html", "css": return "globe"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default: return "doc"
        }
    }
}
