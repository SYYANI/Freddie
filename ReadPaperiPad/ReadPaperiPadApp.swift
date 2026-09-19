import SwiftData
import SwiftUI

@main
struct ReadPaperiPadApp: App {
    private let sharedModelContainer: ModelContainer

    init() {
        do {
            sharedModelContainer = try ReadPaperModelStore.makeModelContainer()
        } catch {
            fatalError("Failed to initialize model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            SystemSynchronizedIPadContent()
                .environment(\.localizationBundle, LanguageManager.shared.bundle)
        }
        .modelContainer(sharedModelContainer)
    }
}

private struct SystemSynchronizedIPadContent: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(PDFDisplayAppearance.userDefaultsKey)
    private var displayAppearancePreference = PDFDisplayAppearance.defaultValue.rawValue

    var body: some View {
        IPadContentView()
            .environment(
                \.pdfDisplayAppearance,
                .resolve(rawValue: displayAppearancePreference)
            )
            .environment(\.colorScheme, .light)
            .onAppear {
                synchronizeAppearancePreference()
            }
            .onChange(of: systemColorScheme) { _, _ in
                synchronizeAppearancePreference()
            }
    }

    private func synchronizeAppearancePreference() {
        PDFDisplayAppearance.synchronizeStoredPreference(
            isSystemDarkMode: systemColorScheme == .dark
        )
    }
}
