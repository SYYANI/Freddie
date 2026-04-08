import Foundation

struct ChatTranslationClient: @unchecked Sendable {
    let session: URLSession
    let keychainStore: KeychainStore

    init(session: URLSession = .shared, keychainStore: KeychainStore = KeychainStore()) {
        self.session = session
        self.keychainStore = keychainStore
    }

    func translate(_ text: String, purpose: String, settings: AppSettingsSnapshot) async throws -> String {
        guard !settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let apiKey = try keychainStore.load(account: KeychainStore.openAIAPIKeyAccount),
              !apiKey.isEmpty else {
            throw PaperImportError.missingAPIConfiguration
        }

        let model = modelName(for: purpose, settings: settings)
        let endpoint = endpointURL(baseURL: settings.openAIBaseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt(targetLanguage: settings.targetLanguage)),
                ChatMessage(role: "user", content: text)
            ],
            temperature: 0.2
        ))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChatTranslationError.httpStatus(http.statusCode, body)
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw ChatTranslationError.emptyResponse
        }
        return content
    }

    private func endpointURL(baseURL: String) -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return URL(string: trimmed + "/chat/completions")!
    }

    private func modelName(for purpose: String, settings: AppSettingsSnapshot) -> String {
        switch purpose {
        case "quick":
            settings.quickModelName
        case "heavy":
            settings.heavyModelName
        default:
            settings.normalModelName
        }
    }

    private func systemPrompt(targetLanguage: String) -> String {
        """
        You are a professional academic translator. Translate into \(targetLanguage).
        Preserve academic tone and terminology.
        Do not change placeholders such as [PROTECTED_0].
        Preserve Markdown emphasis markers if present.
        Output only the translation.
        """
    }
}

enum ChatTranslationError: Error, LocalizedError {
    case httpStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let body):
            "Translation request failed with HTTP \(status): \(body)"
        case .emptyResponse:
            "Translation request returned an empty response."
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double
}

private struct ChatMessage: Codable {
    var role: String
    var content: String
}

private struct ChatCompletionResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: ChatMessage
    }
}
