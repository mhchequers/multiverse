import Foundation

@Observable
@MainActor
final class AppState {
    var selectedProject: Project?
    var isCreatingProject = false
    var searchText = ""
    var statusFilter: Project.ProjectStatus = .inProgress

    let gitService = GitService()
    @ObservationIgnored lazy var commitWatcher = CommitWatcher(gitService: gitService)

    // MARK: - Terminal Lifecycle

    private var terminalRefs: [ObjectIdentifier: MonitoredTerminalView] = [:]

    func registerTerminal(_ terminal: MonitoredTerminalView) {
        let id = ObjectIdentifier(terminal)
        terminalRefs[id] = terminal
    }

    func unregisterTerminal(_ terminal: MonitoredTerminalView) {
        let id = ObjectIdentifier(terminal)
        terminalRefs.removeValue(forKey: id)
    }

    func terminateAllProcesses() {
        for (_, terminal) in terminalRefs {
            if terminal.isProcessRunning {
                terminal.terminateProcessGroup()
            }
        }
        terminalRefs.removeAll()

        for (_, session) in terminalSessionCache {
            for (_, terminal) in session.terminalViews {
                if terminal.isProcessRunning {
                    terminal.terminateProcessGroup()
                }
            }
        }
        terminalSessionCache.removeAll()
    }

    // MARK: - Terminal Session Cache

    struct CachedTerminalSession {
        var tabs: [TerminalTab]
        var selectedTabId: UUID?
        var terminalViews: [UUID: MonitoredTerminalView]
        var workingDirectory: String
    }

    private var terminalSessionCache: [String: CachedTerminalSession] = [:]
    private var deletedProjectIds: Set<String> = []

    func cacheTerminalSession(projectId: String, tabs: [TerminalTab], selectedTabId: UUID?,
                              terminalViews: [UUID: MonitoredTerminalView], workingDirectory: String) {
        guard !deletedProjectIds.contains(projectId) else {
            for (_, terminal) in terminalViews {
                if terminal.isProcessRunning { terminal.terminateProcessGroup() }
                unregisterTerminal(terminal)
            }
            return
        }
        terminalSessionCache[projectId] = CachedTerminalSession(
            tabs: tabs, selectedTabId: selectedTabId,
            terminalViews: terminalViews, workingDirectory: workingDirectory
        )
    }

    func restoreTerminalSession(projectId: String) -> CachedTerminalSession? {
        terminalSessionCache.removeValue(forKey: projectId)
    }

    func clearTerminalSession(projectId: String) {
        if let session = terminalSessionCache.removeValue(forKey: projectId) {
            for (_, terminal) in session.terminalViews {
                if terminal.isProcessRunning { terminal.terminateProcessGroup() }
                unregisterTerminal(terminal)
            }
        }
    }

    func markProjectDeleted(_ projectId: String) {
        deletedProjectIds.insert(projectId)
        clearTerminalSession(projectId: projectId)
        fileExplorerCache.removeValue(forKey: projectId)
    }

    // MARK: - File Explorer Cache

    private var fileExplorerCache: [String: FileExplorerViewModel] = [:]

    func fileExplorerVM(for projectId: String) -> FileExplorerViewModel? {
        fileExplorerCache[projectId]
    }

    func cacheFileExplorerVM(_ vm: FileExplorerViewModel, for projectId: String) {
        guard !deletedProjectIds.contains(projectId) else { return }
        fileExplorerCache[projectId] = vm
    }
}
