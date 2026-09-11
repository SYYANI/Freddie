import AppKit
import SwiftUI

private enum SelectionAssistantLayout {
    static let resultCardMaximumWidth: CGFloat = 600
    static let resultCardMinimumWidth: CGFloat = 340
    static let resultCardMinimumHeight: CGFloat = 160
    static let resultCardAvailableWidthInset: CGFloat = 36
    static let resultCardAvailableHeightInset: CGFloat = 100
    static let resizedCardChromeHeight: CGFloat = 128
    static let questionFieldWidth: CGFloat = 360
    static let singleTurnConversationMaximumHeight: CGFloat = 360
    static let multiTurnConversationMaximumHeight: CGFloat = 600
}

enum SelectionAssistantResizeCorner: CaseIterable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    fileprivate var horizontalMultiplier: CGFloat {
        switch self {
        case .topLeading, .bottomLeading: -2
        case .topTrailing, .bottomTrailing: 2
        }
    }

    fileprivate var verticalMultiplier: CGFloat {
        switch self {
        case .topLeading, .topTrailing: -1
        case .bottomLeading, .bottomTrailing: 1
        }
    }
}

enum SelectionAssistantResizeGeometry {
    static func proposedCardSize(
        startingSize: CGSize,
        dragTranslation: CGSize,
        corner: SelectionAssistantResizeCorner
    ) -> CGSize {
        CGSize(
            width: startingSize.width + dragTranslation.width * corner.horizontalMultiplier,
            height: startingSize.height + dragTranslation.height * corner.verticalMultiplier
        )
    }

    static func clampedCardSize(
        _ proposedSize: CGSize,
        availableSize: CGSize,
        minimumSize: CGSize
    ) -> CGSize {
        let maximumWidth = max(0, availableSize.width - SelectionAssistantLayout.resultCardAvailableWidthInset)
        let maximumHeight = max(0, availableSize.height - SelectionAssistantLayout.resultCardAvailableHeightInset)
        let effectiveMinimumWidth = min(minimumSize.width, maximumWidth)
        let effectiveMinimumHeight = min(minimumSize.height, maximumHeight)
        return CGSize(
            width: min(max(proposedSize.width, effectiveMinimumWidth), maximumWidth),
            height: min(max(proposedSize.height, effectiveMinimumHeight), maximumHeight)
        )
    }
}

private struct SelectionAssistantResultCardSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

struct SelectionAssistantOverlay: View {
    @Environment(\.localizationBundle) private var bundle

    let selection: NoteSelectionContext
    let progress: SelectionAssistantProgress?
    let initialConversation: SelectionAssistantConversationSnapshot?
    let perform: @MainActor (
        SelectionAssistantRequest,
        @escaping @MainActor (String) -> Void
    ) async throws -> SelectionAssistantResult
    let saveAsNote: @MainActor (NoteSelectionContext, String, UUID?) throws -> UUID
    let onSourceActivated: @MainActor (AssistantSource) -> Void
    let onConversationChanged: @MainActor (SelectionAssistantConversationSnapshot) -> Void
    let onInteractionBegan: @MainActor @Sendable () -> Void
    let onDismiss: @MainActor @Sendable () -> Void

    @State private var question = ""
    @State private var isEnteringQuestion = false
    @State private var isWorking = false
    @State private var activeAction: SelectionAssistantAction?
    @State private var conversation: [SelectionAssistantConversationTurn] = []
    @State private var pendingQuestion: String?
    @State private var followUpQuestion = ""
    @State private var errorText: String?
    @State private var saveErrorText: String?
    @State private var isSavedAsNote = false
    @State private var savedNoteID: UUID?
    @State private var conversationScrollRequest: SelectionAssistantConversationScrollRequest?
    @State private var task: Task<Void, Never>?
    @State private var completedRequests: [SelectionAssistantRequest] = []
    @State private var partialAnswer = ""
    @State private var userResultCardSize: CGSize?
    @State private var measuredResultCardSize: CGSize = .zero
    @State private var resizeStartSize: CGSize?
    @FocusState private var isQuestionFieldFocused: Bool
    @FocusState private var isFollowUpFieldFocused: Bool

    private var layoutAnimation: Animation {
        .smooth(duration: 0.34, extraBounce: 0)
    }

