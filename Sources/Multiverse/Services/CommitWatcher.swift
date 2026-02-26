import Foundation
import SwiftData

@MainActor
final class CommitWatcher {
    private let gitService: GitService
    private var pollingTask: Task<Void, Never>?

    init(gitService: GitService) {
        self.gitService = gitService
    }

    func start(modelContext: ModelContext) {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                await self?.checkForNewCommits(modelContext: modelContext)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func checkForNewCommits(modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate<Project> { $0.statusRaw == "in_progress" }
        )
        guard let projects = try? modelContext.fetch(descriptor) else { return }

        for project in projects {
            let directory = project.worktreePath ?? project.repoPath
            guard !directory.isEmpty else { continue }

            do {
                let currentHash = try await gitService.headCommitHash(in: directory)
                guard !currentHash.isEmpty else { continue }

                if project.lastKnownCommitHash.isEmpty {
                    // First time seeing this project — seed the hash without logging
                    project.lastKnownCommitHash = currentHash
                    try? modelContext.save()
                } else if currentHash != project.lastKnownCommitHash {
                    // New commit detected
                    let message = try await gitService.latestCommitMessage(in: directory)
                    logActivity(.commitDetected, detail: message, for: project, in: modelContext)
                    project.lastKnownCommitHash = currentHash
                    try? modelContext.save()
                }
            } catch {
                // Silently skip projects where git commands fail (e.g., deleted repo)
                continue
            }
        }
    }
}
