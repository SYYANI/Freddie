import Foundation
import Observation

@MainActor @Observable
final class DocumentOutlineModel {
    var isPresented = false
    var isPinned = false
    private(set) var isLoading = false
    private(set) var isOrganizing = false
    private(set) var isGenerating = false
    private(set) var cache: DocumentOutlineCache?
    private(set) var htmlEntries: [DocumentOutlineEntry] = []
    private(set) var currentPDFID: String?
    private(set) var currentHTMLID: String?
    func currentID(isHTML: Bool) -> String? { isHTML ? currentHTMLID : currentPDFID }
    var errorMessage: String?
    @ObservationIgnored private var paperID: UUID?
    @ObservationIgnored private var request: DocumentOutlineRequest?
    @ObservationIgnored private var operation: Task<Void, Never>?
    /// Changes with the paper or PDF request; results for an older one are dropped.
    @ObservationIgnored private var identity = UUID()
    @ObservationIgnored private var loadToken = UUID()
    /// Written on every scroll tick, so it must not notify observers.
    @ObservationIgnored private var location = (page: 0, fraction: 1.0)

    var variants: [DocumentOutlineVariant] { cache?.variants ?? [] }
    var source: DocumentOutlineSource? { cache?.selectedSource }
    var isBusy: Bool { isLoading || isOrganizing || isGenerating }
    var canGenerateAutomatic: Bool { cache?.canGenerateAutomatic == true && !isBusy }
    var canOrganize: Bool { cache?.canOrganize == true && !isBusy }
    func entries(isHTML: Bool) -> [DocumentOutlineEntry] {
        if isHTML { return htmlEntries }
        return cache?.variants.first { $0.source == cache?.selectedSource }?.entries ?? []
    }

    /// Tracks the reader's paper and PDF; the outline is only extracted once `fetch` is
    /// true, i.e. while the panel is shown. HTML entries belong to the HTML reader and are
    /// left alone: its page may report them before this runs.
    func load(_ request: DocumentOutlineRequest?, paperID: UUID?, fetch: Bool) async {
        if paperID != self.paperID {
            cache = nil; currentPDFID = nil
            isPresented = false
        }
        if paperID != self.paperID || request != self.request {
            operation?.cancel(); identity = UUID()
            isOrganizing = false; isGenerating = false
            if request?.pdfURL != self.request?.pdfURL { cache = nil; currentPDFID = nil }
        }
        self.paperID = paperID
        self.request = request
        guard fetch, let request else { return }
        let id = identity
        let token = UUID()
        loadToken = token
        isLoading = true; errorMessage = nil
        defer { if loadToken == token { isLoading = false } }
        do {
            let result = try await DocumentOutlineService.shared.load(request)
            try Task.checkCancellation()
            guard loadToken == token, identity == id else { return }
            apply(result)
        } catch is CancellationError {} catch {
            if loadToken == token, identity == id { errorMessage = error.localizedDescription }
        }
    }

    func updateHTML(_ entries: [DocumentOutlineEntry], currentID: String?) {
        if htmlEntries != entries { htmlEntries = entries }
        if currentHTMLID != currentID { currentHTMLID = currentID }
    }
    func updatePDFLocation(page: Int, fraction: Double = 1) {
        location = (page, fraction)
        let id = DocumentOutlineEntry.current(in: entries(isHTML: false), page: page, fraction: fraction)
        if currentPDFID != id { currentPDFID = id }
    }
    func select(_ source: DocumentOutlineSource) {
        guard let request, !isBusy else { return }
        let generates = !variants.contains { $0.source == source }
        guard !generates || (source == .automatic && canGenerateAutomatic) else { return }
        // An existing variant shows at once; persistence runs away from the UI thread.
        if !generates { apply(cache.map { var cache = $0; cache.selectedSource = source; return cache }) }
        let id = identity
        operation?.cancel(); errorMessage = nil
        if generates { isGenerating = true }
        operation = Task {
            defer { if identity == id { isGenerating = false } }
            do {
                let result = try await DocumentOutlineService.shared.select(source, request: request)
                guard !Task.isCancelled, identity == id else { return }
                apply(result)
                if result.selectedSource != source { errorMessage = OutlineError.noCandidates.localizedDescription }
            } catch is CancellationError {} catch { if identity == id { errorMessage = error.localizedDescription } }
        }
    }
    func organize(route: ResolvedLLMModelRoute) {
        guard let request, !isBusy else { return }
        let id = identity
        operation?.cancel(); isOrganizing = true; errorMessage = nil
        operation = Task {
            defer { if identity == id { isOrganizing = false } }
            do {
                let result = try await DocumentOutlineService.shared.organize(request, route: route)
                try Task.checkCancellation()
                guard identity == id else { return }
                apply(result)
            } catch is CancellationError {} catch { if identity == id { errorMessage = error.localizedDescription } }
        }
    }
    func cancel() { operation?.cancel() }

    private func apply(_ result: DocumentOutlineCache?) {
        cache = result
        updatePDFLocation(page: location.page, fraction: location.fraction)
    }
}
