import SwiftUI
import SwiftData
import AppKit

@main
struct MultiverseApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    // When running via `swift run`, macOS doesn't activate
                    // the app as foreground — windows can't receive keyboard input.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()

                    if let resourceURL = Bundle.module.url(forResource: "multiverse", withExtension: "jpg"),
                       let icon = NSImage(contentsOf: resourceURL) {
                        NSApp.applicationIconImage = icon
                    }

                    // Clear cached window frames and set size immediately
                    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame") {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    if let window = NSApp.windows.first,
                       let screen = window.screen ?? NSScreen.main {
                        let visibleFrame = screen.visibleFrame
                        let width: CGFloat = 1600
                        let height: CGFloat = 975
                        let x = visibleFrame.origin.x + (visibleFrame.width - width) / 2
                        let y = visibleFrame.maxY - height
                        let frame = NSRect(x: x, y: y, width: width, height: height)
                        window.setFrame(frame, display: true, animate: false)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.terminateAllProcesses()
                }
        }
        .modelContainer(for: [
            Project.self,
        ])
        .defaultSize(width: 1600, height: 975)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    appState.isCreatingProject = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
