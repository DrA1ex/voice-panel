import Foundation
import SwiftUI
import VoicePanelCore

struct InputLevelMeterView: View {
    let currentDB: Float
    let noiseFloorDB: Float
    let thresholdDB: Float
    let state: VoiceActivityState
    let isTesting: Bool

    private let minimumDB: Float = -90
    private let maximumDB: Float = -6
    private let tickValues: [Float] = [-90, -80, -70, -60, -50, -40, -30, -20, -10]
    private let barCornerRadius: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Input level")
                    .font(.callout.weight(.medium))
                Spacer()
                if isTesting {
                    Text(state == .speech ? "Speech detected" : "Background / pause")
                        .font(.caption)
                        .foregroundStyle(state == .speech ? Color.primary : Color.secondary)
                } else {
                    Text("Start Test Input to view the live level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.07))

                    if isTesting {
                        RoundedRectangle(cornerRadius: barCornerRadius - 1, style: .continuous)
                            .fill(inputColor)
                            .frame(width: geometry.size.width * fraction(for: currentDB))

                        marker(
                            at: noiseFloorDB,
                            width: geometry.size.width,
                            color: .secondary,
                            height: 20
                        )
                    }

                    ForEach(tickValues, id: \.self) { value in
                        tick(at: value, width: geometry.size.width)
                    }

                    marker(
                        at: thresholdDB,
                        width: geometry.size.width,
                        color: .orange,
                        height: 25
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous))
            }
            .frame(height: 20)

            HStack(spacing: 0) {
                ForEach(tickValues, id: \.self) { value in
                    Text("\(Int(value))")
                        .frame(
                            maxWidth: .infinity,
                            alignment: value == tickValues.first
                                ? .leading
                                : value == tickValues.last ? .trailing : .center
                        )
                }
                Text("dB")
                    .padding(.leading, 4)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)

            HStack(spacing: 16) {
                if isTesting {
                    legendBar(color: inputColor, title: "Live input")
                    legendMarker(color: .secondary, title: "Noise floor")
                }
                legendMarker(color: .orange, title: "Speech threshold")
                Spacer()
            }

            HStack(spacing: 14) {
                if isTesting {
                    metricLabel("Input", value: currentDB)
                    metricLabel("Noise floor", value: noiseFloorDB)
                }
                metricLabel("Threshold", value: thresholdDB)
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Microphone input level and speech threshold")
    }

    private var inputColor: Color {
        state == .speech ? Color.green.opacity(0.82) : Color.secondary.opacity(0.42)
    }

    private func tick(at value: Float, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(value.truncatingRemainder(dividingBy: 20) == 0 ? 0.18 : 0.09))
            .frame(width: 1, height: 7)
            .offset(x: max(0, min(width - 1, width * fraction(for: value))))
    }

    private func marker(at value: Float, width: CGFloat, color: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2.5, height: height)
            .offset(x: max(0, min(width - 3, width * fraction(for: value))))
    }

    private func legendBar(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 14, height: 5)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metricLabel(_ title: String, value: Float) -> some View {
        Text("\(title) \(String(format: "%.1f dB", value))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func legendMarker(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2.5, height: 11)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func fraction(for value: Float) -> CGFloat {
        CGFloat(min(max((value - minimumDB) / (maximumDB - minimumDB), 0), 1))
    }
}

#if DEBUG
    #Preview("Input Level · Speech") {
        InputLevelMeterView(
            currentDB: -27.4,
            noiseFloorDB: -58,
            thresholdDB: -44,
            state: .speech,
            isTesting: true
        )
        .frame(width: 620)
        .padding()
    }

    #Preview("Input Level · Idle") {
        InputLevelMeterView(
            currentDB: -90,
            noiseFloorDB: -58,
            thresholdDB: -44,
            state: .silence,
            isTesting: false
        )
        .frame(width: 620)
        .padding()
    }
#endif
