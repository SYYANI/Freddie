import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRows: [AppSettings]

    var body: some View {
        Group {
            if let settings = settingsRows.first {
                SettingsForm(settings: settings)
            } else {
                ProgressView()
                    .onAppear {
                        modelContext.insert(AppSettings())
                        try? modelContext.save()
                    }
            }
        }
        .padding(24)
    }
}

private struct SettingsForm: View {
    @Bindable var settings: AppSettings
    @State private var apiKey = ""
    @State private var statusMessage: String?
    @State private var isInstalling = false

    var body: some View {
        Form {
            Section("OpenAI-compatible API") {
                TextField("Base URL", text: $settings.openAIBaseURL)
                TextField("Quick model", text: $settings.quickModelName)
                TextField("Normal model", text: $settings.normalModelName)
                TextField("Heavy model", text: $settings.heavyModelName)
                SecureField("API key", text: $apiKey)
                Button("Save API key") {
                    saveAPIKey()
                }
            }

            Section("Translation") {
                TextField("Target language", text: $settings.targetLanguage)
                Stepper("HTML concurrency: \(settings.htmlTranslationConcurrency)", value: $settings.htmlTranslationConcurrency, in: 1...12)
                Stepper("BabelDOC QPS: \(settings.babelDocQPS)", value: $settings.babelDocQPS, in: 1...20)
            }

            Section("BabelDOC") {
                TextField("Version", text: $settings.babelDocVersion)
                Button(isInstalling ? "Installing..." : "Install or update BabelDOC") {
                    installBabelDOC()
                }
                .disabled(isInstalling)
            }

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(statusMessage.hasPrefix("Error") ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = (try? KeychainStore().load(account: KeychainStore.openAIAPIKeyAccount)) ?? ""
        }
    }

    private func saveAPIKey() {
        do {
            try KeychainStore().save(apiKey, account: KeychainStore.openAIAPIKeyAccount)
            statusMessage = "API key saved in Keychain."
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func installBabelDOC() {
        isInstalling = true
        statusMessage = "Installing BabelDOC..."
        Task {
            do {
                let result = try await BabelDocToolManager().installOrUpdateBabelDOC(version: settings.babelDocVersion)
                if result.exitCode == 0 {
                    statusMessage = "BabelDOC is ready."
                } else {
                    statusMessage = "Error: \(result.combinedOutput)"
                }
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            isInstalling = false
        }
    }
}
