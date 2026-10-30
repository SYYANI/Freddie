import SwiftUI
import UniformTypeIdentifiers

struct LibrarySyncReaderObserver: ViewModifier {
    let activity: LibrarySyncReaderActivity
    var onFilesChanged: () -> Void
    @State private var readerID = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: activity, initial: true) { _, value in
                LibrarySyncActivity.shared.update(readerID, activity: value)
            }
            .onReceive(NotificationCenter.default.publisher(for: .librarySyncDidApply)) { notification in
                guard let id = activity.paperID, let ids = notification.userInfo?["paperIDs"] as? Set<UUID>, ids.contains(id) else { return }
                onFilesChanged()
            }
            .onDisappear { LibrarySyncActivity.shared.remove(readerID) }
    }
}

struct LibrarySyncSettingsView: View {
    @Environment(\.localizationBundle) private var bundle
    @State private var sync = LibrarySyncController.shared
    @State private var isImporting = false
    @State private var importError: String?
    @State private var confirmsHistoryReview = false
    @State private var confirmsDifferentServer = false
    @State private var pendingCredential: Data?
    @State private var pendingServer = ""

    var body: some View {
        Form {
            Section {
                if let configuration = sync.configuration {
                    LabeledContent(String(localized: "Server", bundle: bundle)) {
                        Text(configuration.baseURL.absoluteString).textSelection(.enabled)
                    }
                    LabeledContent(String(localized: "This device", bundle: bundle), value: configuration.label)
                    Toggle(String(localized: "Automatically sync", bundle: bundle), isOn: Binding(
                        get: { sync.configuration?.isEnabled == true }, set: { sync.setAutomaticSync($0) }
                    ))
                    .disabled(sync.isSyncing)
                    Button(String(localized: "Change Device Credential…", bundle: bundle)) { isImporting = true }
                        .disabled(sync.isSyncing)
                } else {
                    Button(String(localized: "Import Device Credential and Connect…", bundle: bundle)) { isImporting = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(sync.isSyncing)
                }
            } header: {
                ReadPaperInfoLabel(
                    String(localized: "Library Sync", bundle: bundle),
                    message: String(localized: "Syncs papers, files, annotations, reading positions, and writings across your own devices. Use a separate device credential on each device; your library stays available offline. Credentials stay in Keychain, and LLM API keys and device preferences are not synced. The sync server can read uploaded content.", bundle: bundle)
                )
            }
            if sync.configuration != nil || importError != nil || sync.errorMessage != nil {
                Section {
                    if sync.configuration != nil {
                        statusRow
                        if let date = sync.lastSuccess {
                            LabeledContent(String(localized: "Last successful sync", bundle: bundle)) {
                                Text(date, format: .dateTime.month().day().hour().minute())
                            }
                        }
                        if sync.pendingCount > 0 {
                            LabeledContent(String(localized: "Pending changes", bundle: bundle), value: sync.pendingCount.formatted())
                        }
                    }
                    if let error = importError ?? sync.errorMessage {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if sync.needsHistoryReview {
                        Button(String(localized: "Review Changed Server History…", bundle: bundle)) { confirmsHistoryReview = true }
                            .disabled(sync.isSyncing)
                    }
                }
            }
            if !sync.unavailableAttachments.isEmpty {
                Section {
                    ForEach(sync.unavailableAttachments) { item in
                        unavailableAttachmentRow(item)
                    }
                } header: {
                    ReadPaperInfoLabel(
                        String(localized: "Attachments Not Synced", bundle: bundle),
                        message: String(localized: "These attachments are skipped while their files are unavailable. Copies on other devices are kept, and a newer version from another device restores the file here.", bundle: bundle)
                    )
                }
            }
            if !sync.conflicts.isEmpty {
                Section {
                    ForEach(sync.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(conflict.title).font(.headline)
                            if conflict.remote.deleted {
                                Text("This item was deleted on another device.", bundle: bundle).foregroundStyle(.secondary)
                            } else if conflict.local == nil {
                                Text("This item was deleted here and changed on another device.", bundle: bundle).foregroundStyle(.secondary)
                            }
                            HStack {
                                resolutionButton("Keep This Device", conflict: conflict, choice: .thisDevice)
                                if conflict.remote.deleted {
                                    resolutionButton("Accept Deletion", conflict: conflict, choice: .server, role: .destructive)
                                } else {
                                    resolutionButton("Use Server Version", conflict: conflict, choice: .server)
                                }
                                if conflict.local?.kind == "writing" {
                                    resolutionButton("Keep Both Writings", conflict: conflict, choice: .keepBoth)
                                }
                            }
                        }
                        .disabled(sync.isSyncing)
                    }
                } header: {
                    ReadPaperInfoLabel(
                        String(localized: "Changes to Review", bundle: bundle),
                        message: String(localized: "Both versions are preserved until you choose. Replacing local changes also keeps a recovery copy on this device.", bundle: bundle)
                    )
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 else {
                    throw LibrarySyncError.message("The device credential is not valid.")
                }
                let data = try Data(contentsOf: url)
                importError = nil
                let credential = try JSONDecoder().decode(LibrarySyncCredential.self, from: data)
                let destination = try LibrarySyncClient.validatedBaseURL(credential.baseURL)
                // Freddie ships without a server: every new destination is confirmed before upload.
                if destination != sync.configuration?.baseURL {
                    pendingCredential = data; pendingServer = destination.absoluteString
                    confirmsDifferentServer = true
                } else {
                    connect(data)
                }
            } catch { importError = error.localizedDescription }
        }
        .confirmationDialog(String(localized: "Review Server History?", bundle: bundle), isPresented: $confirmsHistoryReview) {
            Button(String(localized: "Review Changes", bundle: bundle)) {
                sync.reviewChangedHistory()
                Task { await sync.syncNow() }
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: {
            Text("Your local library will be kept. Freddie will fetch the server history again and ask you to review conflicting changes.", bundle: bundle)
        }
        .alert(sync.configuration == nil
               ? String(localized: "Connect to This Server?", bundle: bundle)
               : String(localized: "Connect to a Different Server?", bundle: bundle),
               isPresented: $confirmsDifferentServer) {
            Button(String(localized: "Connect and Sync", bundle: bundle)) {
                if let data = pendingCredential { connect(data) }
                pendingCredential = nil
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) { pendingCredential = nil }
        } message: {
            Text(AppLocalization.format("This server will receive a copy of your paper library: %@", bundle: bundle, pendingServer))
        }
    }

    private func connect(_ data: Data) {
        Task {
            await sync.connect(credentialData: data)
            if sync.errorMessage == nil { await sync.syncNow() }
        }
    }

    /// Status and its action share one row; the bar appears only while files are transferring.
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if sync.isSyncing, sync.progressTotal == 0 {
                    ProgressView().controlSize(.small)
                }
                Text(String(localized: String.LocalizationValue(sync.statusKey), bundle: bundle))
                Spacer()
                Button {
                    Task { await sync.syncNow() }
                } label: {
                    Label(String(localized: "Sync Now", bundle: bundle), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.isSyncing)
            }
            if sync.isSyncing, sync.progressTotal > 0 {
                HStack {
                    ProgressView(value: Double(sync.progressCompleted), total: Double(sync.progressTotal))
                    Text(verbatim: "\(sync.progressCompleted.formatted()) / \(sync.progressTotal.formatted())")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func unavailableAttachmentRow(_ item: LibrarySyncUnavailableAttachment) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).font(.headline)
                if !item.paperTitle.isEmpty {
                    Text(item.paperTitle).foregroundStyle(.secondary).lineLimit(1)
                }
                Group {
                    switch item.reason {
                    case .missing: Text("Missing on this device", bundle: bundle)
                    case .unreadable: Text("Link or unreadable", bundle: bundle)
                    case .outsideLibrary: Text("Outside the Freddie library", bundle: bundle)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            #if os(macOS)
            if item.reason != .missing {
                Spacer()
                Button(String(localized: "Show in Finder", bundle: bundle)) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                .help(item.url.path)
            }
            #endif
        }
    }

    private func resolutionButton(_ key: String, conflict: LibrarySyncConflict, choice: LibrarySyncController.ConflictChoice, role: ButtonRole? = nil) -> some View {
        Button(String(localized: String.LocalizationValue(key), bundle: bundle), role: role) {
            Task { await sync.resolve(conflict.id, choice: choice) }
        }
    }
}
