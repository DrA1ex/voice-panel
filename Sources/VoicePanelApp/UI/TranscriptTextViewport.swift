import AppKit
import CoreText
import QuartzCore
import SwiftUI
import VoicePanelCore

/// Draws the newest text inside fixed native bounds. No oversized text surface
/// or SwiftUI line truncation can leave an older line stuck in the viewport.
struct TranscriptTextViewport: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    var maximumLines = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> TranscriptTextViewportView {
        TranscriptTextViewportView()
    }

    func updateNSView(_ view: TranscriptTextViewportView, context: Context) {
        view.update(text: text, fontSize: fontSize, maximumLines: maximumLines, reduceMotion: reduceMotion)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: TranscriptTextViewportView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: proposal.height ?? fontSize * 1.5 * CGFloat(max(1, maximumLines))
        )
    }
}

@MainActor
final class TranscriptTextViewportView: NSView {
    private var text = ""
    private var sourceText = ""
    private var fontSize: CGFloat = 0
    private var maximumLines = 1
    private var reduceMotion = false
    private var typesetter: CTTypesetter?
    private var lines: [CTLine] = []
    private var lineWidth: CGFloat = 0
    private var ascent: CGFloat = 0
    private var descent: CGFloat = 0
    private var scrollStartedAt: CFTimeInterval?
    private var scrollStartOrigin: CGFloat = 0
    private var displayLink: WindowDisplayLinkDriver?
    private(set) var drawingOrigin: CGFloat = 0

    private var targetOrigin: CGFloat {
        maximumLines == 1 ? min(0, bounds.width - lineWidth) : 0
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: lineWidth, height: fontSize * 1.5 * CGFloat(maximumLines))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("transcription-panel.transcript")
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink = window.map { window in
            WindowDisplayLinkDriver(window: window) { [weak self] in
                self?.advanceScrollAnimation()
            }
        }
        snapToNewestText()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            if maximumLines > 1 { rebuildLines() }
            snapToNewestText()
        }
        needsDisplay = true
    }

    func update(text: String, fontSize: CGFloat, maximumLines: Int = 1, reduceMotion: Bool = false) {
        let lineLimit = max(1, maximumLines)
        let motionChanged = self.reduceMotion != reduceMotion
        self.reduceMotion = reduceMotion
        guard text != sourceText || fontSize != self.fontSize || lineLimit != self.maximumLines else {
            if motionChanged, reduceMotion { snapToNewestText() }
            return
        }
        sourceText = text
        let normalizedText =
            lineLimit == 1
            ? TranscriptTextNormalizer.singleLinePreview(text)
            : TranscriptTextNormalizer.normalize(String(text.suffix(1_200)))
        advanceScrollAnimation()
        let oldOrigin = drawingOrigin
        let canAnimate = !self.text.isEmpty && fontSize == self.fontSize && lineLimit == self.maximumLines
        self.text = normalizedText
        self.fontSize = fontSize
        self.maximumLines = lineLimit

        let systemFont = NSFont.systemFont(ofSize: fontSize)
        let descriptor = systemFont.fontDescriptor.withDesign(.rounded) ?? systemFont.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: fontSize) ?? systemFont
        let attributed = NSAttributedString(
            string: normalizedText,
            attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
        )
        typesetter = CTTypesetterCreateWithAttributedString(attributed)
        rebuildLines()
        invalidateIntrinsicContentSize()
        setAccessibilityLabel(normalizedText)

        // Small appends get a brief scroll. Larger Apple revisions, corrections,
        // and wrapped lines snap immediately instead of queuing unreadable motion.
        let distance = oldOrigin - targetOrigin
        if canAnimate, !reduceMotion, maximumLines == 1,
            distance > 0, distance <= 24, displayLink != nil
        {
            drawingOrigin = oldOrigin
            scrollStartOrigin = oldOrigin
            scrollStartedAt = CACurrentMediaTime()
            displayLink?.isActive = true
        } else {
            snapToNewestText()
        }
        needsDisplay = true
    }

    private func rebuildLines() {
        guard let typesetter else { return }
        let length = (text as NSString).length
        if maximumLines == 1 {
            lines = [CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: length))]
        } else {
            var wrappedLines: [CTLine] = []
            var offset = 0
            while offset < length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(max(1, bounds.width))))
                let range = CFRange(location: offset, length: min(count, length - offset))
                wrappedLines.append(CTTypesetterCreateLine(typesetter, range))
                offset += range.length
            }
            lines = Array(wrappedLines.suffix(maximumLines))
        }
        lineWidth =
            lines.map { line in
                CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            }.max() ?? 0
    }

    private func snapToNewestText() {
        drawingOrigin = targetOrigin
        scrollStartedAt = nil
        displayLink?.isActive = false
        needsDisplay = true
    }

    private func advanceScrollAnimation() {
        guard let scrollStartedAt else { return }
        let progress = min(1, max(0, (CACurrentMediaTime() - scrollStartedAt) / 0.10))
        if progress >= 1 {
            snapToNewestText()
            return
        }
        let eased = 1 - pow(1 - progress, 3)
        drawingOrigin = scrollStartOrigin + (targetOrigin - scrollStartOrigin) * eased
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        advanceScrollAnimation()
        guard !lines.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.textMatrix = .identity
        context.setFillColor(NSColor.labelColor.cgColor)
        let lineHeight = fontSize * 1.5
        let firstBaseline =
            maximumLines == 1
            ? bounds.midY - (ascent - descent) / 2
            : bounds.maxY - lineHeight / 2 - (ascent - descent) / 2
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(
                x: drawingOrigin,
                y: firstBaseline - CGFloat(index) * lineHeight
            )
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

#if DEBUG
    #Preview("Transcript Text Viewport · Long Tail") {
        TranscriptTextViewport(
            text: String(repeating: "Длинная запись продолжает расти. ", count: 40)
                + "Последние слова всегда видны.",
            fontSize: 14
        )
        .frame(width: 300, height: 28)
        .padding()
    }
#endif
