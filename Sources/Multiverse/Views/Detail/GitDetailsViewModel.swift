import Foundation

@Observable
@MainActor
final class GitDetailsViewModel {
    var fileChanges: [FileChange] = []
    var selectedFile: FileChange?
    var diffLines: [DiffLine] = []
    var isLoading = false
    var error: String?

    var stagedChanges: [FileChange] {
        fileChanges.filter { $0.area == .staged }
    }

    var unstagedChanges: [FileChange] {
        fileChanges.filter { $0.area == .unstaged }
    }

    private let gitService: GitService
    private let directory: String

    init(gitService: GitService, directory: String) {
        self.gitService = gitService
        self.directory = directory
    }

    func refresh() async {
        isLoading = true
        error = nil
        do {
            fileChanges = try await gitService.status(in: directory)
            if let selected = selectedFile,
               !fileChanges.contains(where: { $0.path == selected.path && $0.area == selected.area }) {
                selectedFile = nil
                diffLines = []
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func selectFile(_ file: FileChange) async {
        selectedFile = file
        do {
            if file.status == .untracked {
                let content = try await gitService.showUntrackedFile(file.path, in: directory)
                diffLines = content.split(separator: "\n", omittingEmptySubsequences: false).map {
                    DiffLine(content: String($0), type: .added)
                }
            } else if file.status == .deleted {
                diffLines = [DiffLine(content: "(file deleted)", type: .unchanged)]
            } else {
                // Get the file content and the diff
                let content: String
                if file.area == .staged {
                    content = try await gitService.stagedFileContent(for: file.path, in: directory)
                } else {
                    content = try await gitService.showUntrackedFile(file.path, in: directory)
                }
                let rawDiff = try await gitService.diff(for: file.path, staged: file.area == .staged, in: directory)
                let annotations = parseAnnotations(from: rawDiff)
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                diffLines = lines.enumerated().map { index, line in
                    let lineNum = index + 1
                    let type: DiffLine.LineType
                    if annotations.modified.contains(lineNum) {
                        type = .modified
                    } else if annotations.added.contains(lineNum) {
                        type = .added
                    } else {
                        type = .unchanged
                    }
                    return DiffLine(content: String(line), type: type)
                }
            }
        } catch {
            diffLines = [DiffLine(content: "Error loading diff: \(error.localizedDescription)", type: .unchanged)]
        }
    }

    private struct LineAnnotations {
        var added: Set<Int> = []
        var modified: Set<Int> = []
    }

    /// Parse unified diff to determine which lines in the new file are added vs modified.
    private func parseAnnotations(from rawDiff: String) -> LineAnnotations {
        var annotations = LineAnnotations()
        let lines = rawDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Find hunk headers
            if line.hasPrefix("@@") {
                // Parse @@ -old,count +new_start,count @@
                guard let newStart = parseNewStart(from: line) else {
                    i += 1
                    continue
                }

                i += 1
                var newLine = newStart

                // Process lines within this hunk
                while i < lines.count && !lines[i].hasPrefix("@@") && !lines[i].hasPrefix("diff ") {
                    let hunkLine = lines[i]
                    if hunkLine.hasPrefix("-") && !hunkLine.hasPrefix("---") {
                        // Removed line — count consecutive removes, then match with adds
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
                        // Now count consecutive adds
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
                        // First min(removeCount, addCount) are modifications
                        let modifiedCount = min(removeCount, addCount)
                        for j in 0..<modifiedCount {
                            annotations.modified.insert(newLine + j)
                        }
                        // Remaining adds are pure additions
                        for j in modifiedCount..<addCount {
                            annotations.added.insert(newLine + j)
                        }
                        newLine += addCount
                    } else if hunkLine.hasPrefix("+") && !hunkLine.hasPrefix("+++") {
                        annotations.added.insert(newLine)
                        newLine += 1
                        i += 1
                    } else if hunkLine.hasPrefix("diff ") || hunkLine.hasPrefix("index ") || hunkLine.hasPrefix("---") || hunkLine.hasPrefix("+++") {
                        i += 1
                    } else {
                        // Context line
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
        // @@ -old_start[,count] +new_start[,count] @@
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
