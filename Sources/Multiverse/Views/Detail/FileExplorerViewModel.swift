import Foundation

struct FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String  // relative to repo root
    let isDirectory: Bool
    var children: [FileNode]
    var gitStatus: ChangeStatus?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }
}

struct LineAnnotations {
    var added: Set<Int> = []
    var modified: Set<Int> = []
    var deleted: Set<Int> = []  // line numbers AFTER which deletions occurred (0 = before line 1)
}

private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp", "svg", "ico", "heic"]

func isImageFile(_ filename: String) -> Bool {
    let ext = (filename as NSString).pathExtension.lowercased()
    return imageExtensions.contains(ext)
}

enum TabContent: Equatable {
    case text(content: String, savedContent: String)
    case image(fullPath: String)
}

struct EditorTab: Identifiable, Equatable {
    let id: UUID = UUID()
    let filePath: String      // relative path (matches FileNode.path)
    let filename: String      // display name (matches FileNode.name)
    var tabContent: TabContent
    var annotations: LineAnnotations

    var isDirty: Bool {
        if case .text(let content, let savedContent) = tabContent { return content != savedContent }
        return false
    }

    var isImage: Bool {
        if case .image = tabContent { return true }
        return false
    }

    // Backward-compatible computed properties
    var content: String {
        get { if case .text(let c, _) = tabContent { return c } else { return "" } }
        set { if case .text(_, let s) = tabContent { tabContent = .text(content: newValue, savedContent: s) } }
    }

    var savedContent: String {
        get { if case .text(_, let s) = tabContent { return s } else { return "" } }
        set { if case .text(let c, _) = tabContent { tabContent = .text(content: c, savedContent: newValue) } }
    }

    init(node: FileNode, content: String, annotations: LineAnnotations) {
        self.filePath = node.path
        self.filename = node.name
        self.tabContent = .text(content: content, savedContent: content)
        self.annotations = annotations
    }

    init(node: FileNode, imagePath: String) {
        self.filePath = node.path
        self.filename = node.name
        self.tabContent = .image(fullPath: imagePath)
        self.annotations = LineAnnotations()
    }

    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool {
        lhs.id == rhs.id
    }
}

@Observable
@MainActor
final class FileExplorerViewModel {
    var rootNodes: [FileNode] = []
    var tabs: [EditorTab] = []
    var selectedTabId: UUID?
    var expandedDirectories: Set<String> = []
    var isLoading = false
    var error: String?

    var selectedTab: EditorTab? {
        guard let id = selectedTabId else { return nil }
        return tabs.first { $0.id == id }
    }

