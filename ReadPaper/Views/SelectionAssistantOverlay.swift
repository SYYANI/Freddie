import AppKit
import SwiftUI

struct SelectionAssistantOverlay: View {
    @Environment(\.localizationBundle) private var bundle

    let selection: NoteSelectionContext
    let perform: @MainActor (SelectionAssistantRequest) async throws -> String
    let saveAsNote: @MainActor (NoteSelectionContext, String) throws -> Void

    @State private var question = ""
    @State private var isEnteringQuestion = false
    @State private var isWorking = false
    @State private var activeAction: SelectionAssistantAction?
    @State private var resultText: String?
    @State private var errorText: String?
    @State private var saveErrorText: String?
    @State private var isSavedAsNote = false
    @State private var task: Task<Void, Never>?
    @State private var submittedQuestion: String?
    @FocusState private var isQuestionFieldFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            if activeAction != nil {
                resultCard
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }

            actionCapsule
        }
        .frame(maxWidth: 390)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .animation(.easeOut(duration: 0.18), value: activeAction)
        .animation(.easeOut(duration: 0.18), value: isEnteringQuestion)
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

                if let resultText, resultText.isEmpty == false {
                    Button {
                        saveResultAsNote(resultText)
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
                        NSPasteboard.general.setString(resultText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Copy", bundle: bundle))
                }

                Button {
                    task?.cancel()
                    activeAction = nil
                    resultText = nil
                    errorText = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close", bundle: bundle))
            }
            .foregroundStyle(activeAction == .translate ? Color.orange : Color.accentColor)

            if activeAction == .ask,
               let submittedQuestion = submittedQuestion,
               submittedQuestion.isEmpty == false {
                Text(AppLocalization.format("Question: %@", bundle: bundle, submittedQuestion))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loadingText)
                        .foregroundStyle(.secondary)
                }
            } else if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let resultText {
                ScrollView {
                    Text(resultText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 260)
            }

            if let saveErrorText {
                Text(saveErrorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 14))
        .lineSpacing(3)
        .padding(16)
        .frame(maxWidth: 370, alignment: .leading)
        .selectionAssistantMaterial(cornerRadius: 14)
    }

    private func actionButton(
        _ action: SelectionAssistantAction,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            if action == .ask {
                isEnteringQuestion = true
                Task { @MainActor in
                    isQuestionFieldFocused = true
                }
            } else {
                run(action: action, question: nil)
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
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        submittedQuestion = normalized
        isEnteringQuestion = false
        run(action: .ask, question: normalized)
    }

    private func run(action: SelectionAssistantAction, question: String?) {
        task?.cancel()
        activeAction = action
        resultText = nil
        errorText = nil
        saveErrorText = nil
        isSavedAsNote = false
        isWorking = true

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
                resultText = response
            } catch is CancellationError {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                errorText = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func resetForNewSelection() {
        task?.cancel()
        task = nil
        question = ""
        submittedQuestion = nil
        isQuestionFieldFocused = false
        isEnteringQuestion = false
        isWorking = false
        activeAction = nil
        resultText = nil
        errorText = nil
        saveErrorText = nil
        isSavedAsNote = false
    }

    private func saveResultAsNote(_ result: String) {
        guard isSavedAsNote == false else { return }
        do {
            try saveAsNote(selection, result)
            saveErrorText = nil
            isSavedAsNote = true
        } catch {
            saveErrorText = AppLocalization.format(
                "Unable to save note: %@",
                bundle: bundle,
                error.localizedDescription
            )
        }
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
