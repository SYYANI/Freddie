import AppKit
import NaturalLanguage
import Observation
import SwiftUI

/// The translation shown next to a selection while "Translate on Selection" is on.
///
/// It is not a conversation: nothing is written to the assistant archive, so there is no
/// history underline and no learning event. The last few translations are kept in memory
/// only, so selecting the same passage again does not pay for a second request.
@MainActor
@Observable
final class QuickTranslationModel {
    struct Presentation: Equatable {
        enum Phase: Equatable {
            case loading
            case translated
            case failed
        }

        /// Target language and selection identity; tells one selection's bubble from the next.
        var key: String
        var text: String
        var phase: Phase
    }

    /// Translates one selection, reporting the partial translation as it streams in.
    typealias Translate = @MainActor (
        NoteSelectionContext,
        @escaping @MainActor (String) -> Void
    ) async throws -> String

    static let cacheLimit = 40

    /// What the bubble shows; `nil` hides it.
    private(set) var presentation: Presentation?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var currentKey: String?
    @ObservationIgnored private var cache: [String: String] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private let isSelecting: @MainActor () -> Bool

    init(
        settleDelay: Duration = SelectionAssistantPreferences.quickTranslateSelectionDelay,
        isSelecting: @escaping @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    ) {
        self.settleDelay = settleDelay
        self.isSelecting = isSelecting
    }

    /// Call on every change of the selection. Dragging publishes a new selection on every
    /// move, so the request waits until the selection has stopped changing and the mouse
    /// button is up; a change before that cancels it.
    func selectionChanged(
        _ selection: NoteSelectionContext,
        targetLanguage: String,
        translate: @escaping Translate
    ) {
        let key = [targetLanguage, selection.selectionAssistantIdentity].joined(separator: "|")
        guard key != currentKey else { return }
        dismiss()
        currentKey = key

        if let cached = cache[key] {
            presentation = Presentation(key: key, text: cached, phase: .translated)
            return
        }

        task = Task { [weak self, settleDelay, isSelecting] in
            repeat {
                try? await Task.sleep(for: settleDelay)
                guard Task.isCancelled == false else { return }
            } while isSelecting()

            guard let self, self.currentKey == key else { return }
            self.presentation = Presentation(key: key, text: "", phase: .loading)
            do {
                let translation = try await translate(selection) { [weak self] partial in
                    guard let self, self.currentKey == key, self.presentation?.phase == .loading else { return }
                    self.presentation = Presentation(key: key, text: partial, phase: .loading)
                }
                guard Task.isCancelled == false, self.currentKey == key else { return }
                let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                self.remember(text, for: key)
                self.presentation = Presentation(key: key, text: text, phase: .translated)
            } catch {
                // A request cancelled by the next selection also surfaces as a URL error.
                guard Task.isCancelled == false, self.currentKey == key else { return }
                self.presentation = Presentation(key: key, text: error.localizedDescription, phase: .failed)
            }
        }
    }

    /// Hides the bubble and cancels a pending or running request.
    func dismiss() {
        task?.cancel()
        task = nil
        currentKey = nil
        if presentation != nil {
            presentation = nil
        }
    }

    private func remember(_ text: String, for key: String) {
        guard text.isEmpty == false else { return }
        if cache.updateValue(text, forKey: key) == nil {
            cacheOrder.append(key)
        }
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }
}

enum QuickTranslationEligibility {
    /// Whether a selection gets the bubble: long enough to be more than a stray click,
    /// short enough to fit next to the text, not in the translated PDF, and not already
    /// written in the target language.
    static func canTranslate(
        quote: String,
        attachmentKind: AttachmentKind,
        targetLanguage: String
    ) -> Bool {
        guard attachmentKind != .translatedPDF else { return false }
        let count = quote.count
        guard count >= SelectionAssistantPreferences.quickGlossMinimumCharacterCount,
              count <= SelectionAssistantPreferences.quickTranslateMaximumCharacterCount else {
            return false
        }
        return isWritten(quote, in: targetLanguage) == false
    }

    /// True only when the text is confidently recognized as the target language, e.g. a
    /// passage selected in a translation block. Anything uncertain is translated.
    static func isWritten(_ text: String, in targetLanguage: String) -> Bool {
        let target = primarySubtag(targetLanguage)
        guard target.isEmpty == false else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.9 else {
            return false
        }
        return primarySubtag(language.rawValue) == target
    }

    private static func primarySubtag(_ identifier: String) -> String {
        identifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { $0.lowercased() } ?? ""
    }
}

enum QuickTranslationContext {
    /// The text around the selection, for disambiguating terms. The readers supply whole
    /// pages or several paragraphs; a request sent on every selection only needs the
    /// neighbouring sentences. `nil` when the selection cannot be found in a long context.
    static func nearby(quote: String, in localContext: String?, radius: Int = 500) -> String? {
        guard let localContext else { return nil }
        let context = collapsingWhitespace(localContext)
        guard context.isEmpty == false else { return nil }
        let probe = String(collapsingWhitespace(quote).prefix(32))
        guard probe.isEmpty == false, let match = context.range(of: probe) else {
            return context.count <= radius * 2 ? context : nil
        }
        let start = context.index(match.lowerBound, offsetBy: -radius, limitedBy: context.startIndex)
            ?? context.startIndex
        let end = context.index(match.lowerBound, offsetBy: quote.count + radius, limitedBy: context.endIndex)
            ?? context.endIndex
        return String(context[start..<end])
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }
}

