import SwiftUI

/// The reader toolbar's centered control: the HTML/PDF format menu joined to the
/// original/bilingual/translated picker in one capsule. Display mode changes far more
/// often than format, so the format is the small menu at the leading end.
struct IPadReaderModeControl<Format: Hashable, Display: Hashable>: View {
    let formatLabel: String
    @Binding var format: Format
    let formats: [ReadPaperSegmentedPicker<Format>.Option]
    let displayLabel: String
    @Binding var display: Display
    let displays: [ReadPaperSegmentedPicker<Display>.Option]

    private var formatTitle: String {
        formats.first { $0.value == format }?.title ?? ""
    }

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Picker(formatLabel, selection: $format) {
                    ForEach(formats, id: \.value) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Text(formatTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: ReadPaperSegmentedPicker<Display>.toolbarSegmentHeight)
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(formatLabel)
            .accessibilityValue(formatTitle)

            IPadToolbarCapsuleDivider()

            ReadPaperSegmentedPicker(
                label: displayLabel,
                selection: $display,
                options: displays,
                placement: .toolbar,
                drawsCapsule: false
            )
        }
        .padding(ReadPaperSegmentedPicker<Display>.toolbarInset)
        .readPaperGlassEffect(in: Capsule())
        .fixedSize()
    }
}

/// Replaces `IPadReaderModeControl` while annotating a PDF, so tools are one tap away
/// instead of inside the annotation menu.
struct IPadPDFAnnotationPalette: View {
    @ObservedObject var session: PDFAnnotationSession
    @Environment(\.localizationBundle) private var bundle

    private static let toolSize = CGSize(width: 44, height: ReadPaperSegmentedPicker<Int>.toolbarSegmentHeight)

    var body: some View {
        HStack(spacing: 2) {
            toolButton(
                .browse,
                title: String(localized: "Select Text", bundle: bundle),
                systemImage: "hand.point.up.left"
            )
            toolButton(
                .ink,
                title: String(localized: "Freehand Draw", bundle: bundle),
                systemImage: "pencil.tip"
            )
            highlighter
            toolButton(
                .erase,
                title: String(localized: "Erase Annotation", bundle: bundle),
                systemImage: "eraser"
            )
            toolButton(
                .textNote,
                title: String(localized: "Place PDF Note", bundle: bundle),
                systemImage: "note.text.badge.plus"
            )

            IPadToolbarCapsuleDivider()

            colorMenu
            lineWidthMenu
        }
        .padding(ReadPaperSegmentedPicker<Int>.toolbarInset)
        .readPaperGlassEffect(in: Capsule())
        .fixedSize()
    }

    private func toolButton(_ mode: PDFInteractionMode, title: String, systemImage: String) -> some View {
        let isSelected = session.interactionMode == mode
        return Button {
            session.selectInteractionMode(mode)
        } label: {
            toolIcon(systemImage)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Marks up the current text selection: tap highlights, long press offers the other markups.
    private var highlighter: some View {
        Menu {
            Button {
                session.applyTextMarkup(.underline)
            } label: {
                Label(String(localized: "Underline Selection", bundle: bundle), systemImage: "underline")
            }
            Button {
                session.applyTextMarkup(.strikeOut)
            } label: {
                Label(String(localized: "Strike Through Selection", bundle: bundle), systemImage: "strikethrough")
            }
        } label: {
            toolIcon("highlighter")
        } primaryAction: {
            session.applyTextMarkup(.highlight)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(session.hasTextSelection ? Color.primary : Color.secondary.opacity(0.5))
        .disabled(session.hasTextSelection == false)
        .accessibilityLabel(String(localized: "Highlight Selection", bundle: bundle))
    }

    private var colorMenu: some View {
        Menu {
            ForEach(PDFAnnotationColorPreset.allCases) { preset in
                Button {
                    session.selectInkColor(preset)
                } label: {
                    Label(
                        colorTitle(preset),
                        systemImage: session.colorPreset == preset ? "checkmark.circle.fill" : "circle.fill"
                    )
                }
            }
        } label: {
            Circle()
                .fill(Self.swatchColor(session.colorPreset))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .frame(width: 20, height: 20)
                .frame(width: Self.toolSize.width, height: Self.toolSize.height)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(String(localized: "Annotation Color", bundle: bundle))
        .accessibilityValue(colorTitle(session.colorPreset))
    }

    private var lineWidthMenu: some View {
        Menu {
            lineWidthButton(PDFAnnotationLineWidthPreset.thin, title: String(localized: "Thin", bundle: bundle))
            lineWidthButton(PDFAnnotationLineWidthPreset.medium, title: String(localized: "Medium", bundle: bundle))
            lineWidthButton(PDFAnnotationLineWidthPreset.thick, title: String(localized: "Thick", bundle: bundle))
        } label: {
            toolIcon("lineweight")
                .foregroundStyle(.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(String(localized: "Drawing Width", bundle: bundle))
    }

    private func lineWidthButton(_ width: Double, title: String) -> some View {
        Button {
            session.lineWidth = width
        } label: {
            Label(title, systemImage: session.lineWidth == width ? "checkmark.circle.fill" : "line.diagonal")
        }
    }

    private func toolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .regular))
            .frame(width: Self.toolSize.width, height: Self.toolSize.height)
            .contentShape(Capsule())
    }

    private func colorTitle(_ preset: PDFAnnotationColorPreset) -> String {
        switch preset {
        case .yellow: String(localized: "Yellow", bundle: bundle)
        case .green: String(localized: "Green", bundle: bundle)
        case .blue: String(localized: "Blue", bundle: bundle)
        case .red: String(localized: "Red", bundle: bundle)
        case .purple: String(localized: "Purple", bundle: bundle)
        }
    }

    private static func swatchColor(_ preset: PDFAnnotationColorPreset) -> Color {
        let value = preset.color(for: .ink)
        return Color(red: value.red, green: value.green, blue: value.blue)
    }
}

/// Hairline between the parts of a toolbar capsule.
struct IPadToolbarCapsuleDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 3)
    }
}
