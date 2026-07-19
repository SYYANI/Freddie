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
            IPadContentView()
                .environment(\.localizationBundle, LanguageManager.shared.bundle)
        }
        .modelContainer(sharedModelContainer)
    }
}
