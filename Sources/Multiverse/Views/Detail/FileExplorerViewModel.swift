import Foundation

struct FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String  // relative to repo root
    let isDirectory: Bool
    var children: [FileNode]?  // nil = not yet loaded (lazy), [] = loaded but empty
    var gitStatus: ChangeStatus?
    var isGitIgnored: Bool = false

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
        && lhs.children?.count == rhs.children?.count
        && lhs.gitStatus == rhs.gitStatus
        && lhs.isGitIgnored == rhs.isGitIgnored
    }
}

struct LineAnnotations: Equatable {
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

    var visibleNodes: [(node: FileNode, depth: Int)] {
        var result: [(node: FileNode, depth: Int)] = []
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                result.append((node: node, depth: depth))
                if node.isDirectory && expandedDirectories.contains(node.id),
                   let children = node.children {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(rootNodes, depth: 0)
        return result
    }
    var revealTargetNodeId: String?
    var isLoading = false
    var error: String?

    // MARK: - Quick Open State
    var quickOpenVisible = false
    var quickOpenQuery = ""
    var quickOpenSelectedIndex = 0
    @ObservationIgnored var cachedFilePaths: [String] = []

    var quickOpenResults: [QuickOpenResult] {
        if quickOpenQuery.isEmpty {
            // Show recently opened files (most recent first)
            if !tabs.isEmpty {
                return Array(tabs.reversed().prefix(20).map { tab in
                    let dir = directoryPortion(of: tab.filePath)
                    return QuickOpenResult(
                        filePath: tab.filePath,
                        filename: tab.filename,
                        directory: dir,
                        matchedIndices: [],
                        score: 0
                    )
                })
            }
            // No tabs open — show first 20 files
            return Array(cachedFilePaths.prefix(20).map { path in
                let filename = (path as NSString).lastPathComponent
                return QuickOpenResult(
                    filePath: path,
                    filename: filename,
                    directory: directoryPortion(of: path),
                    matchedIndices: [],
                    score: 0
                )
            })
        }

        let query = quickOpenQuery
        var scored: [QuickOpenResult] = []
        for path in cachedFilePaths {
            if let result = fuzzyMatch(query: query, path: path) {
                scored.append(result)
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.filePath.count < b.filePath.count
        }
        return Array(scored.prefix(20))
    }

    func showQuickOpen() {
        quickOpenQuery = ""
        quickOpenSelectedIndex = 0
        quickOpenVisible = true
        if cachedFilePaths.isEmpty {
            Task {
                cachedFilePaths = (try? await gitService.listFiles(in: directory)) ?? []
            }
        }
    }

    func dismissQuickOpen() {
        quickOpenVisible = false
        quickOpenQuery = ""
    }

    func quickOpenConfirmSelection() {
        let results = quickOpenResults
        guard quickOpenSelectedIndex >= 0, quickOpenSelectedIndex < results.count else {
            dismissQuickOpen()
            return
        }
        let selected = results[quickOpenSelectedIndex]
        dismissQuickOpen()
        Task { await openFileByPath(selected.filePath) }
    }

    func quickOpenMoveSelection(by delta: Int) {
        let count = quickOpenResults.count
        guard count > 0 else { return }
        quickOpenSelectedIndex = max(0, min(count - 1, quickOpenSelectedIndex + delta))
    }

    private func directoryPortion(of filePath: String) -> String {
        let components = filePath.split(separator: "/")
        if components.count <= 1 { return "" }
        return components.dropLast().joined(separator: "/")
    }

    @ObservationIgnored private var fileWatchTask: Task<Void, Never>?
    @ObservationIgnored var scrollOffsets: [UUID: CGPoint] = [:]

    var currentScrollOffset: CGPoint {
        guard let id = selectedTabId else { return .zero }
        return scrollOffsets[id] ?? .zero
    }

    func setScrollOffset(_ offset: CGPoint, for tabId: UUID) {
        scrollOffsets[tabId] = offset
    }

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
            try await rebuildTree()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
        startFileWatching()
    }

    private func rebuildTree() async throws {
        let files = try await gitService.listFiles(in: directory)
        cachedFilePaths = files
        let statusMap = try await buildStatusMap()
        rootNodes = buildTree(from: files, statusMap: statusMap, basePath: directory)
    }

    private func startFileWatching() {
        fileWatchTask?.cancel()
        fileWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await self?.refreshOpenFiles()
            }
        }
    }

    private func refreshOpenFiles() async {
        // 1. Check for file list changes (new/deleted files)
        let freshFiles = (try? await gitService.listFiles(in: directory)) ?? []
        if freshFiles != cachedFilePaths {
            // File list changed — full tree rebuild (includes status)
            cachedFilePaths = freshFiles
            let statusMap = (try? await buildStatusMap()) ?? [:]
            rootNodes = buildTree(from: freshFiles, statusMap: statusMap, basePath: directory)
        } else {
            // File list unchanged — lightweight status update only
            if let statusMap = try? await buildStatusMap() {
                rootNodes = applyStatus(statusMap, to: rootNodes)
            }
        }

        // 2. Refresh open tab content and annotations
        for index in tabs.indices {
            let tab = tabs[index]
            guard !tab.isImage, !tab.isDirty else { continue }

            let fullPath = (directory as NSString).appendingPathComponent(tab.filePath)

            // Reload content if changed externally
            if let newContent = try? String(contentsOfFile: fullPath, encoding: .utf8),
               newContent != tab.savedContent {
                tabs[index].tabContent = .text(content: newContent, savedContent: newContent)
            }

            // Refresh diff annotations (a commit changes the diff baseline
            // without changing file content, so always re-check)
            if var rawDiff = try? await gitService.diff(for: tab.filePath, staged: false, in: directory) {
                if rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rawDiff = (try? await gitService.diff(for: tab.filePath, staged: true, in: directory)) ?? ""
                }
                let newAnnotations = parseAnnotations(from: rawDiff)
                if newAnnotations != tabs[index].annotations {
                    tabs[index].annotations = newAnnotations
                }
            }
        }
    }

    private func applyStatus(_ statusMap: [String: ChangeStatus], to nodes: [FileNode]) -> [FileNode] {
        nodes.map { node in
            var updated = node
            if node.isDirectory {
                updated.gitStatus = statusMap.first(where: { $0.key.hasPrefix(node.path + "/") })?.value
                if let children = node.children {
                    updated.children = applyStatus(statusMap, to: children)
                }
            } else {
                updated.gitStatus = statusMap[node.path]
            }
            return updated
        }
    }

    func openFileByPath(_ relativePath: String) async {
        // If already open, just focus it
        if let existing = tabs.first(where: { $0.filePath == relativePath }) {
            selectedTabId = existing.id
            revealFileInTree(relativePath)
            return
        }

        let name = (relativePath as NSString).lastPathComponent
        let node = FileNode(
            id: relativePath,
            name: name,
            path: relativePath,
            isDirectory: false,
            children: [],
            gitStatus: nil,
            isGitIgnored: false
        )
        await openFile(node)
        revealFileInTree(relativePath)
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
        scrollOffsets.removeValue(forKey: tabId)
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
        if let tab = tabs.first(where: { $0.id == tabId }) {
            revealFileInTree(tab.filePath)
        }
    }

    func revealFileInTree(_ filePath: String) {
        let components = filePath.split(separator: "/").map(String.init)
        var accumulated = ""
        for i in 0..<(components.count - 1) {
            accumulated += (accumulated.isEmpty ? "" : "/") + components[i]
            expandedDirectories.insert(accumulated)
        }
        revealTargetNodeId = filePath
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
        guard !tabs[index].isImage, tabs[index].isDirty else { return }
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

    private func buildTree(from files: [String], statusMap: [String: ChangeStatus], prefix: String = "", basePath: String) -> [FileNode] {
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
        var knownEntries = Set<String>()

        // Directories first, sorted
        for dirName in directoryContents.keys.sorted() {
            knownEntries.insert(dirName)
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
                prefix: fullPath + "/",
                basePath: (basePath as NSString).appendingPathComponent(dirName)
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
            knownEntries.insert(fileName)
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

        // Augment with filesystem-only entries (gitignored files/directories)
        let fm = FileManager.default
        if let fsEntries = try? fm.contentsOfDirectory(atPath: basePath) {
            for entry in fsEntries.sorted() where !knownEntries.contains(entry) && entry != ".git" {
                let entryAbsPath = (basePath as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: entryAbsPath, isDirectory: &isDir)
                let fullPath = prefix + entry
                nodes.append(FileNode(
                    id: fullPath,
                    name: entry,
                    path: fullPath,
                    isDirectory: isDir.boolValue,
                    children: isDir.boolValue ? nil : [],
                    gitStatus: nil,
                    isGitIgnored: true
                ))
            }
        }

        // Sort: directories first, then alphabetical
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Lazy Loading for Gitignored Directories

    func loadChildren(for node: FileNode) {
        guard node.isDirectory, node.children == nil else { return }

        let fm = FileManager.default
        let fullDirPath = (directory as NSString).appendingPathComponent(node.path)

        guard let entries = try? fm.contentsOfDirectory(atPath: fullDirPath) else {
            rootNodes = setNodeChildren(path: node.path, children: [], in: rootNodes)
            return
        }

        var children: [FileNode] = []
        for entry in entries.sorted() {
            let entryAbsPath = (fullDirPath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entryAbsPath, isDirectory: &isDir)
            let childPath = node.path + "/" + entry
            children.append(FileNode(
                id: childPath,
                name: entry,
                path: childPath,
                isDirectory: isDir.boolValue,
                children: isDir.boolValue ? nil : [],
                gitStatus: nil,
                isGitIgnored: true
            ))
        }

        // Sort: directories first, then alphabetical
        children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        rootNodes = setNodeChildren(path: node.path, children: children, in: rootNodes)
    }

    private func setNodeChildren(path: String, children: [FileNode], in nodes: [FileNode]) -> [FileNode] {
        var result = nodes
        for i in result.indices {
            if result[i].path == path {
                result[i].children = children
                return result
            }
            if result[i].isDirectory, let sub = result[i].children {
                result[i].children = setNodeChildren(path: path, children: children, in: sub)
            }
        }
        return result
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
