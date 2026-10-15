import SwiftUI

/// Floating capsule that shows a running translation where the toast appears:
/// a soft glow spreads across the capsule as progress grows, and the cancel button
/// is a round glass bubble at its trailing end that melts further into the capsule
/// as the run nears the end. When the run ends the bubble is fully absorbed and
/// carries the outcome mark, then the capsule fades out.
/// It names only the phase; the stage detail is in the tooltip.
struct TranslationActivityCapsule: View {
    enum Phase: Equatable {
        case running(isCancelling: Bool)
        case completed
        case cancelled
    }

    let phase: Phase
    /// The current stage, such as `Translating PDF with BabelDOC...`.
    let detail: String?
    /// Completed share in 0...1, or nil while the total is still unknown.
    let fraction: Double?
    /// Short count such as `12/48` or `35%`, shown while running.
    let summary: String?
    let onCancel: () -> Void

    @Environment(\.localizationBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @State private var isCancelHovered = false

    private static let height: CGFloat = 40
    /// Fixed, so the capsule keeps its size as the count and phase change.
    private static let width: CGFloat = 230
    /// Bubble spacing at the start of a run: apart, joined only by a glass neck.
    private static let startGap: CGFloat = 4
    /// Bubble spacing at 100%: well into the capsule's end.
    private static let endGap: CGFloat = -14

    // Three layers share one layout: the glass shapes, one glow across both of
    // them, then the text and buttons. Giving each shape its own glow would show
    // the capsule's rounded end through the bubble where they overlap.
    var body: some View {
        ZStack {
            ReadPaperGlassEffectContainer(spacing: 14) {
                HStack(spacing: bubbleGap) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.height)
                        .readPaperGlassEffect(in: Capsule())
                    Color.clear
                        .frame(width: Self.height, height: Self.height)
                        .readPaperGlassEffect(in: Circle())
                }
            }

            progressGlow

            HStack(spacing: bubbleGap) {
                mainContent
                    .frame(maxWidth: .infinity)
                bubbleContent
                    .frame(width: Self.height, height: Self.height)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .animation(.spring(duration: 0.5, bounce: 0.2), value: phase)
        .animation(.easeInOut(duration: 0.6), value: displayedFraction)
        .animation(.easeInOut(duration: 0.25), value: summary)
    }

    /// The bubble closes in with progress; once the run ends it sits entirely
    /// inside the capsule's rounded end, so the two read as one shape.
    private var bubbleGap: CGFloat {
        isRunning
            ? Self.startGap + (Self.endGap - Self.startGap) * displayedFraction
            : -Self.height
    }

    private var title: String {
        switch phase {
        case .running(let isCancelling):
            isCancelling
                ? String(localized: "Cancelling", bundle: bundle)
                : String(localized: "Translating", bundle: bundle)
        case .completed:
            String(localized: "Done", bundle: bundle)
        case .cancelled:
            String(localized: "Cancelled", bundle: bundle)
        }
    }

    private var mainContent: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .lineLimit(1)
                .contentTransition(.opacity)

            Spacer(minLength: 8)

            if isRunning, let summary {
                Text(summary)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .transition(.opacity)
            }
        }
        .padding(.leading, 18)
        // Keep the count clear of the part of the capsule the bubble covers.
        .padding(.trailing, 16 + max(0, -bubbleGap))
        .frame(height: Self.height)
        .contentShape(Capsule())
        .help(detail ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityValue(summary ?? "")
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private var isCancelling: Bool {
        phase == .running(isCancelling: true)
    }

    private var tint: Color {
        switch phase {
        case .running(let isCancelling):
            isCancelling ? .secondary : .accentColor
        case .completed:
            .green
        case .cancelled:
            .secondary
        }
    }

    /// Where the glow ends: a finished run fills the capsule, a cancelled one drains
    /// back to empty, so both end where the next run starts.
    private var displayedFraction: Double {
        switch phase {
        case .running:
            min(max(fraction ?? 0, 0), 1)
        case .completed:
            1
        case .cancelled:
            0
        }
    }

    /// A blurred wash rather than a hard bar: it fades out over its leading edge as
    /// it advances, so even an empty capsule keeps a faint glow at its start.
    private var progressGlow: some View {
        GeometryReader { proxy in
            let overhang: CGFloat = 24
            let fade: CGFloat = 40
            // The progress point sits mid-fade, so the glow reads at its true share
            // and a finished run pushes the whole fade past the trailing end.
            let progressPoint = (proxy.size.width + fade / 2) * displayedFraction
            let total = overhang + progressPoint + fade / 2
            // Near zero progress the fade is longer than the glow; the stops must
            // stay ordered.
            let fadeStart = min(max((total - fade) / total, 0), 1)
            let glowColor: Color = phase == .completed ? .green : .accentColor
            let strength = colorScheme == .dark ? 0.42 : 0.30

            LinearGradient(
                stops: [
                    .init(color: glowColor.opacity(strength), location: 0),
                    .init(color: glowColor.opacity(strength * 0.85), location: fadeStart),
                    .init(color: glowColor.opacity(0), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // Overhang top, bottom and leading so the blur only softens the
            // advancing edge, not the capsule's own outline.
            .frame(width: total, height: proxy.size.height + overhang)
            .offset(x: -24, y: -12)
            .blur(radius: 10)
            .opacity(isCancelling ? 0.45 : 1)
        }
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.6), value: displayedFraction)
        .animation(.easeInOut(duration: 0.3), value: phase)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch phase {
        case .running(let isCancelling):
            cancelButton(isCancelling: isCancelling)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .completed, .cancelled:
            outcomeBadge
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    private var outcomeBadge: some View {
        Image(systemName: phase == .completed ? "checkmark" : "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(tint))
    }

    private func cancelButton(isCancelling: Bool) -> some View {
        let title = isCancelling
            ? String(localized: "Cancelling translation...", bundle: bundle)
            : String(localized: "Cancel Translation", bundle: bundle)
        return Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isCancelling ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: Self.height, height: Self.height)
                .background {
                    Circle()
                        .fill(.primary.opacity(isCancelHovered && !isCancelling ? 0.08 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isCancelling)
        .onHover { isCancelHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
