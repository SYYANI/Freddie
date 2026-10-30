import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Keeps the Markdown and caret alive when the inspector switches back to Paper.
@MainActor
@Observable
final class IPadWritingDocument {
    let id: UUID
    var markdown: String {
        didSet {
            guard !isApplyingSync else { return }
            guard markdown != oldValue else { return }
            hasUnsavedChanges = true
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(800))
                    self?.save()
                } catch {}
            }
        }
    }
    var selection: NSRange
    var focusRequest = 0
    private(set) var hasUnsavedChanges = false
    @ObservationIgnored weak var textView: UITextView?
    @ObservationIgnored private let library: WritingLibrary
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingSync = false

    init(id: UUID, markdown: String, library: WritingLibrary) {
        self.id = id
        self.markdown = markdown
        self.library = library
        selection = NSRange(location: (markdown as NSString).length, length: 0)
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges else { return }
        if library.save(markdown: markdown, for: id) { hasUnsavedChanges = false }
    }

    func discardPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        hasUnsavedChanges = false
    }

    func reloadAfterSync(_ text: String) {
        guard !hasUnsavedChanges, textView?.markedTextRange == nil, text != markdown else { return }
        isApplyingSync = true
        markdown = text
        isApplyingSync = false
        selection = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        textView?.text = text
        textView?.selectedRange = selection
        textView?.undoManager?.removeAllActions()
    }

    func apply(_ edit: WritingEdit) {
        let text = markdown as NSString
        let location = min(max(0, edit.range.location), text.length)
        let range = NSRange(location: location, length: min(edit.range.length, text.length - location))
        // Use UIKit's editing path when visible so the change participates in undo.
        if let textView,
           let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
           let end = textView.position(from: start, offset: range.length),
           let textRange = textView.textRange(from: start, to: end) {
            textView.unmarkText()
            textView.replace(textRange, withText: edit.replacement)
            markdown = textView.text
            textView.selectedRange = edit.selectionAfter
        } else {
            markdown = text.replacingCharacters(in: range, with: edit.replacement)
        }
        selection = edit.selectionAfter
    }
}

@MainActor
final class IPadWritingDocumentCenter {
    static let shared = IPadWritingDocumentCenter(library: .shared)
    let library: WritingLibrary
    private var documents: [UUID: IPadWritingDocument] = [:]

    init(library: WritingLibrary) { self.library = library }

    func document(for id: UUID) throws -> IPadWritingDocument {
        if let document = documents[id] { return document }
        let document = IPadWritingDocument(id: id, markdown: try library.markdown(for: id), library: library)
        documents[id] = document
        return document
    }

    func saveAll() { documents.values.forEach { $0.save() } }

    var syncBlockedWritingIDs: Set<UUID> {
        Set(documents.values.filter { $0.hasUnsavedChanges || $0.textView?.markedTextRange != nil }.map(\.id))
    }

    func reloadAfterSync(_ ids: Set<UUID>) {
        for id in ids {
            guard let document = documents[id], !document.hasUnsavedChanges else { continue }
            if let markdown = try? library.markdown(for: id) { document.reloadAfterSync(markdown) }
            else { close(id) }
        }
    }

    func close(_ id: UUID) {
        documents.removeValue(forKey: id)?.discardPendingSave()
    }
}

struct IPadWritingPaneView: View {
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @Environment(\.scenePhase) private var scenePhase
    var library: WritingLibrary = .shared
    var center: IPadWritingDocumentCenter = .shared
    var onOpenCitation: (PaperCitation, String?) -> Void
    @State private var writingPendingDeletion: WritingMetadata?
    @State private var writingBeingRenamed: WritingMetadata?
    @State private var newTitle = ""
    @State private var errorMessage: String?
    @State private var isChoosingImages = false
    @State private var isPreviewing = false
    @State private var isShowingRecentlyDeleted = false

