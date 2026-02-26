import Foundation

@Observable
@MainActor
final class GitChangesViewModel {
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
                var lineNum = 1
                diffLines = content.split(separator: "\n", omittingEmptySubsequences: false).map {
                    defer { lineNum += 1 }
                    return DiffLine(content: String($0), type: .added, lineNumber: lineNum)
                }
            } else if file.status == .deleted {
                let rawDiff = try await gitService.diff(for: file.path, staged: file.area == .staged, in: directory)
                diffLines = buildDiffLines(from: rawDiff)
                if diffLines.isEmpty {
                    diffLines = [DiffLine(content: "(file deleted)", type: .deleted, lineNumber: nil)]
                }
            } else {
                let rawDiff = try await gitService.diff(for: file.path, staged: file.area == .staged, in: directory)
                diffLines = buildDiffLines(from: rawDiff)
            }
            applyHighlightingToDiffLines(filename: file.filename)
        } catch {
            diffLines = [DiffLine(content: "Error loading diff: \(error.localizedDescription)", type: .unchanged, lineNumber: nil)]
        }
    }

    /// Build diff lines directly from unified diff output, including deleted lines.
    private func buildDiffLines(from rawDiff: String) -> [DiffLine] {
        let lines = rawDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [DiffLine] = []
        var newLineNum = 1
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("@@") {
                if let (_, newStart) = parseHunkHeader(line) {
                    newLineNum = newStart
                }
                i += 1
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
                i += 1
            } else if line.hasPrefix("-") {
                // Collect consecutive removes
                var removes: [String] = []
                while i < lines.count && lines[i].hasPrefix("-") && !lines[i].hasPrefix("---") {
                    removes.append(String(lines[i].dropFirst()))
                    i += 1
                }
                // Collect consecutive adds
                var adds: [String] = []
                while i < lines.count && lines[i].hasPrefix("+") && !lines[i].hasPrefix("+++") {
                    adds.append(String(lines[i].dropFirst()))
                    i += 1
                }

                let modCount = min(removes.count, adds.count)

                // Emit deleted lines first (paired deletions shown before their replacements)
                for j in 0..<modCount {
                    result.append(DiffLine(content: removes[j], type: .deleted, lineNumber: nil))
                }
                // Extra removes (pure deletions)
                for j in modCount..<removes.count {
                    result.append(DiffLine(content: removes[j], type: .deleted, lineNumber: nil))
                }

                // Then modified lines (replacements for paired deletions)
                for j in 0..<modCount {
                    result.append(DiffLine(content: adds[j], type: .modified, lineNumber: newLineNum))
                    newLineNum += 1
                }
                // Extra adds (pure additions)
                for j in modCount..<adds.count {
                    result.append(DiffLine(content: adds[j], type: .added, lineNumber: newLineNum))
                    newLineNum += 1
                }
            } else if line.hasPrefix("+") {
                result.append(DiffLine(content: String(line.dropFirst()), type: .added, lineNumber: newLineNum))
                newLineNum += 1
                i += 1
            } else {
                // Context line
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                result.append(DiffLine(content: content, type: .unchanged, lineNumber: newLineNum))
                newLineNum += 1
                i += 1
            }
        }
        return result
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
                applyHighlightingToSideBySide(filename: file.filename)
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
            applyHighlightingToSideBySide(filename: file.filename)
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

    // MARK: - Syntax highlighting

    private func applyHighlightingToDiffLines(filename: String) {
        let fullText = diffLines.map(\.content).joined(separator: "\n")
        let highlighted = SyntaxHighlighter.highlightLines(fullText, filename: filename)
        for i in diffLines.indices where i < highlighted.count {
            diffLines[i].highlightedContent = highlighted[i]
        }
    }

    private func applyHighlightingToSideBySide(filename: String) {
        // Reconstruct left and right file text from non-spacer lines
        var leftTexts: [String] = []
        var leftIndices: [Int] = []
        var rightTexts: [String] = []
        var rightIndices: [Int] = []

        for (i, line) in sideBySideLines.enumerated() {
            if line.left.type != .spacer {
                leftTexts.append(line.left.content)
                leftIndices.append(i)
            }
            if line.right.type != .spacer {
                rightTexts.append(line.right.content)
                rightIndices.append(i)
            }
        }

        let leftHighlighted = SyntaxHighlighter.highlightLines(
            leftTexts.joined(separator: "\n"), filename: filename
        )
        let rightHighlighted = SyntaxHighlighter.highlightLines(
            rightTexts.joined(separator: "\n"), filename: filename
        )

        for (idx, lineIndex) in leftIndices.enumerated() where idx < leftHighlighted.count {
            sideBySideLines[lineIndex] = SideBySideLine(
                left: SideLine(
                    lineNumber: sideBySideLines[lineIndex].left.lineNumber,
                    content: sideBySideLines[lineIndex].left.content,
                    type: sideBySideLines[lineIndex].left.type,
                    highlightedContent: leftHighlighted[idx]
                ),
                right: sideBySideLines[lineIndex].right
            )
        }
        for (idx, lineIndex) in rightIndices.enumerated() where idx < rightHighlighted.count {
            sideBySideLines[lineIndex] = SideBySideLine(
                left: sideBySideLines[lineIndex].left,
                right: SideLine(
                    lineNumber: sideBySideLines[lineIndex].right.lineNumber,
                    content: sideBySideLines[lineIndex].right.content,
                    type: sideBySideLines[lineIndex].right.type,
                    highlightedContent: rightHighlighted[idx]
                )
            )
        }
    }
}
