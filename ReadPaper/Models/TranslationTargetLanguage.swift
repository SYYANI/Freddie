import Foundation

struct TranslationTargetLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let nativeName: String

    var id: String { code }

    static let english = TranslationTargetLanguage(
        code: "EN",
        nativeName: "English"
    )

    static let simplifiedChinese = TranslationTargetLanguage(
        code: "zh-CN",
        nativeName: "中文（简体）"
    )

    static let supported: [TranslationTargetLanguage] = [
        english,
        simplifiedChinese
    ]
}
