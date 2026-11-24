import Foundation

/// Suggested names for files the reader exports, so each export is named after its paper
/// rather than after the attachment's storage name (every attachment is `paper.pdf`).
enum ExportFilename {
    static let fallbackTitle = "paper"
    static let maxTitleLength = 120

    /// `Title.pdf`, or `Title (variant).pdf` when the file is not the plain original,
    /// e.g. a translation or the bilingual HTML export.
    static func pdf(title: String, variant: String? = nil) -> String {
        var name = sanitizedTitle(title)
        if let variant = variant.map(sanitizedComponent), !variant.isEmpty {
            name += " (\(variant))"
        }
        return name + ".pdf"
    }

    static func sanitizedTitle(_ title: String) -> String {
        let cleaned = sanitizedComponent(title)
        guard !cleaned.isEmpty else { return fallbackTitle }
        guard cleaned.count > maxTitleLength else { return cleaned }
        return String(cleaned.prefix(maxTitleLength))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
    }

    /// Replaces path separators and control characters, collapses whitespace, and drops
    /// leading dots so the name is neither a path nor a hidden file.
    private static func sanitizedComponent(_ text: String) -> String {
        let separators = CharacterSet(charactersIn: "/:\\")
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if separators.contains(scalar) {
                scalars.append("-")
            } else if CharacterSet.controlCharacters.contains(scalar)
                        || CharacterSet.newlines.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.drop { $0 == "." || $0 == " " })
    }
}