    var body: some View {
        GeometryReader { geometry in
            let availableSize = geometry.size
            let cardSize = resolvedResultCardSize(in: availableSize)

            VStack(spacing: 10) {
                if activeAction != nil {
                    resultCard
                        .frame(
                            width: cardSize.width,
                            height: userResultCardSize == nil ? nil : cardSize.height,
                            alignment: .topLeading
                        )
                        .selectionAssistantMaterial(cornerRadius: 14)
                        .measureSelectionAssistantResultCardSize()
                        .overlay {
                            resizeCornerHitAreas(cardSize: cardSize, availableSize: availableSize)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    onInteractionBegan()
                                }
                        )
                }

                actionCapsule
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                onInteractionBegan()
                            }
                    )
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .frame(width: availableSize.width, height: availableSize.height, alignment: .bottom)
            .onPreferenceChange(SelectionAssistantResultCardSizePreferenceKey.self) { size in
                guard size.width > 0, size.height > 0, measuredResultCardSize != size else { return }
                measuredResultCardSize = size
            }
        }
        .animation(layoutAnimation, value: activeAction)
        .animation(layoutAnimation, value: isEnteringQuestion)
        .onAppear(perform: restoreInitialConversation)
        .onChange(of: selection.selectionAssistantIdentity) { _, _ in
            resetForNewSelection()
            restoreInitialConversation()
        }
        .onChange(of: initialConversation?.modifiedAt) { _, _ in
            restoreInitialConversation()
        }
        .onDisappear {
            task?.cancel()
        }
    }

    @ViewBuilder
    private var actionCapsule: some View {
        if isEnteringQuestion {
            HStack(spacing: 6) {
                TextField(
                    String(localized: "Ask about the selected text...", bundle: bundle),
                    text: $question
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isQuestionFieldFocused)
                .onSubmit(submitQuestion)
                .onExitCommand {
                    isEnteringQuestion = false
                }

                Button(action: submitQuestion) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                .help(String(localized: "Send Question", bundle: bundle))
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(width: SelectionAssistantLayout.questionFieldWidth)
            .selectionAssistantMaterial(cornerRadius: 24)
        } else {
            HStack(spacing: 4) {
                actionButton(
                    .explain,
                    title: String(localized: "Explain Selected Text", bundle: bundle),
                    systemImage: "sparkles"
                )
                actionButton(
                    .ask,
                    title: String(localized: "Ask AI About Selected Text", bundle: bundle),
                    systemImage: "bubble.left"
                )
                actionButton(
                    .translate,
                    title: String(localized: "Translate Selected Text", bundle: bundle),
                    systemImage: "translate"
                )
            }
            .padding(6)
            .selectionAssistantMaterial(cornerRadius: 22)
        }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: activeAction == .translate ? "translate" : "sparkles")
                Text(resultTitle)
                    .fontWeight(.semibold)

                Spacer(minLength: 8)

                if conversation.isEmpty == false {
                    Button {
                        saveConversationAsNote()
                    } label: {
                        Label(
                            isSavedAsNote
                                ? String(localized: "Saved to Notes", bundle: bundle)
                                : String(localized: "Save as Note", bundle: bundle),
                            systemImage: isSavedAsNote ? "checkmark.circle.fill" : "note.text.badge.plus"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isSavedAsNote)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(conversationMarkdown, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Copy", bundle: bundle))
                }

                if isWorking {
                    Button(action: stopGeneration) {
                        Image(systemName: "stop.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Stop Generating", bundle: bundle))
                    .accessibilityLabel(String(localized: "Stop Generating", bundle: bundle))
                }

                Button {
                    closeResultCard()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close", bundle: bundle))
            }
            .foregroundStyle(activeAction == .translate ? Color.orange : Color.accentColor)

            conversationArea

            if conversation.isEmpty == false {
                Divider()

                HStack(spacing: 6) {
                    TextField(
                        String(localized: "Ask a follow-up...", bundle: bundle),
                        text: $followUpQuestion
                    )
                    .textFieldStyle(.plain)
                    .focused($isFollowUpFieldFocused)
                    .onSubmit(submitFollowUp)

                    Button(action: submitFollowUp) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        followUpQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking
                    )
                    .help(String(localized: "Send Follow-up", bundle: bundle))
                    .accessibilityLabel(String(localized: "Send Follow-up", bundle: bundle))

                    Menu {
                        Button(String(localized: "Regenerate", bundle: bundle)) {
                            regenerateLastAnswer()
                        }
                        .disabled(completedRequests.isEmpty)
                        Button(String(localized: "Shorten the answer", bundle: bundle)) {
                            submitPresetFollowUp("Make the preceding answer shorter while preserving its evidence and caveats.")
                        }
                        Button(String(localized: "Expand the background", bundle: bundle)) {
                            submitPresetFollowUp("Expand the essential background, keeping paper claims distinct from general knowledge.")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.055), in: Capsule())
                .transition(.opacity)
            }

            if let saveErrorText {
                Text(saveErrorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .font(.system(size: 14))
        .lineSpacing(3)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resizeCornerHitAreas(cardSize: CGSize, availableSize: CGSize) -> some View {
        ZStack {
            resizeCornerHitArea(.topLeading, cardSize: cardSize, availableSize: availableSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            resizeCornerHitArea(.topTrailing, cardSize: cardSize, availableSize: availableSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            resizeCornerHitArea(.bottomLeading, cardSize: cardSize, availableSize: availableSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            resizeCornerHitArea(.bottomTrailing, cardSize: cardSize, availableSize: availableSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func resizeCornerHitArea(
        _ corner: SelectionAssistantResizeCorner,
        cardSize: CGSize,
        availableSize: CGSize
    ) -> some View {
        Color.clear
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .help(String(localized: "Resize AI window", bundle: bundle))
            .accessibilityLabel(String(localized: "Resize AI window", bundle: bundle))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onInteractionBegan()
                        let startingSize = resizeStartSize ?? CGSize(
                            width: cardSize.width,
                            height: max(measuredResultCardSize.height, SelectionAssistantLayout.resultCardMinimumHeight)
                        )
                        if resizeStartSize == nil {
                            resizeStartSize = startingSize
                        }
                        let proposedSize = SelectionAssistantResizeGeometry.proposedCardSize(
                            startingSize: startingSize,
                            dragTranslation: value.translation,
                            corner: corner
                        )
                        userResultCardSize = clampedResultCardSize(proposedSize, in: availableSize)
                    }
                    .onEnded { _ in
                        resizeStartSize = nil
                    }
            )
    }

    private var conversationArea: some View {
        SelectionAssistantConversationView(
            conversation: conversation,
            pendingQuestion: pendingQuestion,
            isWorking: isWorking,
            errorText: errorText,
            loadingText: loadingText,
            partialAnswer: partialAnswer,
            showsInitialQuestion: activeAction == .ask,
            conversationMaximumHeight: conversationMaximumHeight,
            conversationScrollRequest: conversationScrollRequest,
            onSourceActivated: onSourceActivated
        )
    }

    private func actionButton(
        _ action: SelectionAssistantAction,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            onInteractionBegan()
            if action == .ask {
                isEnteringQuestion = true
                Task { @MainActor in
                    isQuestionFieldFocused = true
                }
            } else {
                runInitialAction(action, question: nil)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(SelectionAssistantCircleButtonStyle())
        .disabled(isWorking)
        .help(title)
        .accessibilityLabel(title)
    }

    private func submitQuestion() {
        onInteractionBegan()
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        isEnteringQuestion = false
        runInitialAction(.ask, question: normalized)
    }

    private func runInitialAction(_ action: SelectionAssistantAction, question: String?) {
        task?.cancel()
        withAnimation(layoutAnimation) {
            activeAction = action
            conversation = []
            completedRequests = []
            pendingQuestion = question ?? initialInstruction(for: action)
            conversationScrollRequest = .init(turnIndex: 0)
            followUpQuestion = ""
            errorText = nil
            saveErrorText = nil
            isSavedAsNote = false
            savedNoteID = nil
            partialAnswer = ""
            isWorking = true
        }

        let request = SelectionAssistantRequest(
            action: action,
            selection: selection.quote,
            localContext: selection.localContext,
            question: question,
            scope: .automatic
        )
        task = Task { @MainActor in
            do {
                let result = try await perform(request) { partialAnswer in
                    self.partialAnswer = partialAnswer
                }
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    conversation = [SelectionAssistantConversationTurn(
                        question: pendingQuestion ?? initialInstruction(for: action),
                        result: result
                    )]
                    completedRequests = [request]
                    pendingQuestion = nil
                    conversationScrollRequest = .init(turnIndex: 0)
                    isWorking = false
                }
                persistConversation()
            } catch is CancellationError {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    errorText = error.localizedDescription
                    conversationScrollRequest = .init(turnIndex: 0)
                    isWorking = false
                }
                persistConversation()
            }
        }
    }

    private func submitFollowUp() {
        onInteractionBegan()
        let normalized = followUpQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false, isWorking == false else { return }

        task?.cancel()
        let pendingTurnIndex = conversation.count
        withAnimation(layoutAnimation) {
            followUpQuestion = ""
            pendingQuestion = normalized
            conversationScrollRequest = .init(turnIndex: pendingTurnIndex)
            errorText = nil
            saveErrorText = nil
            isSavedAsNote = false
            partialAnswer = ""
            isWorking = true
        }

        let priorConversation = conversation
        let request = SelectionAssistantRequest(
            action: .ask,
            selection: selection.quote,
            localContext: selection.localContext,
            question: normalized,
            conversation: priorConversation,
            scope: .automatic
        )
        task = Task { @MainActor in
            do {
                let result = try await perform(request) { partialAnswer in
                    self.partialAnswer = partialAnswer
                }
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    conversation.append(SelectionAssistantConversationTurn(
                        question: normalized,
                        result: result
                    ))
                    completedRequests.append(request)
                    pendingQuestion = nil
                    conversationScrollRequest = .init(turnIndex: pendingTurnIndex)
                    isWorking = false
                }
                persistConversation()
            } catch is CancellationError {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    errorText = error.localizedDescription
                    conversationScrollRequest = .init(turnIndex: pendingTurnIndex)
                    isWorking = false
                }
            }
        }
    }

    private func resetForNewSelection() {
        task?.cancel()
        task = nil
        withAnimation(layoutAnimation) {
            question = ""
            followUpQuestion = ""
            conversation = []
            completedRequests = []
            pendingQuestion = nil
            conversationScrollRequest = nil
            isQuestionFieldFocused = false
            isFollowUpFieldFocused = false
            isEnteringQuestion = false
            isWorking = false
            activeAction = nil
            errorText = nil
            saveErrorText = nil
            isSavedAsNote = false
            savedNoteID = nil
            partialAnswer = ""
            userResultCardSize = nil
            measuredResultCardSize = .zero
            resizeStartSize = nil
        }
    }

    private func closeResultCard() {
        resetForNewSelection()
        onDismiss()
    }

    private func stopGeneration() {
        task?.cancel()
        task = nil
        withAnimation(layoutAnimation) {
            pendingQuestion = nil
            isWorking = false
            errorText = String(localized: "Generation stopped.", bundle: bundle)
            partialAnswer = ""
        }
    }

    private func submitPresetFollowUp(_ instruction: String) {
        guard isWorking == false else { return }
        followUpQuestion = instruction
        submitFollowUp()
    }

    private func regenerateLastAnswer() {
        onInteractionBegan()
        guard isWorking == false,
              let request = completedRequests.last,
              let lastTurn = conversation.last else { return }

        task?.cancel()
        let turnIndex = max(0, conversation.count - 1)
        withAnimation(layoutAnimation) {
            conversation.removeLast()
            completedRequests.removeLast()
            pendingQuestion = lastTurn.question
            conversationScrollRequest = .init(turnIndex: turnIndex)
            errorText = nil
            saveErrorText = nil
            isSavedAsNote = false
            partialAnswer = ""
            isWorking = true
        }

        task = Task { @MainActor in
            do {
                let result = try await perform(request) { partialAnswer in
                    self.partialAnswer = partialAnswer
                }
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    conversation.append(SelectionAssistantConversationTurn(
                        question: lastTurn.question,
                        result: result
                    ))
                    completedRequests.append(request)
                    pendingQuestion = nil
                    conversationScrollRequest = .init(turnIndex: turnIndex)
                    isWorking = false
                }
                persistConversation()
            } catch is CancellationError {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    errorText = error.localizedDescription
                    conversationScrollRequest = .init(turnIndex: turnIndex)
                    isWorking = false
                }
            }
        }
    }

    private func restoreInitialConversation() {
        guard let initialConversation,
              initialConversation.selectionIdentity == selection.selectionAssistantIdentity,
              initialConversation.turns.isEmpty == false,
              isWorking == false else { return }
        activeAction = initialConversation.action
        conversation = initialConversation.turns
        completedRequests = []
        pendingQuestion = nil
        errorText = nil
        partialAnswer = ""
        conversationScrollRequest = .init(turnIndex: max(0, conversation.count - 1))
    }

    private func persistConversation() {
        guard let activeAction, conversation.isEmpty == false else { return }
        onConversationChanged(SelectionAssistantConversationSnapshot(
            selectionIdentity: selection.selectionAssistantIdentity,
            attachmentID: selection.attachmentID,
            quote: selection.trimmedQuote,
            pageIndex: selection.pageIndex,
            htmlSelector: selection.htmlSelector,
            action: activeAction,
            scope: conversation.last?.result.scope ?? .nearby,
            turns: conversation
        ))
    }

    private func saveConversationAsNote() {
        onInteractionBegan()
        guard isSavedAsNote == false else { return }
        do {
            savedNoteID = try saveAsNote(selection, conversationMarkdown, savedNoteID)
            saveErrorText = nil
            isSavedAsNote = true
        } catch {
            withAnimation(layoutAnimation) {
                saveErrorText = AppLocalization.format(
                    "Unable to save note: %@",
                    bundle: bundle,
                    error.localizedDescription
                )
            }
        }
    }

    private func shouldShowQuestion(at index: Int) -> Bool {
        index > 0 || activeAction == .ask
    }

    private var isMultiTurnConversation: Bool {
        conversation.count > 1
            || (conversation.isEmpty == false && (pendingQuestion != nil || errorText != nil))
    }

    private var conversationMaximumHeight: CGFloat {
        if let userResultCardSize {
            return max(0, userResultCardSize.height - SelectionAssistantLayout.resizedCardChromeHeight)
        }
        return isMultiTurnConversation
            ? SelectionAssistantLayout.multiTurnConversationMaximumHeight
            : SelectionAssistantLayout.singleTurnConversationMaximumHeight
    }

    private func resolvedResultCardSize(in availableSize: CGSize) -> CGSize {
        let defaultHeight = max(measuredResultCardSize.height, SelectionAssistantLayout.resultCardMinimumHeight)
        let proposedSize = userResultCardSize ?? CGSize(
            width: SelectionAssistantLayout.resultCardMaximumWidth,
            height: defaultHeight
        )
        return clampedResultCardSize(proposedSize, in: availableSize)
    }

    private func clampedResultCardSize(_ proposedSize: CGSize, in availableSize: CGSize) -> CGSize {
        SelectionAssistantResizeGeometry.clampedCardSize(
            proposedSize,
            availableSize: availableSize,
            minimumSize: CGSize(
                width: SelectionAssistantLayout.resultCardMinimumWidth,
                height: SelectionAssistantLayout.resultCardMinimumHeight
            )
        )
    }

    private func initialInstruction(for action: SelectionAssistantAction) -> String {
        switch action {
        case .translate:
            return "Translate the selected text."
        case .explain:
            return "Explain the selected text."
        case .ask:
            return question
        }
    }

    private var conversationMarkdown: String {
        var sections = ["## \(resultTitle)"]
        for (index, turn) in conversation.enumerated() {
            if shouldShowQuestion(at: index) {
                sections.append("**\(AppLocalization.format("Question: %@", bundle: bundle, turn.question))**")
            }
            sections.append(turn.answer)
            if turn.result.sources.isEmpty == false {
                let sourceLines: [String] = turn.result.citationSources.enumerated().map {
                    sourceIndex, source in
                    var location = source.title
                    if let pageIndex = source.pageIndex {
                        location += " (\(AppLocalization.format("Page %d", bundle: bundle, pageIndex + 1)))"
                    }
                    let citationLabel = "S\(sourceIndex + 1)"
                    if let urlString = source.urlString, urlString.isEmpty == false {
                        return "- [\(citationLabel)] [\(location)](\(urlString))"
                    }
                    return "- [\(citationLabel)] \(location)"
                }
                sections.append("### \(String(localized: "Sources", bundle: bundle))\n\(sourceLines.joined(separator: "\n"))")
            }
            if turn.result.warnings.isEmpty == false {
                sections.append(turn.result.warnings.map { "> ⚠️ \($0)" }.joined(separator: "\n"))
            }
        }
        return sections.joined(separator: "\n\n")
    }

    private var resultTitle: String {
        switch activeAction {
        case .translate:
            return String(localized: "Translation", bundle: bundle)
        case .explain:
            return String(localized: "AI Explanation", bundle: bundle)
        case .ask:
            return String(localized: "Ask AI", bundle: bundle)
        case nil:
            return ""
        }
    }

    private var loadingText: String {
        switch progress {
        case .collectingPaperContext:
            return String(localized: "Collecting paper context...", bundle: bundle)
        case .searchingFullText:
            return String(localized: "Searching the full paper...", bundle: bundle)
        case .foundPaperSources(let count):
            return AppLocalization.format("Found %d relevant passages.", bundle: bundle, count)
        case .searchingExternalSources:
            return String(localized: "Searching the web...", bundle: bundle)
        case .generatingAnswer, nil:
            break
        }
        if conversation.isEmpty == false || activeAction == .ask {
            return String(localized: "Generating an answer...", bundle: bundle)
        }
        switch activeAction {
        case .translate:
            return String(localized: "Translating...", bundle: bundle)
        case .explain:
            return String(localized: "Understanding the selected text in context...", bundle: bundle)
        case .ask:
            return String(localized: "Generating an answer...", bundle: bundle)
        case nil:
            return String(localized: "Working...", bundle: bundle)
        }
    }

}

struct SelectionAssistantConversationView: View {
    @Environment(\.localizationBundle) private var bundle

    let conversation: [SelectionAssistantConversationTurn]
    let pendingQuestion: String?
    let isWorking: Bool
    let errorText: String?
    let loadingText: String
    let partialAnswer: String
    let showsInitialQuestion: Bool
    let conversationMaximumHeight: CGFloat
    let conversationScrollRequest: SelectionAssistantConversationScrollRequest?
    var onSourceActivated: (AssistantSource) -> Void

    @State private var conversationHeights: [SelectionAssistantConversationGeometry: CGFloat] = [:]
    @State private var streamingAnswerRequestID: UUID?

    init(
        conversation: [SelectionAssistantConversationTurn],
        pendingQuestion: String?,
        isWorking: Bool,
        errorText: String?,
        loadingText: String,
        partialAnswer: String = "",
        showsInitialQuestion: Bool,
        conversationMaximumHeight: CGFloat,
        conversationScrollRequest: SelectionAssistantConversationScrollRequest?,
        onSourceActivated: @escaping (AssistantSource) -> Void = { _ in }
    ) {
        self.conversation = conversation
        self.pendingQuestion = pendingQuestion
        self.isWorking = isWorking
        self.errorText = errorText
        self.loadingText = loadingText
        self.partialAnswer = partialAnswer
        self.showsInitialQuestion = showsInitialQuestion
        self.conversationMaximumHeight = conversationMaximumHeight
        self.conversationScrollRequest = conversationScrollRequest
        self.onSourceActivated = onSourceActivated
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Keep a turn's identity when its loading status becomes
                        // an answer, so scrollTo never sees two copies of its ID.
                        ForEach(0..<conversationTurnCount, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 10) {
                                if index < conversation.count {
                                    conversationTurn(conversation[index], index: index)
                                } else if let pendingQuestion {
                                    if shouldShowQuestion(at: index) {
                                        Text(AppLocalization.format("Question: %@", bundle: bundle, pendingQuestion))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }

                                    conversationStatus
                                }
                            }
                            .id(SelectionAssistantConversationScrollTarget.turn(index))
                            .measureConversationHeight(.turn(index))
                        }
                    }

                    Color.clear
                        .frame(height: SelectionAssistantConversationScrollTarget.bottomInset)
                        .id(SelectionAssistantConversationScrollTarget.bottom)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .measureConversationHeight(.content)
            }
            // Keep the viewport tied to the measured content height. Streaming
            // still follows the bottom, but a short first answer must not reserve
            // the entire maximum height and leave a large empty card behind.
            .frame(minHeight: 0, idealHeight: conversationViewportHeight, maxHeight: conversationViewportHeight)
            .clipped()
            .measureConversationHeight(.viewport)
            .opacity(hasConversationAreaContent ? 1 : 0)
            .onPreferenceChange(SelectionAssistantConversationHeightPreferenceKey.self) { height in
                var normalizedHeights = height.mapValues { ceil(max(0, $0)) }
                // Finalization replaces the streamed Markdown node and can report
                // a shorter content height after trimming/citation normalization.
                // Retain the largest content measurement already presented so the
                // card never collapses at the end of generation.
                normalizedHeights[.content] = max(
                    normalizedHeights[.content] ?? 0,
                    conversationHeights[.content] ?? 0
                )
                guard normalizedHeights != conversationHeights else { return }

                // Streaming updates arrive much faster than a layout animation can
                // finish. Keep geometry bookkeeping out of the surrounding card's
                // animation transaction so successive tokens cannot make it pulse.
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    conversationHeights = normalizedHeights
                }
            }
            .task(id: conversationScrollUpdate) {
                let update = conversationScrollUpdate
                guard let target = update.target else { return }
                // Geometry changes restart this task. Scroll after the measured
                // layout is installed, including loading -> answer and resizing.
                await Task.yield()
                guard Task.isCancelled == false else { return }

                if update.followsStreamingBottom {
                    // Do not stack an animation for every streamed token. Immediate
                    // scrolling keeps the newest text attached to the bottom edge.
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        proxy.scrollTo(target, anchor: .bottom)
                    }
                } else {
                    // Static Markdown rendering updates asynchronously and can
                    // produce a few sequential geometry changes. Wait for those
                    // updates to settle before animating to the requested target.
                    try? await Task.sleep(for: .milliseconds(50))
                    guard Task.isCancelled == false else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(target, anchor: target == .bottom ? .bottom : .top)
                    }
                }
            }
        }
        .allowsHitTesting(hasConversationAreaContent)
        .onChange(of: partialAnswer.isEmpty) { _, isEmpty in
            guard isEmpty == false else { return }
            streamingAnswerRequestID = conversationScrollRequest?.id
        }
    }

    @ViewBuilder
    private var conversationStatus: some View {
        if isWorking {
            if partialAnswer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loadingText)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                ReadPaperMarkdownView(markdown: partialAnswer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let errorText {
            Text(errorText)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func conversationTurn(
        _ turn: SelectionAssistantConversationTurn,
        index: Int
    ) -> some View {
        if shouldShowQuestion(at: index) {
            Text(AppLocalization.format("Question: %@", bundle: bundle, turn.question))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }

        ReadPaperMarkdownView(markdown: turn.answer)
            .frame(maxWidth: .infinity, alignment: .leading)

        if turn.result.sources.isEmpty == false {
            Text(sourceSummary(for: turn.result))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(turn.result.citationSources.enumerated()), id: \.element.id) { sourceIndex, source in
                        Button {
                            onSourceActivated(source)
                        } label: {
                            Label(
                                "S\(sourceIndex + 1) · \(source.title)",
                                systemImage: sourceIcon(source)
                            )
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(source.excerpt)
                    }
                }
            }
        }

        ForEach(Array(turn.result.warnings.enumerated()), id: \.offset) { _, warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if index < conversation.count - 1 {
            Divider()
        }
    }

    private func shouldShowQuestion(at index: Int) -> Bool {
        index > 0 || showsInitialQuestion
    }

    private func sourceSummary(for result: SelectionAssistantResult) -> String {
        switch result.scope {
        case .automatic:
            return String(localized: "Based on automatically selected context", bundle: bundle)
        case .nearby:
            return String(localized: "Based on the current passage", bundle: bundle)
        case .fullPaper:
            let count = result.sources.filter { $0.kind == .paperHTML || $0.kind == .paperPDF }.count
            return AppLocalization.format("Based on %d full-paper passages", bundle: bundle, count)
        case .external:
            let count = result.sources.filter { $0.kind == .external }.count
            if result.sources.contains(where: {
                $0.id == AssistantSource.liveWebSearchID || $0.isLiveWebSearchResult
            }) {
                return String(localized: "Based on paper context and live web search", bundle: bundle)
            }
            return AppLocalization.format("Based on paper context and %d external sources", bundle: bundle, count)
        }
    }

    private func sourceIcon(_ source: AssistantSource) -> String {
        switch source.kind {
        case .currentSelection: return "text.quote"
        case .paperHTML: return "doc.richtext"
        case .paperPDF: return "doc.text"
        case .userNote: return "note.text"
        case .paperMetadata: return "info.circle"
        case .external: return "network"
        }
    }

    private var conversationTurnCount: Int {
        conversation.count + (pendingQuestion == nil ? 0 : 1)
    }

    private var conversationViewportHeight: CGFloat {
        return min(ceil(conversationHeights[.content] ?? 0), conversationMaximumHeight)
    }

    private var conversationScrollUpdate: SelectionAssistantConversationScrollUpdate {
        SelectionAssistantConversationScrollUpdate(
            request: conversationScrollRequest,
            heights: conversationHeights,
            followsStreamingBottom: followsStreamingBottom
        )
    }

    private var followsStreamingBottom: Bool {
        guard isWorking else { return false }
        guard let requestID = conversationScrollRequest?.id else {
            return partialAnswer.isEmpty == false
        }
        return partialAnswer.isEmpty == false || streamingAnswerRequestID == requestID
    }

    private var hasConversationAreaContent: Bool {
        conversation.isEmpty == false
            || pendingQuestion != nil
            || isWorking
            || errorText != nil
    }
}

enum SelectionAssistantConversationScrollTarget: Hashable {
    case bottom
    case turn(Int)

    static let bottomInset: CGFloat = 10

    static func resolve(
        turnIndex: Int,
        turnHeight: CGFloat,
        viewportHeight: CGFloat,
        followsStreamingBottom: Bool = false
    ) -> Self {
        if followsStreamingBottom {
            return .bottom
        }
        // Never advance past the latest question just to reveal the answer's tail.
        return turnHeight + bottomInset <= viewportHeight ? .bottom : .turn(turnIndex)
    }
}

private enum SelectionAssistantConversationGeometry: Hashable {
    case content
    case viewport
    case turn(Int)
}

struct SelectionAssistantConversationScrollRequest: Equatable {
    let id = UUID()
    let turnIndex: Int
}

private struct SelectionAssistantConversationScrollUpdate: Equatable {
    let request: SelectionAssistantConversationScrollRequest?
    let heights: [SelectionAssistantConversationGeometry: CGFloat]
    let followsStreamingBottom: Bool

    var target: SelectionAssistantConversationScrollTarget? {
        guard let request,
              let turnHeight = heights[.turn(request.turnIndex)],
              let viewportHeight = heights[.viewport], viewportHeight > 0 else { return nil }
        return .resolve(
            turnIndex: request.turnIndex,
            turnHeight: turnHeight,
            viewportHeight: viewportHeight,
            followsStreamingBottom: followsStreamingBottom
        )
    }
}

private struct SelectionAssistantConversationHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [SelectionAssistantConversationGeometry: CGFloat] { [:] }

    static func reduce(
        value: inout [SelectionAssistantConversationGeometry: CGFloat],
        nextValue: () -> [SelectionAssistantConversationGeometry: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private struct SelectionAssistantCircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.accentColor : Color.primary)
            .background {
                Circle()
                    .fill(configuration.isPressed ? Color.accentColor.opacity(0.14) : Color.clear)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    func measureSelectionAssistantResultCardSize() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SelectionAssistantResultCardSizePreferenceKey.self,
                    value: geometry.size
                )
            }
        }
    }

    func measureConversationHeight(_ element: SelectionAssistantConversationGeometry) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SelectionAssistantConversationHeightPreferenceKey.self,
                    value: [element: geometry.size.height]
                )
            }
        }
    }

    func selectionAssistantMaterial(cornerRadius: CGFloat) -> some View {
        readPaperGlassEffect(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            interactive: true
        )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 12, y: 6)
            .shadow(color: Color.black.opacity(0.06), radius: 3, y: 1)
    }
}
