import Foundation
import SwiftData

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
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: true
        )
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
