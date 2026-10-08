import SwiftUI

/// Displays a single-line transcript that shifts left as it grows. Pending
/// feedback remains visible only while audio is waiting for recognition.
struct SlidingTranscriptView: View {
    let text: String
    var fontSize: CGFloat = 14
    var pendingFeedbackStyle: AppSettings.PendingFeedbackStyle?
    var pendingItemCount = 0
    var pendingItemExtent: Double?
    var pendingFeedbackIsActive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TranscriptOverflowLayout(
            spacing: 7,
            hasText: !text.isEmpty,
            feedbackSlotWidth: feedbackSlotWidth
        ) {
            if !text.isEmpty {
                TranscriptTextViewport(text: text, fontSize: fontSize)
            }

            if let pendingFeedbackStyle {
                PendingFeedbackVisual(
                    style: pendingFeedbackStyle,
                    itemCount: max(1, pendingItemCount),
                    itemExtent: pendingItemExtent ?? Double(pendingItemCount),
                    isActive: pendingFeedbackIsActive
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(pendingItemCount > 0 ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.15),
                    value: pendingItemCount > 0
                )
                .clipped()
            }
        }
        .clipped()
    }

    private var feedbackSlotWidth: CGFloat {
        switch pendingFeedbackStyle {
        case .pulse: return 27
        case .gradientBars: return 138
        case .blurredWords: return 150
        case nil: return 0
        }
    }
}

/// Keep the text and indicator in fixed columns while recording. The text
/// viewport uses all available width until it actually overflows.
private struct TranscriptOverflowLayout: Layout {
    let spacing: CGFloat
    let hasText: Bool
    let feedbackSlotWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 460
        let sizes = sizes(in: width, subviews: subviews)
        let contentHeight = sizes.map(\.height).max() ?? 0
        return CGSize(
            width: width,
            height: proposal.height ?? contentHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = sizes(in: bounds.width, subviews: subviews)
        var nextX = bounds.minX

        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            subview.place(
                at: CGPoint(x: nextX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            nextX += size.width
            if index < subviews.count - 1 {
                nextX += spacing
            }
        }
    }

    private func sizes(in width: CGFloat, subviews: Subviews) -> [CGSize] {
        guard hasText, subviews.count == 2 else {
            return subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
        }
        let feedbackWidth = min(feedbackSlotWidth, width * 0.4)
        let textWidth = max(0, width - feedbackWidth - spacing)
        let feedbackHeight = subviews[1].sizeThatFits(
            ProposedViewSize(width: feedbackWidth, height: nil)
        ).height
        return [
            subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil)),
            CGSize(width: feedbackWidth, height: feedbackHeight),
        ]
    }
}

struct PendingFeedbackPreview: View {
    let style: AppSettings.PendingFeedbackStyle

    var body: some View {
        PendingFeedbackVisual(
            style: style,
            itemCount: 4,
            itemExtent: 4,
            isActive: false
        )
        .frame(width: previewWidth, height: 22, alignment: .leading)
        .accessibilityLabel(style.title)
    }

    private var previewWidth: CGFloat {
        switch style {
        case .blurredWords: 150
        case .gradientBars: 142
        case .pulse: 42
        }
    }
}

private struct PendingFeedbackVisual: View {
    let style: AppSettings.PendingFeedbackStyle
    let itemCount: Int
    let itemExtent: Double
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch style {
            case .blurredWords:
                BlurredPendingWords(
                    wordCount: min(max(itemCount, 1), 8),
                    isActive: isActive,
                    reduceMotion: reduceMotion
                )
            case .gradientBars:
                PendingGradientBars(
                    itemExtent: min(max(itemExtent, 1), 5),
                    isActive: isActive
                )
            case .pulse:
                PendingPulse(isActive: isActive, reduceMotion: reduceMotion)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct BlurredPendingWords: View {
    let wordCount: Int
    let isActive: Bool
    let reduceMotion: Bool

    private let candidateWords = ["varel", "moneta", "selin", "noravi", "temo", "velaris", "lume", "soremi"]

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 30,
                paused: reduceMotion || !isActive
            )
        ) { context in
            HStack(spacing: 7) {
                ForEach(0..<wordCount, id: \.self) { index in
                    let pulse = smoothPulse(
                        at: context.date,
                        offset: Double(index) * 0.72
                    )
                    Text(candidateWords[index % candidateWords.count])
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(
                            Color.primary.opacity(
                                reduceMotion || !isActive
                                    ? 0.42
                                    : 0.34 + pulse * 0.16
                            )
                        )
                        .blur(radius: 1.75)
                        .padding(.horizontal, 3)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .animation(.easeInOut(duration: 0.42), value: wordCount)
        }
    }

    private func smoothPulse(at date: Date, offset: Double) -> Double {
        (sin(date.timeIntervalSinceReferenceDate * .pi * 0.9 + offset) + 1) / 2
    }
}

private struct PendingGradientBars: View {
    let itemExtent: Double
    let isActive: Bool

