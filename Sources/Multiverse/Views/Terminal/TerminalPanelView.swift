import SwiftUI
import SwiftTerm

struct TerminalPanelView: View {
    let workingDirectory: String
    let projectId: String
    @Environment(AppState.self) private var appState
    @State private var tabs: [TerminalTab] = []
    @State private var selectedTabId: UUID?
    @State private var terminalViews: [UUID: MonitoredTerminalView] = [:]

    struct TerminalTab: Identifiable {
        let id = UUID()
        var label: String
        var command: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    Button {
                        selectedTabId = tab.id
                    } label: {
                        HStack(spacing: 4) {
                            Text(tab.label)
                                .font(.caption)
                            if tabs.count > 1 {
                                Button {
                                    closeTab(tab.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8))
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selectedTabId == tab.id ? Color.accentColor.opacity(0.1) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    addTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.bar)

            // Terminal content — ZStack keeps all sessions alive across tab switches
            ZStack {
                ForEach(tabs) { tab in
                    TerminalRepresentable(
                        workingDirectory: workingDirectory,
                        initialCommand: tab.command,
                        terminalView: Binding(
                            get: { terminalViews[tab.id] },
                            set: { newValue in
                                if let old = terminalViews[tab.id] {
                                    appState.unregisterTerminal(old)
                                }
                                terminalViews[tab.id] = newValue
                                if let tv = newValue {
                                    appState.registerTerminal(tv)
                                }
                            }
                        )
                    )
                    .opacity(selectedTabId == tab.id ? 1 : 0)
                    .allowsHitTesting(selectedTabId == tab.id)
                }
            }
        }
        .onAppear {
            if tabs.isEmpty {
                addTab()
            }
        }
        .onDisappear {
            for (id, terminal) in terminalViews {
                if terminal.isProcessRunning {
                    terminal.terminateProcessGroup()
                }
                appState.unregisterTerminal(terminal)
                _ = id
            }
            terminalViews.removeAll()
            tabs.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launchClaude)) { notification in
            guard let targetId = notification.userInfo?["projectId"] as? String,
                  targetId == projectId else { return }
            let command = notification.userInfo?["command"] as? String
            let label = notification.userInfo?["label"] as? String ?? "Claude"
            addTab(label: label, command: command)
        }
    }

    private func addTab(label: String? = nil, command: String? = nil) {
        let number = tabs.count + 1
        let tabLabel = label ?? (number == 1 ? "zsh" : "zsh \(number)")
        let tab = TerminalTab(label: tabLabel, command: command)
        tabs.append(tab)
        selectedTabId = tab.id
    }

    private func closeTab(_ id: UUID) {
        if let terminal = terminalViews[id] {
            if terminal.isProcessRunning {
                terminal.terminateProcessGroup()
            }
            appState.unregisterTerminal(terminal)
        }
        tabs.removeAll { $0.id == id }
        terminalViews.removeValue(forKey: id)
        if selectedTabId == id {
            selectedTabId = tabs.last?.id
        }
    }
}
