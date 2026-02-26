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

@Observable
@MainActor
final class FileExplorerViewModel {
    var rootNodes: [FileNode] = []
    var selectedFile: FileNode?
    var fileContent: String = ""
    var annotations: LineAnnotations = LineAnnotations()
    var expandedDirectories: Set<String> = []
    var isLoading = false
    var error: String?

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

    func selectFile(_ node: FileNode) async {
        guard !node.isDirectory else { return }
        // Save any pending changes to the current file before switching
        saveTask?.cancel()
        if selectedFile != nil { saveFile() }

        selectedFile = node
        isLoadingFile = true
        do {
            let fullPath = (directory as NSString).appendingPathComponent(node.path)
            fileContent = try String(contentsOfFile: fullPath, encoding: .utf8)

            // Get git diff annotations
            var rawDiff = try await gitService.diff(for: node.path, staged: false, in: directory)
            if rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawDiff = try await gitService.diff(for: node.path, staged: true, in: directory)
            }
            annotations = parseAnnotations(from: rawDiff)
        } catch {
            fileContent = "Error loading file: \(error.localizedDescription)"
            annotations = LineAnnotations()
        }
        isLoadingFile = false
    }

    func contentDidChange() {
        guard !isLoadingFile else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveFile()
        }
    }

    func saveFile() {
        guard let node = selectedFile else { return }
        let fullPath = (directory as NSString).appendingPathComponent(node.path)
        do {
            try fileContent.write(toFile: fullPath, atomically: true, encoding: .utf8)
            // Re-fetch annotations after save
            let savedPath = node.path
            Task {
                var rawDiff = try await gitService.diff(for: savedPath, staged: false, in: directory)
                if rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rawDiff = try await gitService.diff(for: savedPath, staged: true, in: directory)
                }
                // Only update annotations if we're still viewing this file
                guard selectedFile?.path == savedPath else { return }
                annotations = parseAnnotations(from: rawDiff)
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
