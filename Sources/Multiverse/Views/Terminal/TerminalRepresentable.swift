import SwiftUI
import SwiftTerm

/// Terminal.app-inspired ANSI palette with a brighter "bright black" (index 8)
/// so dim text is readable against our dark background.
nonisolated(unsafe) private let terminalPalette: [SwiftTerm.Color] = {
    func c(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }
    return [
        c( 40,  42,  42),   // 0  black (raised from 0 for visibility against near-black bg)
        c(194,  54,  33),   // 1  red
        c( 37, 188,  36),   // 2  green
        c(173, 173,  39),   // 3  yellow
        c( 73,  46, 225),   // 4  blue
        c(211,  56, 211),   // 5  magenta
        c( 51, 187, 200),   // 6  cyan
        c(203, 204, 205),   // 7  white
        c(180, 182, 182),   // 8  bright black  (bright enough that 50% dim is still readable)
        c(252,  57,  31),   // 9  bright red
        c( 49, 231,  34),   // 10 bright green
        c(234, 236,  35),   // 11 bright yellow
        c( 88,  51, 255),   // 12 bright blue
        c(249,  53, 248),   // 13 bright magenta
        c( 20, 240, 240),   // 14 bright cyan
        c(233, 235, 235),   // 15 bright white
    ]
}()

struct TerminalRepresentable: NSViewRepresentable {
    let workingDirectory: String
    let initialCommand: String?
    @Binding var terminalView: MonitoredTerminalView?

    init(workingDirectory: String, initialCommand: String? = nil, terminalView: Binding<MonitoredTerminalView?>) {
        self.workingDirectory = workingDirectory
        self.initialCommand = initialCommand
        self._terminalView = terminalView
    }

    func makeNSView(context: Context) -> MonitoredTerminalView {
        let terminal = MonitoredTerminalView(frame: .zero)

        terminal.nativeForegroundColor = .white
        terminal.nativeBackgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.getTerminal().changeHistorySize(5_000)

        // Custom palette with brighter "bright black" (index 8) for visibility on dark bg
        terminal.installColors(terminalPalette)


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

        if let cmd = initialCommand {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                terminal.send(txt: cmd + "\n")
            }
        }

        DispatchQueue.main.async {
            self.terminalView = terminal
        }

        return terminal
    }

    func updateNSView(_ nsView: MonitoredTerminalView, context: Context) {}
}
