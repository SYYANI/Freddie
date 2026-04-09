import SwiftData
import SwiftUI

@main
struct ReadPaperApp: App {
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
            ContentView()
        }
        .modelContainer(sharedModelContainer)

        Settings {
            SettingsView()
                .modelContainer(sharedModelContainer)
                .frame(width: 920, height: 720)
        }
    }
}

enum ReadPaperModelStore {
    static let storeFilename = "ReadPaper.store"
    static let schema = Schema([
        Paper.self,
        PaperAttachment.self,
        ReadingState.self,
        Note.self,
        TranslationSegment.self,
        TranslationJob.self,
        ToolInstallState.self,
        LLMProviderProfile.self,
        LLMModelProfile.self,
        AppSettings.self
    ])

    static func makeModelContainer(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) throws -> ModelContainer {
        let storeURL = try storeURL(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )

        let configuration = ModelConfiguration("ReadPaper", schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func storeURL(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) throws -> URL {
        let fileStore = PaperFileStore(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )
        let rootDirectory = try fileStore.applicationSupportDirectory
        try fileStore.ensureDirectory(rootDirectory)
        return rootDirectory.appendingPathComponent(storeFilename, isDirectory: false)
    }
}
