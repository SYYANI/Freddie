import AppKit
import SwiftData
import SwiftUI

@main
struct ReadPaperApp: App {
    @NSApplicationDelegateAdaptor(ReadPaperApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var systemAppearance = SystemAppearanceMonitor()
    @AppStorage(PDFDisplayAppearance.userDefaultsKey)
    private var displayAppearancePreference = PDFDisplayAppearance.defaultValue.rawValue

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
        let displayAppearance = PDFDisplayAppearance.resolve(
            rawValue: displayAppearancePreference
        )

        WindowGroup {
            ContentView()
                .environment(\.localizationBundle, bundle)
                .environment(\.pdfDisplayAppearance, displayAppearance)
                .preferredColorScheme(.light)
                .onChange(of: systemAppearance.readerAppearance, initial: true) {
                    _, appearance in
                    synchronizeAppearancePreference(with: appearance)
                }
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
        .commands {
            AboutFreddieCommands()
        }

        Window("About Freddie", id: AboutFreddieCommands.windowID) {
            AboutView()
                .environment(\.localizationBundle, bundle)
                .preferredColorScheme(.light)
        }
        .defaultSize(
            width: AboutWindowMetrics.width,
            height: AboutWindowMetrics.height
        )
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(\.localizationBundle, bundle)
                .environment(\.pdfDisplayAppearance, displayAppearance)
                .preferredColorScheme(.light)
                .onChange(of: systemAppearance.readerAppearance, initial: true) {
                    _, appearance in
                    synchronizeAppearancePreference(with: appearance)
                }
                .modelContainer(sharedModelContainer)
                .frame(
                    minWidth: SettingsWindowMetrics.minWidth,
                    idealWidth: SettingsWindowMetrics.defaultWidth,
                    minHeight: SettingsWindowMetrics.minHeight,
                    idealHeight: SettingsWindowMetrics.defaultHeight
                )
        }
        .defaultSize(
            width: SettingsWindowMetrics.defaultWidth,
            height: SettingsWindowMetrics.defaultHeight
        )
        .windowResizability(.contentMinSize)
    }

    private func synchronizeAppearancePreference(with appearance: PDFDisplayAppearance) {
        PDFDisplayAppearance.synchronizeStoredPreference(
            isSystemDarkMode: appearance == .paper
        )
    }
}

private struct AboutFreddieCommands: Commands {
    static let windowID = "about-freddie"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About Freddie", bundle: LanguageManager.shared.bundle)) {
                openWindow(id: Self.windowID)
            }
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