    private var selectedTabIndex: Int? {
        guard let id = selectedTabId else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    // Convenience properties for view bindings
    var currentContent: String {
        get { selectedTab?.content ?? "" }
        set {
            guard let index = selectedTabIndex else { return }
            tabs[index].content = newValue
        }
    }

    var currentAnnotations: LineAnnotations {
        selectedTab?.annotations ?? LineAnnotations()
    }

    var currentFilename: String {
        selectedTab?.filename ?? ""
    }

    var currentImagePath: String? {
        guard let tab = selectedTab, case .image(let path) = tab.tabContent else { return nil }
        return path
    }

    var currentTabIsImage: Bool {
        selectedTab?.isImage ?? false
    }

    var tabDisplayLabels: [UUID: String] {
        let grouped = Dictionary(grouping: tabs) { $0.filename }
        var labels: [UUID: String] = [:]
        for (filename, group) in grouped {
            if group.count == 1 {
                labels[group[0].id] = filename
            } else {
                let paths = group.map { $0.filePath.split(separator: "/").map(String.init) }
                let maxDepth = paths.map(\.count).max() ?? 1
                var depth = 2
                while depth <= maxDepth {
                    let suffixes = paths.map { segments in
                        segments.suffix(depth).joined(separator: "/")
                    }
                    if Set(suffixes).count == suffixes.count || depth == maxDepth {
                        for (i, tab) in group.enumerated() {
                            labels[tab.id] = suffixes[i]
                        }
                        break
                    }
                    depth += 1
                }
            }
        }
        return labels
    }

    private let gitService: GitService
    private let directory: String
    private let runner = ProcessRunner.shared
    private var saveTask: Task<Void, Never>?
    private var isLoadingFile = false

    init(gitService: GitService, directory: String) {
        self.gitService = gitService
        self.directory = directory
    }

    func loadFileTree() async {
        isLoading = true
        error = nil
        do {
            let files = try await gitService.listFiles(in: directory)
            let statusMap = try await buildStatusMap()
            rootNodes = buildTree(from: files, statusMap: statusMap)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func openFileByPath(_ relativePath: String) async {
        // If already open, just focus it
        if let existing = tabs.first(where: { $0.filePath == relativePath }) {
            selectedTabId = existing.id
            return
        }

        let name = (relativePath as NSString).lastPathComponent
        let node = FileNode(
            id: relativePath,
            name: name,
            path: relativePath,
            isDirectory: false,
            children: [],
            gitStatus: nil
        )
        await openFile(node)
    }

    func openFile(_ node: FileNode) async {
        guard !node.isDirectory else { return }

        // If already open, just focus that tab
        if let existing = tabs.first(where: { $0.filePath == node.path }) {
            selectedTabId = existing.id
            return
        }

        // Save pending changes on current tab
        saveTask?.cancel()
        if selectedTabIndex != nil { saveCurrentTab() }

        let fullPath = (directory as NSString).appendingPathComponent(node.path)

        if isImageFile(node.name) {
            let tab = EditorTab(node: node, imagePath: fullPath)
            tabs.append(tab)
            selectedTabId = tab.id
            return
        }

        isLoadingFile = true
        do {
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            var rawDiff = try await gitService.diff(for: node.path, staged: false, in: directory)
            if rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawDiff = try await gitService.diff(for: node.path, staged: true, in: directory)
            }
            let annotations = parseAnnotations(from: rawDiff)
            let tab = EditorTab(node: node, content: content, annotations: annotations)
            tabs.append(tab)
            selectedTabId = tab.id
        } catch {
            self.error = "Error loading file: \(error.localizedDescription)"
        }
        isLoadingFile = false
    }

    func closeTab(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if tabs[index].isDirty { saveTab(at: index) }
        let wasSelected = selectedTabId == tabId
        tabs.remove(at: index)
        if wasSelected {
            selectedTabId = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func selectTab(_ tabId: UUID) {
        guard tabId != selectedTabId else { return }
        saveTask?.cancel()
        selectedTabId = tabId
    }

    func contentDidChange() {
        guard !isLoadingFile else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveCurrentTab()
        }
    }

    func saveCurrentTab() {
        guard let index = selectedTabIndex else { return }
        saveTab(at: index)
    }

    private func saveTab(at index: Int) {
        guard !tabs[index].isImage else { return }
        let tab = tabs[index]
        let fullPath = (directory as NSString).appendingPathComponent(tab.filePath)
        do {
            try tab.content.write(toFile: fullPath, atomically: true, encoding: .utf8)
            tabs[index].savedContent = tab.content
            let savedPath = tab.filePath
            let tabId = tab.id
            Task {
                var rawDiff = try await gitService.diff(for: savedPath, staged: false, in: directory)
                if rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rawDiff = try await gitService.diff(for: savedPath, staged: true, in: directory)
                }
                if let idx = tabs.firstIndex(where: { $0.id == tabId }) {
                    tabs[idx].annotations = parseAnnotations(from: rawDiff)
                }
            }
        } catch {
            self.error = "Failed to save: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func buildStatusMap() async throws -> [String: ChangeStatus] {
        let changes = try await gitService.status(in: directory)
        var map: [String: ChangeStatus] = [:]
        for change in changes {
            map[change.path] = change.status
        }
        return map
    }

    private func buildTree(from files: [String], statusMap: [String: ChangeStatus], prefix: String = "") -> [FileNode] {
        // Group files by top-level directory/file
        var directoryContents: [String: [String]] = [:]  // dir -> remaining paths
        var topLevelFiles: [String] = []

        for file in files {
            let components = file.split(separator: "/", maxSplits: 1).map(String.init)
            if components.count == 1 {
                topLevelFiles.append(file)
            } else {
                directoryContents[components[0], default: []].append(components[1])
            }
        }

        var nodes: [FileNode] = []

        // Directories first, sorted
        for dirName in directoryContents.keys.sorted() {
            let fullPath = prefix + dirName

            // Determine if directory has any changed files
            let dirStatus = statusMap.first(where: { $0.key.hasPrefix(dirName + "/") })?.value

            let children = buildTree(
                from: directoryContents[dirName]!,
                statusMap: statusMap.reduce(into: [:]) { result, pair in
                    if pair.key.hasPrefix(dirName + "/") {
                        let remaining = String(pair.key.dropFirst(dirName.count + 1))
                        result[remaining] = pair.value
                    }
                },
                prefix: fullPath + "/"
            )

            nodes.append(FileNode(
                id: fullPath,
                name: dirName,
                path: fullPath,
                isDirectory: true,
                children: children,
                gitStatus: dirStatus
            ))
        }

        // Then files, sorted
        for fileName in topLevelFiles.sorted() {
            let fullPath = prefix + fileName
            nodes.append(FileNode(
                id: fullPath,
                name: fileName,
                path: fullPath,
                isDirectory: false,
                children: [],
                gitStatus: statusMap[fileName]
            ))
        }

        return nodes
    }

    // MARK: - Diff Parsing (reused from GitChangesViewModel)

    func parseAnnotations(from rawDiff: String) -> LineAnnotations {
        var annotations = LineAnnotations()
        let lines = rawDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var i = 0
        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("@@") {
                guard let newStart = parseNewStart(from: line) else {
                    i += 1
                    continue
                }

                i += 1
                var newLine = newStart

                while i < lines.count && !lines[i].hasPrefix("@@") && !lines[i].hasPrefix("diff ") {
                    let hunkLine = lines[i]
                    if hunkLine.hasPrefix("-") && !hunkLine.hasPrefix("---") {
                        var removeCount = 0
                        while i < lines.count {
                            let l = lines[i]
                            if l.hasPrefix("-") && !l.hasPrefix("---") {
                                removeCount += 1
                                i += 1
                            } else {
                                break
                            }
                        }
                        var addCount = 0
                        while i < lines.count {
                            let l = lines[i]
                            if l.hasPrefix("+") && !l.hasPrefix("+++") {
                                addCount += 1
                                i += 1
                            } else {
                                break
                            }
                        }
                        let modifiedCount = min(removeCount, addCount)
                        for j in 0..<modifiedCount {
                            annotations.modified.insert(newLine + j)
                        }
                        for j in modifiedCount..<addCount {
                            annotations.added.insert(newLine + j)
                        }
                        // Track pure deletions (excess removes with no matching adds)
                        if removeCount > addCount {
                            annotations.deleted.insert(max(0, newLine + addCount - 1))
                        }
                        newLine += addCount
                    } else if hunkLine.hasPrefix("+") && !hunkLine.hasPrefix("+++") {
                        annotations.added.insert(newLine)
                        newLine += 1
                        i += 1
                    } else if hunkLine.hasPrefix("diff ") || hunkLine.hasPrefix("index ") || hunkLine.hasPrefix("---") || hunkLine.hasPrefix("+++") {
                        i += 1
                    } else {
                        newLine += 1
                        i += 1
                    }
                }
            } else {
                i += 1
            }
        }
        return annotations
    }

    private func parseNewStart(from header: String) -> Int? {
        guard let plusIndex = header.firstIndex(of: "+") else { return nil }
        let afterPlus = header[header.index(after: plusIndex)...]
        let numStr: String
        if let commaIndex = afterPlus.firstIndex(of: ",") {
            numStr = String(afterPlus[..<commaIndex])
        } else if let spaceIndex = afterPlus.firstIndex(of: " ") {
            numStr = String(afterPlus[..<spaceIndex])
        } else {
            numStr = String(afterPlus)
        }
        return Int(numStr)
    }
}
