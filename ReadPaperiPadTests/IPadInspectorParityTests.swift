import PDFKit
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import ReadPaperiPad

final class IPadInspectorParityTests: XCTestCase {
    @MainActor
    func testWritingActionsUseTheSelectedLanguage() {
        let original = AppLocalization.currentLanguageOverride()
        defer { AppLocalization.setLanguageOverride(original) }
        for (language, preview, share) in [("en", "Preview Writing", "Share Writing"), ("zh-Hans", "预览写作稿", "分享写作稿")] {
            AppLocalization.setLanguageOverride(language)
            XCTAssertEqual(AppLocalization.localized("Preview Writing"), preview)
            XCTAssertEqual(AppLocalization.localized("Share Writing"), share)
        }
    }

    @MainActor
    func testWritingKeepsCaretAndSavesCitationAcrossInspectorTabs() async throws {
        let fixture = try writingFixture()
        defer { fixture.remove() }
        let writing = try fixture.library.createWriting(markdown: "# Review\n\nFirst paragraph.\n\nLast paragraph.")
        let document = try fixture.center.document(for: writing.id)
        document.selection = NSRange(location: 12, length: 0)
        let citation = PaperCitation(paperID: UUID(), pageIndex: 3, quotePrefix: "原文")
        document.apply(WritingInsertion.block(
            PaperCitation.quoteMarkdown(quote: "原文", label: "Author, p. 4", citation: citation),
            in: document.markdown, at: document.selection.location
        ))
        let caret = document.selection
        let sameDocument = try fixture.center.document(for: writing.id)
        XCTAssertTrue(sameDocument === document)
        XCTAssertEqual(sameDocument.selection, caret)
        try await Task.sleep(for: .milliseconds(950))
        XCTAssertEqual(try fixture.library.markdown(for: writing.id), document.markdown)
        XCTAssertEqual(fixture.library.writings(citing: citation.paperID).map(\.id), [writing.id])
        XCTAssertFalse(document.hasUnsavedChanges)
    }

    @MainActor
    func testDeletingWritingCancelsPendingSaveAndDoesNotRecreateFiles() async throws {
        let fixture = try writingFixture()
        defer { fixture.remove() }
        let writing = try fixture.library.createWriting(markdown: "Before")
        let document = try fixture.center.document(for: writing.id)
        document.markdown = "Unsaved edit"
        let url = try XCTUnwrap(fixture.library.directoryURL(for: writing.id))
        try fixture.library.deleteWriting(writing.id)
        fixture.center.close(writing.id)
        try await Task.sleep(for: .milliseconds(950))
        document.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(fixture.library.currentWritingID)
    }

    @MainActor
    func testCitationSwitchRestoresThenNavigatesWithoutClampingToPartialTranslation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: ReadPaperModelStore.schema,
            configurations: ModelConfiguration(schema: ReadPaperModelStore.schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let first = Paper(title: "First")
        let second = Paper(title: "Second")
        context.insert(first)
        context.insert(second)
        var allAttachments: [PaperAttachment] = []
        for paper in [first, second] {
            for (kind, count): (AttachmentKind, Int) in [(.pdf, 6), (.translatedPDF, 2)] {
                let url = directory.appendingPathComponent("\(paper.id)-\(kind.rawValue).pdf")
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
                try renderer.writePDF(to: url) { context in
                    for page in 0..<count {
                        context.beginPage()
                        ("Page \(page + 1)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: nil)
                    }
                }
                let attachment = PaperAttachment(paperID: paper.id, kind: kind, source: .generated,
                                                 filename: url.lastPathComponent, filePath: url.path)
                context.insert(attachment)
                allAttachments.append(attachment)
            }
            try ReadingStateStore().upsertState(for: paper.id, attachmentID: nil, readerMode: .bilingualPDF,
                                               pageIndex: 4, scrollRatio: 0, in: context)
        }
        let model = ReaderModel(paper: first, attachments: allAttachments)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ReaderHarness(model: model).modelContainer(container))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        var panes = descendants(PDFView.self, in: window)
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.first?.document?.index(for: try XCTUnwrap(panes.first?.currentPage)), 4)
        XCTAssertEqual(panes.last?.document?.index(for: try XCTUnwrap(panes.last?.currentPage)), 1)

        model.paper = second
        model.request = PaperCitation(paperID: second.id, pageIndex: 3).navigationRequest()
        try await Task.sleep(for: .milliseconds(500))
        panes = descendants(PDFView.self, in: window)
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.first?.document?.index(for: try XCTUnwrap(panes.first?.currentPage)), 3)
        XCTAssertEqual(panes.last?.document?.index(for: try XCTUnwrap(panes.last?.currentPage)), 1)
        XCTAssertEqual(try ReadingStateStore().state(for: second.id, in: context)?.pageIndex, 3)
    }

    @MainActor
    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        if let match = view as? T { return [match] }
        return view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor
    private func writingFixture() throws -> WritingFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "IPadInspectorParityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let library = WritingLibrary(store: WritingStore(
            fileStore: PaperFileStore(applicationSupportDirectory: directory), movesDeletedWritingsToTrash: false
        ), userDefaults: defaults)
        library.loadIfNeeded()
        return WritingFixture(directory: directory, defaults: defaults, suite: suite,
                              library: library, center: IPadWritingDocumentCenter(library: library))
    }
}

@MainActor
private struct WritingFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let library: WritingLibrary
    let center: IPadWritingDocumentCenter
    func remove() {
        center.saveAll()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class ReaderModel: ObservableObject {
    @Published var paper: Paper
    let attachments: [PaperAttachment]
    @Published var request: NoteNavigationRequest?
    @Published var selection: NoteSelectionContext?
    init(paper: Paper, attachments: [PaperAttachment]) { self.paper = paper; self.attachments = attachments }
}

private struct ReaderHarness: View {
    @ObservedObject var model: ReaderModel
    var body: some View {
        IPadReaderPaneView(paper: model.paper,
                           attachments: model.attachments.filter { $0.paperID == model.paper.id },
                           settings: nil, noteSelectionContext: $model.selection,
                           noteNavigationRequest: $model.request, onToggleInspector: {})
    }
}
