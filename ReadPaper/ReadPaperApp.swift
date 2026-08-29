import AppKit
import SwiftData
import SwiftUI

@main
struct ReadPaperApp: App {
    @NSApplicationDelegateAdaptor(ReadPaperApplicationDelegate.self)
    private var applicationDelegate

    private let sharedModelContainer: ModelContainer

    init() {
        do {
            sharedModelContainer = try ReadPaperModelStore.makeModelContainer()
        } catch {
            fatalError("Failed to initialize model container: \(error)")
        }
    }

    var body: some Scene {
        let bundle = LanguageManager.shared.bundle

        WindowGroup {
            ContentView()
                .environment(\.localizationBundle, bundle)
                .frame(
                    minWidth: MainWindowMetrics.minWidth,
                    minHeight: MainWindowMetrics.minHeight
                )
        }
        .defaultSize(
            width: MainWindowMetrics.defaultWidth,
            height: MainWindowMetrics.defaultHeight
        )
        .windowResizability(.contentMinSize)
        .modelContainer(sharedModelContainer)

        Settings {
            SettingsView()
                .environment(\.localizationBundle, bundle)
                .modelContainer(sharedModelContainer)
                .frame(width: 920, height: 720)
        }
    }
}

private final class ReadPaperApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard #unavailable(macOS 26.0) else {
            return
        }

        guard let icon = NSImage(named: "LegacyAppIcon") else {
            return
        }

        NSApplication.shared.applicationIconImage = icon
    }
}

private enum MainWindowMetrics {
    static let defaultWidth: CGFloat = 1220
    static let defaultHeight: CGFloat = 780
    static let minWidth: CGFloat = 1040
    static let minHeight: CGFloat = 640
}
