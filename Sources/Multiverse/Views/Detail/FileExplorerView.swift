import AppKit
import SwiftUI

struct FileExplorerView: View {
    let project: Project
    @Environment(AppState.self) private var appState
    @State private var viewModel: FileExplorerViewModel?
    @State private var treeWidth: CGFloat = 0
    @State private var treeHeight: CGFloat = 0

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
        if let vm = viewModel, let pending = appState.consumePendingOpenFile(for: projectId) {
            Task { await vm.openFileByPath(pending) }
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
        .onReceive(NotificationCenter.default.publisher(for: .openFileInExplorer)) { notification in
            guard let path = notification.userInfo?["path"] as? String,
                  let targetId = notification.userInfo?["projectId"] as? String,
                  targetId == project.id.uuidString,
                  let vm = viewModel else { return }
            Task { await vm.openFileByPath(path) }
        }
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

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.rootNodes) { node in
                            fileNodeView(node: node, vm: vm, depth: 0)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(minWidth: treeWidth, minHeight: treeHeight, alignment: .topLeading)
                }
                .onGeometryChange(for: CGSize.self) { geo in
                    geo.size
                } action: { newSize in
                    treeWidth = newSize.width
                    treeHeight = newSize.height
                }
                .onChange(of: vm.revealTargetNodeId) { _, targetId in
                    if let targetId {
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(targetId, anchor: .center)
                            }
                            vm.revealTargetNodeId = nil
                        }
                    }
                }
            }
        }
    }

    private func fileNodeView(node: FileNode, vm: FileExplorerViewModel, depth: Int) -> AnyView {
        let isExpanded = node.isDirectory && vm.expandedDirectories.contains(node.id)

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2) {
                    Group {
                        if node.isDirectory {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 12)

                    fileLabel(node: node, vm: vm)
                }
                .padding(.leading, CGFloat(depth) * 8)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    if node.isDirectory {
                        if vm.expandedDirectories.contains(node.id) {
                            vm.expandedDirectories.remove(node.id)
                        } else {
                            vm.expandedDirectories.insert(node.id)
                        }
                    } else {
                        Task { await vm.openFile(node) }
                    }
                }
                .id(node.id)

                if isExpanded {
                    ForEach(node.children) { child in
                        fileNodeView(node: child, vm: vm, depth: depth + 1)
                    }
                }
            }
        )
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
                breadcrumbBar(vm: vm)
                Divider()

                if vm.selectedTab != nil {
                    if vm.currentTabIsImage, let imagePath = vm.currentImagePath {
                        imageViewer(path: imagePath)
                            .id(vm.selectedTabId)
                    } else {
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
    private func breadcrumbBar(vm: FileExplorerViewModel) -> some View {
        if let tab = vm.selectedTab,
           let label = vm.tabDisplayLabels[tab.id],
           label != tab.filename {
            let segments = tab.filePath.split(separator: "/").map(String.init)
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Text(segment)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.white.opacity(0.03))
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

            Text(vm.tabDisplayLabels[tab.id] ?? tab.filename)
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

    @ViewBuilder
    private func imageViewer(path: String) -> some View {
        if let nsImage = NSImage(contentsOfFile: path) {
            ImageViewerContent(nsImage: nsImage)
        } else {
            ContentUnavailableView(
                "Cannot Display Image",
                systemImage: "photo",
                description: Text("The image file could not be loaded.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Image Viewer with Zoom

private struct ImageViewerContent: View {
    let nsImage: NSImage

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 0.1
    private let maxScale: CGFloat = 10.0

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) { resetZoom() }
                .overlay {
                    ZoomGestureView { factor, anchor in
                        zoomAround(factor: factor, anchor: anchor, viewSize: geo.size)
                    }
                }
        }
        .padding(20)
    }

    private func zoomAround(factor: CGFloat, anchor: CGPoint, viewSize: CGSize) {
        let newScale = clampScale(scale * factor)
        let actualFactor = newScale / scale
        let cx = anchor.x - viewSize.width / 2
        let cy = anchor.y - viewSize.height / 2
        offset = CGSize(
            width: offset.width * actualFactor + cx * (1 - actualFactor),
            height: offset.height * actualFactor + cy * (1 - actualFactor)
        )
        lastOffset = offset
        scale = newScale
    }

    private func clampScale(_ value: CGFloat) -> CGFloat {
        min(maxScale, max(minScale, value))
    }

    private func resetZoom() {
        scale = 1.0
        offset = .zero
        lastOffset = .zero
    }
}

private struct ZoomGestureView: NSViewRepresentable {
    var onZoom: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> ZoomGestureNSView {
        let view = ZoomGestureNSView()
        view.onZoom = onZoom
        let magnify = NSMagnificationGestureRecognizer(
            target: view, action: #selector(view.handleMagnify(_:))
        )
        view.addGestureRecognizer(magnify)
        return view
    }

    func updateNSView(_ nsView: ZoomGestureNSView, context: Context) {
        nsView.onZoom = onZoom
    }

    class ZoomGestureNSView: NSView {
        var onZoom: ((CGFloat, CGPoint) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let swiftUIPoint = CGPoint(x: loc.x, y: bounds.height - loc.y)
            let factor = 1.0 + (event.scrollingDeltaY * 0.03)
            onZoom?(factor, swiftUIPoint)
        }

        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            let loc = gesture.location(in: self)
            let swiftUIPoint = CGPoint(x: loc.x, y: bounds.height - loc.y)
            let factor = 1.0 + gesture.magnification
            gesture.magnification = 0
            onZoom?(factor, swiftUIPoint)
        }
    }
}
