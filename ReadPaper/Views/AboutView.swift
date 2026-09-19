import AppKit
import SwiftUI

enum AboutWindowMetrics {
    static let width: CGFloat = 490
    static let height: CGFloat = 247
    static let contentSize = NSSize(width: width, height: height)
}

struct AboutView: View {
    @Environment(\.localizationBundle) private var bundle

    private enum Metrics {
        static let columnHeight: CGFloat = 198
        static let topPadding: CGFloat = 48
        static let bottomPadding: CGFloat = 1
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Freddie"
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String(
            format: String(localized: "Version %@ (Build %@)", bundle: bundle),
            version,
            build
        )
    }

    private var copyrightDescription: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 SYYANI."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            identityColumn
                .frame(width: 181, height: Metrics.columnHeight)

            creditsColumn
                .frame(width: 255, height: Metrics.columnHeight)
        }
        .padding(.top, Metrics.topPadding)
        .padding(.leading, 18)
        .padding(.trailing, 20)
        .padding(.bottom, Metrics.bottomPadding)
        .frame(width: AboutWindowMetrics.width, height: AboutWindowMetrics.height)
        .background {
            AppWindowBackdrop(role: .about)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private var identityColumn: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 85, height: 85)

            Text(verbatim: appName)
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 8)

            Text(verbatim: versionDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 6)

            Text(verbatim: copyrightDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Spacer(minLength: 6)

            externalLink("github.com/SYYANI/Freddie", urlString: "https://github.com/SYYANI/Freddie")
                .font(.subheadline)
                .underline()
        }
        .frame(maxWidth: .infinity)
    }

    private var creditsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Credits", bundle: bundle)
                    .font(.headline)

                creditSection(String(localized: "Development", bundle: bundle)) {
                    externalLink("SYYANI", urlString: "https://github.com/SYYANI")
                }

                creditSection(String(localized: "Document Reading", bundle: bundle)) {
                    Text("PDFKit · SwiftSoup")
                    externalLink("swift-readability", urlString: "https://github.com/neolee/swift-readability")
                }

                creditSection(String(localized: "PDF Translation", bundle: bundle)) {
                    externalLink("BabelDOC", urlString: "https://github.com/funstory-ai/BabelDOC")
                }

                creditSection(String(localized: "Interface and Localization", bundle: bundle)) {
                    Text("SwiftUI · AppKit · SwiftData")
                    externalLink("Mercury", urlString: "https://github.com/neolee/mercury")
                }

                creditSection(String(localized: "Open Source License", bundle: bundle)) {
                    externalLink("GNU AGPL v3.0", urlString: "https://www.gnu.org/licenses/agpl-3.0.html")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private func creditSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .fontWeight(.medium)
            content()
        }
        .font(.body)
    }

    @ViewBuilder
    private func externalLink(_ title: String, urlString: String) -> some View {
        if let destination = URL(string: urlString) {
            Link(title, destination: destination)
        } else {
            Text(verbatim: title)
        }
    }
}
