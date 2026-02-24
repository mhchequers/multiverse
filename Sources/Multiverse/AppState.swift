import Foundation

@Observable
@MainActor
final class AppState {
    var selectedProject: Project?
    var isCreatingProject = false
    var searchText = ""
    var statusFilter: Project.ProjectStatus = .inProgress

    let gitService = GitService()

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
    }
}
