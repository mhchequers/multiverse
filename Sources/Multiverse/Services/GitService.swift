import Foundation

@Observable
@MainActor
final class GitService {
    static let worktreeBase = NSHomeDirectory() + "/multiverse-worktrees"

    private let runner = ProcessRunner.shared

    struct BranchInfo: Identifiable, Hashable, Sendable {
        let name: String
        let isCurrent: Bool
        var id: String { name }
    }

    // MARK: - Branches

    func listBranches(repoPath: String) async throws -> [BranchInfo] {
        let result = try await runner.git("branch", "--list", "--no-color", in: repoPath)
        guard result.succeeded else { throw GitError.commandFailed(result.stderr) }

        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isCurrent = trimmed.hasPrefix("* ")
                let name = isCurrent ? String(trimmed.dropFirst(2)) : trimmed
                return BranchInfo(name: name, isCurrent: isCurrent)
            }
    }

    // MARK: - Worktrees

    func createWorktree(repoPath: String, branchName: String, baseBranch: String) async throws -> String {
        let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
        let slug = SlugGenerator.generate(from: branchName)
        let worktreePath = "\(Self.worktreeBase)/\(repoName)--\(slug)"

        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.worktreeBase) {
            try fm.createDirectory(atPath: Self.worktreeBase, withIntermediateDirectories: true)
        }

        // Clean up stale worktree directory from a previous failed attempt
        if fm.fileExists(atPath: worktreePath) {
            try fm.removeItem(atPath: worktreePath)
            _ = try? await runner.git("worktree", "prune", in: repoPath)
        }

        // Check if branch already exists
        let branchCheck = try await runner.git("rev-parse", "--verify", branchName, in: repoPath)
        let branchExists = branchCheck.succeeded

        let result: ProcessResult
        if branchExists {
            result = try await runner.git(
                "worktree", "add", worktreePath, branchName,
                in: repoPath
            )
        } else {
            result = try await runner.git(
                "worktree", "add", "-b", branchName, worktreePath, baseBranch,
                in: repoPath
            )
        }

        guard result.succeeded else { throw GitError.commandFailed(result.stderr) }
        return worktreePath
    }

    func removeWorktree(repoPath: String, worktreePath: String) async throws {
        let result = try await runner.git("worktree", "remove", "--force", worktreePath, in: repoPath)
        if !result.succeeded {
            _ = try? await runner.git("worktree", "prune", in: repoPath)
        }
    }

    enum GitError: Error, LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let msg): "Git error: \(msg)"
            }
        }
    }
}
