#if os(macOS)
import AppKit
import PDFKit
import WebKit

enum HTMLPDFExportError: LocalizedError {
    case loadingTimedOut
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .loadingTimedOut:
            AppLocalization.localized("The HTML content took too long to load. Please try exporting again.")
        case .renderingFailed:
            AppLocalization.localized("Unable to render the HTML content as a PDF.")
        }
    }
}

/// Uses a separate web view so printing cannot change the reader's position or display mode.
@MainActor
final class HTMLPDFExporter: NSObject, WKNavigationDelegate {
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeout: Task<Void, Never>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    func export(
        sourceURL: URL,
        displayMode: TranslationDisplayMode,
        fontSize: Double,
        destinationURL: URL
    ) async throws {
        // Check early: WebKit does not consistently report missing local files as navigation errors.
        _ = try Data(contentsOf: sourceURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if !HTMLTeXRendering.userScript.isEmpty {
            configuration.userContentController.addUserScript(
                WKUserScript(source: HTMLTeXRendering.userScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 960),
            configuration: configuration
        )
        webView.appearance = NSAppearance(named: .aqua)
        webView.navigationDelegate = self
        defer {
            loadTimeout?.cancel()
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            loadTimeout = Task { [weak self, weak webView] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.finishLoading(.failure(HTMLPDFExportError.loadingTimedOut))
                webView?.stopLoading()
            }
            webView.loadFileURL(sourceURL, allowingReadAccessTo: sourceURL.deletingLastPathComponent())
        }
        try Task.checkCancellation()
        let resourcesReady = try await webView.callAsyncJavaScript(
            """
            document.documentElement.setAttribute('data-rp-display-mode', mode);
            const style = document.createElement('style');
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
            const images = Array.from(document.images);
            images.forEach(image => { image.loading = 'eager'; });
            return await Promise.race([
                Promise.all([
                    document.fonts.ready,
                    ...images.map(image => image.decode().catch(() => {}))
                ]).then(() => true),
                new Promise(resolve => setTimeout(() => resolve(false), 15000))
            ]);
            """,
            arguments: ["mode": displayMode.rawValue, "css": Self.printCSS(fontSize: fontSize)],
            in: nil,
            contentWorld: .page
        )
        guard resourcesReady as? Bool == true else { throw HTMLPDFExportError.loadingTimedOut }
        try Task.checkCancellation()

        // Print to a temporary file first, so a failed render never truncates an existing export.
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let printInfo = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: temporaryURL
        ])
        printInfo.paperSize = NSSize(width: 595.28, height: 841.89) // A4, in points.
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.isHorizontallyCentered = false
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit computes pagination asynchronously; run() can deadlock its main-thread callback.
        let printWindow = NSWindow(
            contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        printWindow.contentView = webView
        operation.canSpawnSeparateThread = true
        let success = await withCheckedContinuation { continuation in
            printContinuation = continuation
            operation.runModal(
                for: printWindow,
                delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
        // Keep the offscreen print host alive until WebKit's print callback completes.
        withExtendedLifetime(printWindow) {}
        try Task.checkCancellation()
        guard success,
              let document = PDFDocument(url: temporaryURL), document.pageCount > 0 else {
            throw HTMLPDFExportError.renderingFailed
        }
        let data = try Data(contentsOf: temporaryURL)
        let hasSecurityScope = destinationURL.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { destinationURL.stopAccessingSecurityScopedResource() } }
        try data.write(to: destinationURL, options: .atomic)
    }

    private static func printCSS(fontSize: Double) -> String {
        """
        \(HTMLReaderTypography.css(fontSize: fontSize))
        html[data-rp-display-mode='original'] .rp-translation-block { display: none !important; }
        html[data-rp-display-mode='translated'] [data-rp-source='true'] { display: none !important; }
        :root { color-scheme: light; }
        html, body { background: white !important; color: black !important; }
        body { margin: 0 !important; }
        .rp-readability-shell { max-width: none !important; margin: 0 !important; padding: 0 !important; }
        img, svg { max-width: 100% !important; height: auto; }
        pre { white-space: pre-wrap !important; overflow-wrap: anywhere; }
        h1, h2, h3, h4, h5, h6 { break-after: avoid; }
        img, tr { break-inside: avoid; }
        p { orphans: 3; widows: 3; }
        """
    }

    @objc nonisolated private func printOperationDidRun(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor in
            let continuation = self.printContinuation
            self.printContinuation = nil
            continuation?.resume(returning: success)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(.failure(HTMLPDFExportError.renderingFailed))
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        loadTimeout?.cancel()
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume(with: result)
    }
}
#endif