    var body: some View {
        VStack(spacing: 0) {
            if let writing = library.currentWriting {
                header(writing)
                Divider()
                if let document = try? center.document(for: writing.id) {
                    if isPreviewing {
                        ScrollView {
                            IPadWritingPreview(markdown: document.markdown, baseURL: library.directoryURL(for: writing.id))
                                .padding(16)
                        }
                        .environment(\.openURL, OpenURLAction { url in
                            guard let citation = PaperCitation(linkDestination: url.absoluteString) else {
                                return .systemAction
                            }
                            onOpenCitation(citation, nil)
                            return .handled
                        })
                    } else {
                        IPadWritingEditor(document: document, usesPaperTypography: displayAppearance == .paper)
                            .id(writing.id)
                    }
                } else {
                    ContentUnavailableView {
                        Label(String(localized: "Writing Unavailable", bundle: bundle), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("The writing’s file could not be read.", bundle: bundle)
                    }
                }
                Divider()
                footer(writing)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("No Writings Yet", bundle: bundle).foregroundStyle(.secondary)
                    Button(String(localized: "New Writing", bundle: bundle), action: createWriting)
                    Button(String(localized: "Recently Deleted", bundle: bundle)) {
                        isShowingRecentlyDeleted = true
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { library.loadIfNeeded() }
        .onDisappear { center.saveAll() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { center.saveAll() }
        }
        .confirmationDialog(
            String(localized: "Delete Writing?", bundle: bundle),
            isPresented: Binding(get: { writingPendingDeletion != nil }, set: { if !$0 { writingPendingDeletion = nil } }),
            presenting: writingPendingDeletion
        ) { writing in
            Button(String(localized: "Move to Recently Deleted", bundle: bundle), role: .destructive) {
                do {
                    try library.deleteWriting(writing.id)
                    center.close(writing.id)
                } catch { errorMessage = error.localizedDescription }
                writingPendingDeletion = nil
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { writing in
            Text(AppLocalization.format(
                "“%@” will move to Recently Deleted. You can restore it later.", bundle: bundle, title(writing)
            ))
        }
        .alert(
            String(localized: "Rename Writing", bundle: bundle),
            isPresented: Binding(get: { writingBeingRenamed != nil }, set: { if !$0 { writingBeingRenamed = nil } }),
            presenting: writingBeingRenamed
        ) { writing in
            TextField(String(localized: "Title", bundle: bundle), text: $newTitle)
            Button(String(localized: "Rename", bundle: bundle)) { rename(writing) }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { _ in
            Text("The title is the writing’s first line, so renaming changes that line.", bundle: bundle)
        }
        .alert(String(localized: "Unable to Update Writing", bundle: bundle), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .sheet(isPresented: $isShowingRecentlyDeleted) {
            IPadDeletedWritingsView(library: library)
        }
        .fileImporter(isPresented: $isChoosingImages, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                guard let id = library.currentWritingID else { return }
                let document = try center.document(for: id)
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let path = try library.importImage(.file(url), into: id)
                    document.apply(WritingInsertion.block(
                        WritingImagePath.markdown(alt: url.deletingPathExtension().lastPathComponent, relativePath: path),
                        in: document.markdown, at: document.selection.location
                    ))
                }
                document.save()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func header(_ writing: WritingMetadata) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(library.writings) { entry in
                    Button {
                        center.saveAll()
                        library.selectWriting(entry.id)
                    } label: {
                        if entry.id == writing.id {
                            Label(title(entry), systemImage: "checkmark")
                        } else { Text(title(entry)) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(title(writing)).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .foregroundStyle(.primary)
            Spacer(minLength: 8)
            InspectorIconButton(title: String(localized: "New Writing", bundle: bundle), systemImage: "square.and.pencil", action: createWriting)
            Menu {
                Button(String(localized: "Rename…", bundle: bundle)) {
                    newTitle = writing.title
                    writingBeingRenamed = writing
                }
                Button(String(localized: "Insert Image…", bundle: bundle)) { isChoosingImages = true }
                Toggle(String(localized: "Preview Writing", bundle: bundle), isOn: $isPreviewing)
                if let url = library.markdownURL(for: writing.id) {
                    ShareLink(item: url) {
                        Label(String(localized: "Share Writing", bundle: bundle), systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                Button(String(localized: "Recently Deleted", bundle: bundle)) {
                    center.saveAll()
                    isShowingRecentlyDeleted = true
                }
                Button(String(localized: "Delete Writing…", bundle: bundle), role: .destructive) {
                    center.saveAll()
                    writingPendingDeletion = writing
                }
            } label: {
                Label(String(localized: "More", bundle: bundle), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func footer(_ writing: WritingMetadata) -> some View {
        HStack(spacing: 6) {
            if let error = library.lastErrorMessage {
                Text(error).foregroundStyle(.red).lineLimit(2)
            } else {
                Text(AppLocalization.format("Words: %lld", bundle: bundle, writing.wordCount))
                if !writing.citedPaperIDs.isEmpty {
                    Text(verbatim: "·")
                    Text(AppLocalization.format("Cited papers: %lld", bundle: bundle, writing.citedPaperIDs.count))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func title(_ writing: WritingMetadata) -> String {
        writing.title.isEmpty ? String(localized: "Untitled Writing", bundle: bundle) : writing.title
    }

    private func createWriting() {
        do {
            center.saveAll()
            let writing = try library.createWriting()
            try center.document(for: writing.id).focusRequest += 1
            isPreviewing = false
        } catch { errorMessage = error.localizedDescription }
    }

    private func rename(_ writing: WritingMetadata) {
        defer { writingBeingRenamed = nil }
        do {
            let document = try center.document(for: writing.id)
            if let edit = WritingTitle.renaming(document.markdown, to: newTitle, selection: document.selection) {
                document.apply(edit)
                document.save()
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct IPadDeletedWritingsView: View {
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.dismiss) private var dismiss
    let library: WritingLibrary
    @State private var writings: [WritingMetadata] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if writings.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No Deleted Writings", bundle: bundle), systemImage: "trash")
                    }
                } else {
                    List {
                        Section {
                            ForEach(writings) { writing in
                                HStack {
                                    Text(writing.title.isEmpty
                                         ? String(localized: "Untitled Writing", bundle: bundle) : writing.title)
                                    Spacer()
                                    Button(String(localized: "Restore", bundle: bundle)) {
                                        do {
                                            try library.restoreWriting(writing.id)
                                            dismiss()
                                        } catch { errorMessage = error.localizedDescription }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        } footer: {
                            Text("Deleted writings and their images stay on this iPad until you restore them or remove the app.", bundle: bundle)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Recently Deleted", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: bundle)) { dismiss() }
                }
            }
            .onAppear {
                do { writings = try library.deletedWritings() }
                catch { errorMessage = error.localizedDescription }
            }
            .alert(String(localized: "Unable to Update Writing", bundle: bundle), isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }
}

/// Images stay relative in the file; the preview resolves them from the writing's folder.
private struct IPadWritingPreview: View {
    let markdown: String
    let baseURL: URL?

    private enum Part {
        case text(String)
        case image(UIImage)
    }

    private struct PartsSource: Equatable {
        var markdown: String
        var baseURL: URL?
    }

    /// Parsed once per Markdown change: the body is re-evaluated on unrelated
    /// observation changes, and each image would otherwise be read from disk again.
    @State private var parts: [Part] = []
    @State private var partsSource: PartsSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parts.indices, id: \.self) { index in
                switch parts[index] {
                case .text(let text):
                    ReadPaperMarkdownView(markdown: text)
                case .image(let image):
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 560)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refreshParts)
        .onChange(of: PartsSource(markdown: markdown, baseURL: baseURL)) { _, _ in refreshParts() }
    }

    private func refreshParts() {
        let source = PartsSource(markdown: markdown, baseURL: baseURL)
        guard partsSource != source else { return }
        partsSource = source
        parts = makeParts()
    }

    private func makeParts() -> [Part] {
        let source = markdown as NSString
        var parts: [Part] = []
        var fence: MarkdownLiveSyntax.FenceState?
        var offset = 0
        var textStart = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let parsed = MarkdownLiveSyntax.parse(source.substring(with: range).trimmingCharacters(in: .newlines), fence: fence)
            fence = parsed.fence
            for span in parsed.line.spans {
                guard case let .image(destination, _) = span.kind,
                      let url = WritingImagePath.fileURL(forDestination: destination, relativeTo: baseURL),
                      let image = UIImage(contentsOfFile: url.path) else { continue }
                let imageStart = range.location + span.range.location
                if imageStart > textStart {
                    parts.append(.text(source.substring(with: NSRange(location: textStart, length: imageStart - textStart))))
                }
                parts.append(.image(image))
                textStart = range.location + NSMaxRange(span.range)
            }
            offset = NSMaxRange(range)
        }
        if textStart < source.length { parts.append(.text(source.substring(from: textStart))) }
        return parts
    }
}

private struct IPadWritingEditor: UIViewRepresentable {
    let document: IPadWritingDocument
    let usesPaperTypography: Bool

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.alwaysBounceVertical = true
        view.text = document.markdown
        view.selectedRange = document.selection
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        document.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.markedTextRange == nil, view.text != document.markdown {
            view.text = document.markdown
            view.selectedRange = document.selection
        }
        let font = UIFont.preferredFont(forTextStyle: .body)
        if usesPaperTypography, let descriptor = font.fontDescriptor.withDesign(.serif) {
            view.font = UIFont(descriptor: descriptor, size: font.pointSize)
        } else { view.font = font }
        if context.coordinator.lastFocusRequest != document.focusRequest {
            context.coordinator.lastFocusRequest = document.focusRequest
            DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
        }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.document.selection = view.selectedRange
        coordinator.document.save()
        if coordinator.document.textView === view { coordinator.document.textView = nil }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let document: IPadWritingDocument
        var lastFocusRequest = -1
        init(document: IPadWritingDocument) { self.document = document }
        func textViewDidChange(_ textView: UITextView) {
            document.markdown = textView.text
            document.selection = textView.selectedRange
        }
        func textViewDidChangeSelection(_ textView: UITextView) { document.selection = textView.selectedRange }
        func textViewDidEndEditing(_ textView: UITextView) { document.save() }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", textView.markedTextRange == nil else { return true }
            let preceding = (textView.text as NSString).substring(to: range.location)
            let lines = preceding.components(separatedBy: "\n")
            var fence: MarkdownLiveSyntax.FenceState?
            for line in lines.dropLast() { fence = MarkdownLiveSyntax.parse(line, fence: fence).fence }
            guard let edit = WritingContinuation.newline(
                in: textView.text, selection: range, isInCodeBlock: fence != nil
            ) else { return true }
            document.apply(edit)
            return false
        }
    }
}
