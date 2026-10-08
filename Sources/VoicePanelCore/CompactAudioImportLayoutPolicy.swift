import Foundation

public struct CompactAudioImportLayoutPolicy: Equatable, Sendable {
    public static let productionCompact = CompactAudioImportLayoutPolicy(
        panelWidth: 420,
        panelHeight: 106,
        horizontalPadding: 14,
        verticalPadding: 12,
        headerHeight: 18,
        recordingSpacing: 7,
        transcriptRowHeight: 32,
        progressIndicatorHeight: 14,
        progressSpacing: 5,
        fallbackFontSize: 12
    )

    public let panelWidth: CGFloat
    public let panelHeight: CGFloat
    public let horizontalPadding: CGFloat
    public let verticalPadding: CGFloat
    public let headerHeight: CGFloat
    public let recordingSpacing: CGFloat
    public let transcriptRowHeight: CGFloat
    public let progressIndicatorHeight: CGFloat
    public let progressSpacing: CGFloat
    public let fallbackFontSize: CGFloat

    public var contentWidth: CGFloat {
        max(0, panelWidth - horizontalPadding * 2)
    }

    public var standardProgressHeight: CGFloat {
        max(
            0,
            panelHeight - verticalPadding * 2 - headerHeight - transcriptRowHeight
                - recordingSpacing * 2
        )
    }

    public var dedicatedProgressHeight: CGFloat {
        max(0, panelHeight - verticalPadding * 2 - headerHeight - recordingSpacing)
    }

    public func requiredProgressHeight(fallbackTextHeight: CGFloat) -> CGFloat {
        progressIndicatorHeight + progressSpacing + max(0, fallbackTextHeight)
    }
}
