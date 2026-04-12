import Foundation
import SwiftUI

enum AppLocalization {
    struct SupportedLanguage: Identifiable, Equatable {
        let code: String
        let displayName: String

        var id: String { code }
    }

    static let supportedLanguages: [SupportedLanguage] = [
        .init(code: "en", displayName: "English"),
        .init(code: "zh-Hans", displayName: "简体中文")
    ]

    static let userDefaultsKey = "ReadPaper.AppLanguageOverride"

    static var developmentLanguageCode: String {
        normalizedSupportedLanguageCode(for: Bundle.main.developmentLocalization ?? "en") ?? "en"
    }

    static func currentLanguageOverride() -> String? {
        UserDefaults.standard.string(forKey: userDefaultsKey)
    }

    static func currentBundle() -> Bundle {
        resolveBundle(for: currentLanguageOverride())
    }

    static func setLanguageOverride(_ code: String?) {
        if let code {
            UserDefaults.standard.set(code, forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }
    }

    static func bestSupportedLanguageCode(for preferredLanguages: [String]) -> String {
        for candidate in preferredLanguages {
            if let code = normalizedSupportedLanguageCode(for: candidate) {
                return code
            }
        }
        return developmentLanguageCode
    }

    static func normalizedSupportedLanguageCode(for candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if let exactMatch = supportedLanguages.first(where: {
            $0.code.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exactMatch.code
        }

        let locale = Locale(identifier: trimmed.replacingOccurrences(of: "_", with: "-"))
        let languageCode = locale.language.languageCode?.identifier.lowercased() ?? ""
        let scriptCode = locale.language.script?.identifier.lowercased() ?? ""
        let countryCode = locale.region?.identifier.uppercased() ?? ""

        switch languageCode {
        case "en":
            return "en"
        case "zh":
            if scriptCode == "hans" || countryCode == "CN" || countryCode == "SG" {
                return "zh-Hans"
            }
            return nil
        default:
            return nil
        }
    }

    static func resolveBundle(for code: String?) -> Bundle {
        let resolvedCode: String
        if let code {
            resolvedCode = normalizedSupportedLanguageCode(for: code) ?? developmentLanguageCode
        } else {
            resolvedCode = bestSupportedLanguageCode(for: Locale.preferredLanguages)
        }

        return bundle(forSupportedLanguageCode: resolvedCode)
    }

    static func localized(_ key: String, bundle: Bundle? = nil) -> String {
        String(localized: String.LocalizationValue(key), bundle: bundle ?? currentBundle())
    }

    static func format(_ key: String, bundle: Bundle? = nil, _ arguments: CVarArg...) -> String {
        String(format: localized(key, bundle: bundle), locale: Locale.current, arguments: arguments)
    }

    static func errorPrefix(bundle: Bundle? = nil) -> String {
        localized("Error", bundle: bundle) + ":"
    }

    static func errorMessage(_ error: Error, bundle: Bundle? = nil) -> String {
        format("Error: %@", bundle: bundle, error.localizedDescription)
    }

    static func isErrorMessage(_ message: String?, bundle: Bundle? = nil) -> Bool {
        guard let message else { return false }
        return message.hasPrefix(errorPrefix(bundle: bundle))
    }

    private static let passthroughBundle: Bundle = {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("readpaper-l10n-passthrough", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Bundle(url: directory) ?? .main
    }()

    private static func bundle(forSupportedLanguageCode code: String) -> Bundle {
        if code == developmentLanguageCode {
            return passthroughBundle
        }

        let baseCode = String(code.prefix(2))
        for identifier in [code, baseCode] {
            if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
               let lprojBundle = Bundle(path: path) {
                return lprojBundle
            }
        }

        return passthroughBundle
    }
}

@MainActor
@Observable
final class LanguageManager {
    static let shared = LanguageManager()

    private(set) var bundle: Bundle
    private(set) var languageOverride: String?

    private init() {
        let storedOverride = AppLocalization.currentLanguageOverride()
        languageOverride = storedOverride
        bundle = AppLocalization.resolveBundle(for: storedOverride)
    }

    func setLanguage(_ code: String?) {
        languageOverride = code
        AppLocalization.setLanguageOverride(code)
        bundle = AppLocalization.resolveBundle(for: code)
    }
}

private struct LocalizationBundleKey: EnvironmentKey {
    static let defaultValue: Bundle = .main
}

extension EnvironmentValues {
    var localizationBundle: Bundle {
        get { self[LocalizationBundleKey.self] }
        set { self[LocalizationBundleKey.self] = newValue }
    }
}
