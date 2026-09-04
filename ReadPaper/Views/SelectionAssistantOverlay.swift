import AppKit
import SwiftUI

struct SelectionAssistantOverlay: View {
    private enum ConversationScrollTarget: Hashable {
        case pending
    }

    @Environment(\.localizationBundle) private var bundle

    let selection: NoteSelectionContext
    let perform: @MainActor (SelectionAssistantRequest) async throws -> String
    let saveAsNote: @MainActor (NoteSelectionContext, String, UUID?) throws -> UUID
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
    @State private var conversationContentHeight: CGFloat = 0
    @State private var task: Task<Void, Never>?
    @FocusState private var isQuestionFieldFocused: Bool
    @FocusState private var isFollowUpFieldFocused: Bool

    private var layoutAnimation: Animation {
        .smooth(duration: 0.34, extraBounce: 0)
    }

    var body: some View {
        VStack(spacing: 10) {
            if activeAction != nil {
                resultCard
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }

            actionCapsule
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            onInteractionBegan()
                        }
                )
        }
        .frame(maxWidth: 390)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .animation(layoutAnimation, value: activeAction)
        .animation(layoutAnimation, value: isEnteringQuestion)
        .onChange(of: selection.selectionAssistantIdentity) { _, _ in
            resetForNewSelection()
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
            .frame(width: 270)
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
        .frame(maxWidth: 370, alignment: .leading)
        .selectionAssistantMaterial(cornerRadius: 14)
    }

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(conversation.enumerated()), id: \.offset) { index, turn in
                        VStack(alignment: .leading, spacing: 10) {
                            conversationTurn(turn, index: index)
                        }
                        .id(index)
                    }

                    if let pendingQuestion,
                       shouldShowQuestion(at: conversation.count) {
                        Text(AppLocalization.format("Question: %@", bundle: bundle, pendingQuestion))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .id(ConversationScrollTarget.pending)
                            .transition(.opacity)
                    }

                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(loadingText)
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    } else if let errorText {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: SelectionAssistantConversationHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
            }
            .frame(height: conversationViewportHeight)
            .clipped()
            .opacity(hasConversationAreaContent ? 1 : 0)
            .onPreferenceChange(SelectionAssistantConversationHeightPreferenceKey.self) { height in
                let normalizedHeight = ceil(max(0, height))
                guard abs(normalizedHeight - conversationContentHeight) > 0.5 else { return }
                withAnimation(layoutAnimation) {
                    conversationContentHeight = normalizedHeight
                }
            }
            .onChange(of: pendingQuestion) { oldQuestion, newQuestion in
                guard oldQuestion == nil,
                      newQuestion != nil,
                      conversation.isEmpty == false else { return }
                withAnimation(layoutAnimation) {
                    proxy.scrollTo(ConversationScrollTarget.pending, anchor: .top)
                }
            }
        }
        .allowsHitTesting(hasConversationAreaContent)
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

        Text(turn.answer)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)

        if index < conversation.count - 1 {
            Divider()
        }
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
            pendingQuestion = question ?? initialInstruction(for: action)
            followUpQuestion = ""
            errorText = nil
            saveErrorText = nil
            isSavedAsNote = false
            savedNoteID = nil
            isWorking = true
        }

        let request = SelectionAssistantRequest(
            action: action,
            selection: selection.quote,
            localContext: selection.localContext,
            question: question
        )
        task = Task { @MainActor in
            do {
                let response = try await perform(request)
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    conversation = [SelectionAssistantConversationTurn(
                        question: pendingQuestion ?? initialInstruction(for: action),
                        answer: response
                    )]
                    pendingQuestion = nil
                    isWorking = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    errorText = error.localizedDescription
                    pendingQuestion = nil
                    isWorking = false
                }
            }
        }
    }

    private func submitFollowUp() {
        onInteractionBegan()
        let normalized = followUpQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false, isWorking == false else { return }

        task?.cancel()
        withAnimation(layoutAnimation) {
            followUpQuestion = ""
            pendingQuestion = normalized
            errorText = nil
            saveErrorText = nil
            isSavedAsNote = false
            isWorking = true
        }

        let priorConversation = conversation
        let request = SelectionAssistantRequest(
            action: .ask,
            selection: selection.quote,
            localContext: selection.localContext,
            question: normalized,
            conversation: priorConversation
        )
        task = Task { @MainActor in
            do {
                let response = try await perform(request)
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    conversation.append(SelectionAssistantConversationTurn(
                        question: normalized,
                        answer: response
                    ))
                    pendingQuestion = nil
                    isWorking = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                withAnimation(layoutAnimation) {
                    errorText = error.localizedDescription
                    pendingQuestion = nil
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
            pendingQuestion = nil
            isQuestionFieldFocused = false
            isFollowUpFieldFocused = false
            isEnteringQuestion = false
            isWorking = false
            activeAction = nil
            errorText = nil
            saveErrorText = nil
            isSavedAsNote = false
            savedNoteID = nil
        }
    }

    private func closeResultCard() {
        resetForNewSelection()
        onDismiss()
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
        isMultiTurnConversation ? 480 : 260
    }

    private var conversationViewportHeight: CGFloat {
        min(conversationContentHeight, conversationMaximumHeight)
    }

    private var hasConversationAreaContent: Bool {
        conversation.isEmpty == false
            || pendingQuestion != nil
            || isWorking
            || errorText != nil
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

private struct SelectionAssistantConversationHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
