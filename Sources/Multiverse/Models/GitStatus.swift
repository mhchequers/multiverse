import Foundation
import SwiftUI

enum ChangeArea: String {
    case staged
    case unstaged
}

enum ChangeStatus: String {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"

    var label: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        }
    }

    var icon: String {
        switch self {
        case .added: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        case .copied: "doc.on.doc.fill"
        case .untracked: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .added, .untracked: .green
        case .modified, .renamed, .copied: .orange
        case .deleted: .red
        }
    }
}

struct FileChange: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let status: ChangeStatus
    let area: ChangeArea

    var filename: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    static func == (lhs: FileChange, rhs: FileChange) -> Bool {
        lhs.path == rhs.path && lhs.area == rhs.area
    }

    static func parse(porcelainOutput: String) -> [FileChange] {
        var changes: [FileChange] = []
        for line in porcelainOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count >= 4 else { continue }
            let indexChar = line[line.startIndex]
            let workChar = line[line.index(after: line.startIndex)]
            let rawPath = String(line.dropFirst(3))
            let displayPath = rawPath.contains(" -> ")
                ? String(rawPath.split(separator: " -> ").last ?? Substring(rawPath))
                : rawPath

            // Skip directory entries (nested git repos) — matches VS Code behavior
            guard !displayPath.hasSuffix("/") else { continue }

            // Staged change (index column)
            if indexChar != " " && indexChar != "?" {
                if let status = ChangeStatus(rawValue: String(indexChar)) {
                    changes.append(FileChange(path: displayPath, status: status, area: .staged))
                }
            }

            // Unstaged change (worktree column)
            if workChar != " " {
                if workChar == "?" {
                    changes.append(FileChange(path: displayPath, status: .untracked, area: .unstaged))
                } else if let status = ChangeStatus(rawValue: String(workChar)) {
                    changes.append(FileChange(path: displayPath, status: status, area: .unstaged))
                }
            }
        }
        return changes
    }
}

struct DiffLine: Identifiable {
    let id = UUID()
    let content: String
    let type: LineType
    let lineNumber: Int?
    var highlightedContent: AttributedString?

    enum LineType {
        case unchanged
        case added     // green gutter — new line not in old file
        case modified  // blue gutter — line that replaced an old line
        case deleted   // red gutter — line removed from old file
    }
}

// MARK: - Side-by-side diff

enum SideLineType {
    case unchanged
    case added
    case removed
    case modified
    case spacer
}

struct SideLine {
    let lineNumber: Int?
    let content: String
    let type: SideLineType
    var highlightedContent: AttributedString?
}

struct SideBySideLine: Identifiable {
    let id = UUID()
    let left: SideLine
    let right: SideLine
}
