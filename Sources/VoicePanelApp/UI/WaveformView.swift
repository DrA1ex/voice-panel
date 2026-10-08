import SwiftUI

struct WaveformView: View {
    let levels: [Float]
    var visibleLevelCount: Int? = nil
    var active = true

    var body: some View {
        Canvas { context, size in
            let capacity = levels.count
            guard capacity > 0 else { return }

            let spacing = size.width / CGFloat(capacity)
            let barWidth = max(1.4, min(4.2, spacing * 0.50))
            let centerY = size.height / 2

            let visibleCount = min(max(visibleLevelCount ?? capacity, 0), capacity)
            let firstVisibleIndex = capacity - visibleCount
            for (index, rawLevel) in levels.prefix(visibleCount).enumerated() {
                let timelineIndex = firstVisibleIndex + index
                let level = CGFloat(max(0.045, min(rawLevel, 1)))
                let progress = Double(timelineIndex) / Double(max(capacity - 1, 1))
                let barColor = waveformColor(at: progress)
                let guideHeight = max(3, size.height * 0.22)
                let activeHeight = max(3, size.height * (0.16 + level * 0.84))
                let x = CGFloat(timelineIndex) * spacing + spacing / 2

                let guideRect = CGRect(
                    x: x - barWidth / 2,
                    y: centerY - guideHeight / 2,
                    width: barWidth,
                    height: guideHeight
                )
                context.fill(
                    Path(roundedRect: guideRect, cornerRadius: barWidth / 2),
                    with: .color(.primary.opacity(0.075))
                )

                let activeRect = CGRect(
                    x: x - barWidth / 2,
                    y: centerY - activeHeight / 2,
                    width: barWidth,
                    height: activeHeight
                )
                let opacity = active ? 0.48 + level * 0.48 : 0.20

                context.drawLayer { layer in
                    if active && level > 0.24 {
                        layer.addFilter(
                            .shadow(
                                color: barColor.opacity(0.24 + level * 0.22),
                                radius: 2.5 + level * 2.5
                            ))
                    }
                    layer.fill(
                        Path(roundedRect: activeRect, cornerRadius: barWidth / 2),
                        with: .color(barColor.opacity(opacity))
                    )
                }

                let highlightHeight = max(1.5, activeHeight * 0.26)
                let highlightRect = CGRect(
                    x: x - max(0.6, barWidth * 0.20),
                    y: centerY - activeHeight / 2 + 1,
                    width: max(1, barWidth * 0.40),
                    height: highlightHeight
                )
                context.fill(
                    Path(roundedRect: highlightRect, cornerRadius: barWidth / 4),
                    with: .color(.white.opacity(active ? 0.18 : 0.05))
                )
            }
        }
        .accessibilityLabel("Microphone waveform")
    }

    private func waveformColor(at progress: Double) -> Color {
        switch progress {
        case ..<0.24: return .blue
        case ..<0.47: return .indigo
        case ..<0.69: return .purple
        case ..<0.86: return .pink
        default: return .orange
        }
    }
}

#if DEBUG
    #Preview("Waveform · Active") {
        WaveformView(
            levels: [
                0.08, 0.14, 0.24, 0.42, 0.68, 0.92, 0.54, 0.31,
                0.46, 0.78, 0.60, 0.22, 0.12, 0.34, 0.66, 0.84,
            ]
        )
        .frame(width: 420, height: 64)
        .padding()
    }

    #Preview("Waveform · Inactive") {
        WaveformView(
            levels: [0.08, 0.12, 0.18, 0.32, 0.54, 0.38, 0.22, 0.15],
            active: false
        )
        .frame(width: 320, height: 52)
        .padding()
    }
#endif