    var body: some View {
        GradientBarShimmer(isActive: isActive)
            .frame(width: containerWidth, height: 20)
            .animation(.smooth(duration: 0.22), value: containerWidth)
    }

    private var containerWidth: CGFloat {
        58 + CGFloat(max(0, min(itemExtent, 5) - 1)) * 20
    }
}

private struct GradientBarShimmer: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 30,
                paused: reduceMotion || !isActive
            )
        ) { context in
            GradientBarShimmerFrame(
                phase: shimmerPhase(at: context.date),
                glow: glowIntensity(at: context.date)
            )
        }
    }

    private func shimmerPhase(at date: Date) -> CGFloat {
        guard !reduceMotion, isActive else { return 0.5 }
        let duration = 2.4
        return CGFloat(
            date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
        )
    }

    private func glowIntensity(at date: Date) -> CGFloat {
        guard !reduceMotion, isActive else { return 0.55 }
        return CGFloat((sin(date.timeIntervalSinceReferenceDate * .pi * 0.92 + 0.8) + 1) / 2)
    }
}

private struct GradientBarShimmerFrame: View {
    let phase: CGFloat
    let glow: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let horizontalInset = max(8, width * 0.09)
            let highlightWidth = max(18, width * 0.24)
            let highlightTravel = width + highlightWidth * 2

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.045),
                                Color.primary.opacity(0.035),
                                Color.pink.opacity(0.045),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.cyan.opacity(0.14),
                                        Color.primary.opacity(0.07),
                                        Color.pink.opacity(0.14),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: 0.7
                            )
                    }

                luminousStreak
                    .padding(.horizontal, horizontalInset)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.95), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: highlightWidth, height: 1.6)
                    .blur(radius: 1.1)
                    .offset(x: -width / 2 - highlightWidth + highlightTravel * phase)
                    .blendMode(.screen)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var luminousStreak: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(streakGradient)
                .frame(height: 5.5)
                .blur(radius: 4.2)
                .opacity(0.42 + glow * 0.18)

            Capsule(style: .continuous)
                .fill(streakGradient)
                .frame(height: 1.45)
                .opacity(0.68 + glow * 0.20)
        }
        .blendMode(.screen)
    }

    private var streakGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: Color.blue.opacity(0.50), location: 0.13),
                .init(color: Color.cyan.opacity(0.88), location: 0.29),
                .init(color: Color.white.opacity(0.98), location: 0.50),
                .init(color: Color.pink.opacity(0.90), location: 0.69),
                .init(color: Color.red.opacity(0.62), location: 0.87),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct PendingPulse: View {
    let isActive: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 30,
                paused: reduceMotion || !isActive
            )
        ) { context in
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let delayed =
                        reduceMotion || !isActive
                        ? 0.45
                        : (sin(
                            context.date.timeIntervalSinceReferenceDate * .pi * 1.4
                                + Double(index) * 0.92
                        ) + 1) / 2
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.cyan, .pink, .orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.72 + delayed * 0.58)
                        .opacity(0.38 + delayed * 0.58)
                        .shadow(color: Color.pink.opacity(0.20 + delayed * 0.30), radius: 3)
                }
            }
            .frame(width: 27, height: 16)
        }
    }
}

#if DEBUG
    #Preview("Sliding Transcript") {
        SlidingTranscriptView(
            text: "VoicePanel keeps the transcript moving while recognition continues",
            pendingFeedbackStyle: .gradientBars,
            pendingItemCount: 4,
            pendingItemExtent: 4.2,
            pendingFeedbackIsActive: true
        )
        .frame(width: 460, height: 32)
        .padding()
    }

    #Preview("Pending Feedback Picker") {
        HStack(spacing: 24) {
            ForEach(AppSettings.PendingFeedbackStyle.allCases) { style in
                VStack(spacing: 8) {
                    PendingFeedbackPreview(style: style)
                    Text(style.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    #Preview("Pending Feedback Visual") {
        PendingFeedbackVisual(
            style: .gradientBars,
            itemCount: 4,
            itemExtent: 4,
            isActive: true
        )
        .frame(width: 150, height: 24)
        .padding()
    }

    #Preview("Blurred Pending Words") {
        BlurredPendingWords(wordCount: 5, isActive: true, reduceMotion: false)
            .padding()
    }

    #Preview("Pending Gradient Bars") {
        PendingGradientBars(itemExtent: 4.5, isActive: true)
            .padding()
    }

    #Preview("Gradient Bar Shimmer") {
        GradientBarShimmer(isActive: true)
            .frame(width: 148, height: 20)
            .padding()
    }

    #Preview("Gradient Bar Shimmer Frame") {
        GradientBarShimmerFrame(phase: 0.58, glow: 0.82)
            .frame(width: 148, height: 20)
            .padding()
    }

    #Preview("Pending Pulse") {
        PendingPulse(isActive: true, reduceMotion: false)
            .padding()
    }
#endif
