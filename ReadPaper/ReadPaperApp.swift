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

        WindowGroup(id: MainWindowScene.id) {
            ContentView()
                .environment(\.localizationBundle, bundle)
                .environment(\.pdfDisplayAppearance, displayAppearance)
                .preferredColorScheme(.light)
                .onChange(of: systemAppearance.readerAppearance, initial: true) {
                    _, appearance in
                    synchronizeAppearancePreference(with: appearance)
                }
        }
        .defaultSize(
            width: MainWindowMetrics.defaultWidth,
            height: MainWindowMetrics.defaultHeight
        )
        .windowResizability(.contentMinSize)
        .modelContainer(sharedModelContainer)
        .commands {
            AboutFreddieCommands()
            LibraryFolderCommands()
            WritingCommands()
        }

        Window(Text("Writing", bundle: bundle), id: WritingWindowScene.id) {
            WritingWindowView()
                .environment(\.localizationBundle, bundle)
                .environment(\.pdfDisplayAppearance, displayAppearance)
                .preferredColorScheme(.light)
        }
        .defaultSize(
            width: WritingWindowScene.defaultWidth,
            height: WritingWindowScene.defaultHeight
        )
        .windowResizability(.contentMinSize)

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

private struct LibraryFolderCommands: Commands {
    @FocusedValue(\.newLibraryFolderAction) private var newFolderAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(String(localized: "New Folder…", bundle: LanguageManager.shared.bundle)) {
                newFolderAction?.perform()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(newFolderAction == nil)
        }
    }
}

private struct WritingCommands: Commands {
    @FocusedValue(\.newWritingAction) private var newWritingAction
    @FocusedValue(\.quoteInWritingAction) private var quoteInWritingAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(String(localized: "New Writing", bundle: LanguageManager.shared.bundle)) {
                newWritingAction?.perform()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(newWritingAction == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(String(localized: "Quote in Writing", bundle: LanguageManager.shared.bundle)) {
                quoteInWritingAction?.perform()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(quoteInWritingAction == nil)
        }
    }
}

private final class ReadPaperApplicationDelegate: NSObject, NSApplicationDelegate {
    /// `readpaper://` links, e.g. citations clicked in a writing opened in another Markdown
    /// app, are taken before SwiftUI sees them: SwiftUI would open a new window for each
    /// link, and a second one when a link launches the app. `PaperLinkRouter` picks the window.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @MainActor @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else {
            return
        }
        PaperLinkRouter.shared.open(url)
    }

    func applicationWillTerminate(_ notification: Notification) {
        WritingDocumentCenter.shared.saveAll()
    }

    func applicationDidResignActive(_ notification: Notification) {
        WritingDocumentCenter.shared.saveAll()
    }

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

enum MainWindowScene {
    static let id = "main"
}

enum MainWindowMetrics {
    static let defaultWidth: CGFloat = 1220
    static let defaultHeight: CGFloat = 780
    static let minWidth: CGFloat = 1040
    static let minHeight: CGFloat = 640
}
