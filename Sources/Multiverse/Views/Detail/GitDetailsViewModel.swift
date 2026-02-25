import Foundation

@Observable
@MainActor
final class GitDetailsViewModel {
    var fileChanges: [FileChange] = []
    var selectedFile: FileChange?
    var diffLines: [DiffLine] = []
    var sideBySideLines: [SideBySideLine] = []
    var showSideBySide = false
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
        showSideBySide = false
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

    // MARK: - Side-by-side diff

    func doubleClickFile(_ file: FileChange) async {
        selectedFile = file
        showSideBySide = true
        do {
            let rawDiff: String
            if file.status == .untracked {
                let content = try await gitService.showUntrackedFile(file.path, in: directory)
                // All lines are additions
                let fileLines = content.split(separator: "\n", omittingEmptySubsequences: false)
                sideBySideLines = fileLines.enumerated().map { index, line in
                    SideBySideLine(
                        left: SideLine(lineNumber: nil, content: "", type: .spacer),
                        right: SideLine(lineNumber: index + 1, content: String(line), type: .added)
                    )
                }
                return
            } else if file.status == .deleted {
                sideBySideLines = [SideBySideLine(
                    left: SideLine(lineNumber: 1, content: "(file deleted)", type: .removed),
                    right: SideLine(lineNumber: nil, content: "", type: .spacer)
                )]
                return
            }

            rawDiff = try await gitService.diff(for: file.path, staged: file.area == .staged, in: directory)
            sideBySideLines = buildSideBySide(from: rawDiff)
        } catch {
            sideBySideLines = [SideBySideLine(
                left: SideLine(lineNumber: nil, content: "Error: \(error.localizedDescription)", type: .unchanged),
                right: SideLine(lineNumber: nil, content: "", type: .spacer)
            )]
        }
    }

    private func buildSideBySide(from rawDiff: String) -> [SideBySideLine] {
        let diffLines = rawDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [SideBySideLine] = []
        var oldLineNum = 1
        var newLineNum = 1
        var i = 0

        while i < diffLines.count {
            let line = diffLines[i]

            if line.hasPrefix("@@") {
                // Parse hunk header for starting line numbers
                if let (oldStart, newStart) = parseHunkHeader(line) {
                    oldLineNum = oldStart
                    newLineNum = newStart
                }
                i += 1
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
                i += 1
            } else if line.hasPrefix("-") {
                // Collect consecutive removes
                var removes: [String] = []
                while i < diffLines.count && diffLines[i].hasPrefix("-") && !diffLines[i].hasPrefix("---") {
                    removes.append(String(diffLines[i].dropFirst()))
                    i += 1
                }
                // Collect consecutive adds
                var adds: [String] = []
                while i < diffLines.count && diffLines[i].hasPrefix("+") && !diffLines[i].hasPrefix("+++") {
                    adds.append(String(diffLines[i].dropFirst()))
                    i += 1
                }

                let modCount = min(removes.count, adds.count)

                // Paired modifications
                for j in 0..<modCount {
                    result.append(SideBySideLine(
                        left: SideLine(lineNumber: oldLineNum, content: removes[j], type: .modified),
                        right: SideLine(lineNumber: newLineNum, content: adds[j], type: .modified)
                    ))
                    oldLineNum += 1
                    newLineNum += 1
                }
                // Extra removes
                for j in modCount..<removes.count {
                    result.append(SideBySideLine(
                        left: SideLine(lineNumber: oldLineNum, content: removes[j], type: .removed),
                        right: SideLine(lineNumber: nil, content: "", type: .spacer)
                    ))
                    oldLineNum += 1
                }
                // Extra adds
                for j in modCount..<adds.count {
                    result.append(SideBySideLine(
                        left: SideLine(lineNumber: nil, content: "", type: .spacer),
                        right: SideLine(lineNumber: newLineNum, content: adds[j], type: .added)
                    ))
                    newLineNum += 1
                }
            } else if line.hasPrefix("+") {
                result.append(SideBySideLine(
                    left: SideLine(lineNumber: nil, content: "", type: .spacer),
                    right: SideLine(lineNumber: newLineNum, content: String(line.dropFirst()), type: .added)
                ))
                newLineNum += 1
                i += 1
            } else {
                // Context line (starts with space or is plain text)
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                result.append(SideBySideLine(
                    left: SideLine(lineNumber: oldLineNum, content: content, type: .unchanged),
                    right: SideLine(lineNumber: newLineNum, content: content, type: .unchanged)
                ))
                oldLineNum += 1
                newLineNum += 1
                i += 1
            }
        }
        return result
    }

    private func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int)? {
        // @@ -old_start[,count] +new_start[,count] @@
        let parts = header.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let oldPart = String(parts[1]) // -old_start[,count]
        let newPart = String(parts[2]) // +new_start[,count]
        guard oldPart.hasPrefix("-"), newPart.hasPrefix("+") else { return nil }
        let oldNum = Int(oldPart.dropFirst().split(separator: ",").first ?? "")
        let newNum = Int(newPart.dropFirst().split(separator: ",").first ?? "")
        guard let o = oldNum, let n = newNum else { return nil }
        return (o, n)
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