enum QuickTranslationBubblePlacement {
    static let margin: CGFloat = 12
    static let gap: CGFloat = 6
    /// A word gets a bubble up to this wide; a paragraph gets one as wide as itself.
    static let narrowWidthLimit: CGFloat = 320
    static let wideWidthLimit: CGFloat = 560
    /// Keeps the bubble clear of the action capsule at the bottom of the reader.
    static let bottomInset: CGFloat = 64

    /// Where the bubble goes, in the container's coordinates (origin at the top left):
    /// just under the selection (centred when it is narrower than the selection, starting
    /// at the selection's leading edge when it is wider), above it when there is no room
    /// below, and never outside the container. `measure` returns the bubble's size for a
    /// width limit and an optional height limit.
    static func frame(
        anchor: CGRect,
        container: CGSize,
        measure: (_ maximumWidth: CGFloat, _ maximumHeight: CGFloat?) -> CGSize
    ) -> CGRect {
        let availableWidth = max(0, container.width - margin * 2)
        let widthLimit = min(availableWidth, max(narrowWidthLimit, min(anchor.width, wideWidthLimit)))
        let spaceBelow = container.height - bottomInset - (anchor.maxY + gap)
        let spaceAbove = anchor.minY - gap - margin

        var size = measure(widthLimit, nil)
        let placesBelow = size.height <= spaceBelow || spaceBelow >= spaceAbove
        let availableHeight = max(0, placesBelow ? spaceBelow : spaceAbove)
        if size.height > availableHeight {
            size = measure(widthLimit, availableHeight)
            size.height = min(size.height, availableHeight)
        }
        size.width = min(size.width, widthLimit)

        let maximumX = max(margin, container.width - margin - size.width)
        let preferredX = size.width <= anchor.width ? anchor.midX - size.width / 2 : anchor.minX
        let x = min(max(preferredX, margin), maximumX)
        let y = placesBelow ? anchor.maxY + gap : anchor.minY - gap - size.height
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// Fills the reader and shows the translation bubble next to the selection. Clicks and
/// scrolling pass through to the reader, so clicking anywhere, including on the bubble,
/// clears the selection and the bubble with it.
struct QuickTranslationBubbleLayer: View {
    let translation: QuickTranslationModel
    let anchor: SelectionAnchorModel

    var body: some View {
        ZStack {
            SelectionAnchorReferenceView(model: anchor)

            if let presentation = translation.presentation, let rect = anchor.rect {
                QuickTranslationBubbleLayout(anchor: rect) {
                    QuickTranslationBubble(presentation: presentation)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: translation.presentation?.key)
        .allowsHitTesting(false)
    }
}

private struct QuickTranslationBubbleLayout: Layout {
    var anchor: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let frame = QuickTranslationBubblePlacement.frame(anchor: anchor, container: bounds.size) { width, height in
            bubble.sizeThatFits(ProposedViewSize(width: width, height: height))
        }
        bubble.place(
            at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(frame.size)
        )
    }
}

private struct QuickTranslationBubble: View {
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pdfDisplayAppearance) private var displayAppearance

    let presentation: QuickTranslationModel.Presentation

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private var isPaperAppearance: Bool {
        displayAppearance == .paper
    }

    var body: some View {
        content
            .font(.system(size: 13, design: isPaperAppearance ? .serif : .default))
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            // The bubble nearly always lies over the lines after the selection; glass
            // alone lets them show through the translation.
            .background(
                isPaperAppearance
                    ? ReadPaperTheme.cardColor(scheme: colorScheme).opacity(0.9)
                    : Color(nsColor: .windowBackgroundColor).opacity(0.84),
                in: shape
            )
            .readPaperGlassEffect(in: shape)
            .overlay {
                shape.strokeBorder(
                    isPaperAppearance
                        ? ReadPaperTheme.cardBorderColor(scheme: colorScheme)
                        : Color.primary.opacity(0.12),
                    lineWidth: 0.5
                )
            }
            .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
            .shadow(color: Color.black.opacity(0.06), radius: 2, y: 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.phase {
        case .loading where presentation.text.isEmpty:
            ProgressView()
                .controlSize(.small)
        case .loading, .translated:
            Text(presentation.text)
        case .failed:
            Label {
                Text(presentation.text)
                    .lineLimit(3)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.secondary)
        }
    }

    private var accessibilityLabel: String {
        switch presentation.phase {
        case .loading where presentation.text.isEmpty:
            String(localized: "Translating...", bundle: bundle)
        case .loading, .translated:
            AppLocalization.format("Translation: %@", bundle: bundle, presentation.text)
        case .failed:
            presentation.text
        }
    }
}
