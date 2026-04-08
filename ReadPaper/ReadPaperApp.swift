import SwiftData
import SwiftUI

@main
struct ReadPaperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            Paper.self,
            PaperAttachment.self,
            ReadingState.self,
            Note.self,
            TranslationSegment.self,
            TranslationJob.self,
            ToolInstallState.self,
            AppSettings.self
        ])

        Settings {
            SettingsView()
                .modelContainer(for: [
                    Paper.self,
                    PaperAttachment.self,
                    ReadingState.self,
                    Note.self,
                    TranslationSegment.self,
                    TranslationJob.self,
                    ToolInstallState.self,
                    AppSettings.self
                ])
                .frame(width: 560, height: 440)
        }
    }
}
