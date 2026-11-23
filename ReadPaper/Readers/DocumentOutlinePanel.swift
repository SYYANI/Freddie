import SwiftUI

/// The same outline list is hosted by the macOS floating panel and the iPad popover.
struct DocumentOutlinePanel: View {
    @Environment(\.localizationBundle) private var bundle
    @Bindable var model: DocumentOutlineModel
    var isHTML: Bool
    var translatedLastPage: Int?
    var isTranslatedOnly = false
    var allowsPinning = true
    var onNavigate: (DocumentOutlineEntry) -> Void
    var onOrganize: () -> Void
    @State private var filter = ""
    @State private var expanded: Set<String> = []
    @State private var selection: String?
    @State private var showAIConfirmation = false
    @FocusState private var searchFocused: Bool

    private var currentID: String? { model.currentID(isHTML: isHTML) }
    private var entries: [DocumentOutlineEntry] { model.entries(isHTML: isHTML) }
    private var visible: [DocumentOutlineEntry] {
        if !filter.isEmpty { return entries.filter { $0.title.localizedStandardContains(filter) || ($0.translation?.localizedStandardContains(filter) ?? false) } }
        var hiddenBelow: Int?
        var rows: [DocumentOutlineEntry] = []
        for (index, entry) in entries.enumerated() {
            if let level = hiddenBelow, entry.level > level { continue }
            hiddenBelow = nil
            rows.append(entry)
            if hasChildren(at: index), !expanded.contains(entry.id) { hiddenBelow = entry.level }
        }
        return rows
    }
    private func hasChildren(at index: Int) -> Bool { index + 1 < entries.count && entries[index + 1].level > entries[index].level }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Contents", bundle: bundle).font(.headline)
                Spacer()
                if allowsPinning {
                    Button { model.isPinned.toggle() } label: {
                        Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    }
                    .help(String(localized: "Pin Contents", bundle: bundle))
                    .accessibilityLabel(String(localized: "Pin Contents", bundle: bundle))
                }
                Button { model.isPresented = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(String(localized: "Close Contents", bundle: bundle))
            }
            .buttonStyle(.plain)
            .padding(12)
            HStack {
                if isHTML {
                    Text(DocumentOutlineSource.html.title)
                } else {
                    Menu {
                        ForEach(model.variants) { variant in
                            Button { model.select(variant.source) } label: {
                                if model.source == variant.source { Label(variant.source.title, systemImage: "checkmark") }
                                else { Text(variant.source.title) }
                            }
                        }
                        if model.canGenerateAutomatic {
                            // Skipped while the embedded outline passed review; generated on request.
                            Button(DocumentOutlineSource.automatic.title) { model.select(.automatic) }
                        }
                        Divider()
                        Button { showAIConfirmation = true } label: {
                            Label(String(localized: "Organize with AI…", bundle: bundle), systemImage: "sparkles")
                        }
                        .disabled(!model.canOrganize)
                    } label: {
                        Text(model.source?.title ?? String(localized: "Outline source", bundle: bundle))
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(model.isBusy)
                }
                Spacer(minLength: 0)
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "Filter headings", bundle: bundle), text: $filter)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .onSubmit { navigateSelection() }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .readPaperFieldWell(isFocused: searchFocused)
            .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if visible.isEmpty {
                            Text(model.isLoading ? "Reading headings…" : filter.isEmpty ? "No reliable headings were found." : "No matching headings.", bundle: bundle)
                                .font(.callout).foregroundStyle(.secondary).padding(20)
                        }
                        ForEach(visible) { entry in row(entry).id(entry.id) }
                    }
                    .padding(6)
                }
                .onAppear {
                    revealCurrent()
                    proxy.scrollTo(currentID, anchor: .center)
                    searchFocused = true
                }
                .onChange(of: currentID) { _, id in
                    revealCurrent()
                    selection = id
                    if filter.isEmpty { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
                .onChange(of: entries) { _, _ in
                    resetExpansion(); revealCurrent()
                    proxy.scrollTo(currentID, anchor: .center)
                }
                .onChange(of: selection) { _, id in proxy.scrollTo(id, anchor: .center) }
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(10)
            }
            if model.isOrganizing || model.isGenerating {
                Button(String(localized: "Cancel", bundle: bundle)) { model.cancel() }.padding(8)
            }
        }
        .frame(minWidth: 240, idealWidth: 290, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { resetExpansion(); revealCurrent() }
        .onChange(of: filter) { _, _ in selection = visible.first?.id }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { navigateSelection(); return .handled }
        .onKeyPress(.escape) { model.isPresented = false; return .handled }
        .confirmationDialog(String(localized: "Organize with AI…", bundle: bundle), isPresented: $showAIConfirmation) {
            Button(String(localized: "Send heading candidates", bundle: bundle), action: onOrganize)
        } message: {
            Text("Heading candidates will be sent to your PDF model. API charges may apply.", bundle: bundle)
        }
    }

    private func row(_ entry: DocumentOutlineEntry) -> some View {
        let index = entries.firstIndex { $0.id == entry.id } ?? 0
        let untranslated = isTranslatedOnly && entry.isUntranslated(lastPage: translatedLastPage)
        return HStack(spacing: 4) {
            Button {
                if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            } label: {
                Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 24)
            }
            .buttonStyle(.plain)
            .opacity(hasChildren(at: index) && filter.isEmpty ? 1 : 0)
            .disabled(!hasChildren(at: index) || !filter.isEmpty)
            Button { selection = entry.id; navigate(entry) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(.system(size: 13)).multilineTextAlignment(.leading)
                        if let translation = entry.translation, !translation.isEmpty {
                            Text(translation).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                    if untranslated {
                        Text("Not translated", bundle: bundle).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let page = entry.pageIndex { Text("\(page + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                .foregroundStyle(untranslated ? Color.secondary : Color.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entry.pageIndex == nil && entry.anchor == nil)
        }
        .padding(.leading, CGFloat(min(6, max(0, entry.level - 1))) * 12)
        .padding(.vertical, 6).padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(
            entry.id == selection ? Color.accentColor.opacity(0.18) : entry.id == currentID ? Color.accentColor.opacity(0.09) : .clear
        ))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(entry.id == currentID ? .isSelected : [])
    }
    private func resetExpansion() {
        // Show level 1 and 2; deeper descendants stay collapsed.
        expanded = Set(entries.filter { $0.level < 2 }.map(\.id))
        selection = currentID
    }
    private func revealCurrent() {
        guard let index = entries.firstIndex(where: { $0.id == currentID }) else { return }
        var level = entries[index].level
        for entry in entries[..<index].reversed() where entry.level < level {
            expanded.insert(entry.id); level = entry.level
        }
        selection = currentID
    }
    private func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let index = selection.flatMap { id in visible.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : visible.count)
        selection = visible[min(max(index + delta, 0), visible.count - 1)].id
    }
    private func navigateSelection() { if let entry = visible.first(where: { $0.id == selection }) { navigate(entry) } }
    private func navigate(_ entry: DocumentOutlineEntry) {
        guard entry.pageIndex != nil || entry.anchor != nil else { return }
        onNavigate(entry)
        if !model.isPinned || !allowsPinning { model.isPresented = false }
    }
}
