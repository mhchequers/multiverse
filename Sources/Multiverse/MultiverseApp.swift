import SwiftUI
import SwiftData
import AppKit

@main
struct MultiverseApp: App {
    @State private var appState = AppState()
    let modelContainer: ModelContainer

    init() {
        self.modelContainer = Self.makeModelContainer()
    }

    static func makeModelContainer() -> ModelContainer {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let multiverseDir = appSupport.appending(path: "Multiverse")
        try? FileManager.default.createDirectory(at: multiverseDir, withIntermediateDirectories: true)

        // Back up the database before opening — if the store is ever corrupted,
        // manually replace Multiverse.store with Multiverse.store.backup
        let storeName = "Multiverse.store"
        let storeURL = multiverseDir.appending(path: storeName)
        if FileManager.default.fileExists(atPath: storeURL.path) {
            for suffix in ["", "-shm", "-wal"] {
                let src = multiverseDir.appending(path: "\(storeName)\(suffix)")
                let dst = multiverseDir.appending(path: "\(storeName)\(suffix).backup")
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
            }
        }

        let config = ModelConfiguration(url: storeURL)
        do {
            return try ModelContainer(for: Project.self, ProjectActivity.self, configurations: config)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

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

                    if let resourceURL = Bundle.module.url(forResource: "multiverse", withExtension: "png"),
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
        .modelContainer(modelContainer)
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
