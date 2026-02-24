import SwiftUI
import SwiftTerm

struct TerminalRepresentable: NSViewRepresentable {
    let workingDirectory: String
    @Binding var terminalView: MonitoredTerminalView?

    func makeNSView(context: Context) -> MonitoredTerminalView {
        let terminal = MonitoredTerminalView(frame: .zero)

        terminal.nativeForegroundColor = .textColor
        terminal.nativeBackgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.getTerminal().changeHistorySize(5_000)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var enriched = ProcessRunner.enrichedEnvironment()
        if enriched["TERM"] == nil {
            enriched["TERM"] = "xterm-256color"
        }
        let env = enriched.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: nil
        )

        terminal.send(txt: "cd \"\(workingDirectory)\" && clear\n")

        DispatchQueue.main.async {
            self.terminalView = terminal
        }

        return terminal
    }

    func updateNSView(_ nsView: MonitoredTerminalView, context: Context) {}
}
