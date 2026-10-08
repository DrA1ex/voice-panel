import AppKit
import Foundation
import VoicePanelCore

private enum PresentationCheckFailure: Error {
    case failed(String)
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PresentationCheckFailure.failed(message) }
}

@MainActor
private func update(
    id: UUID, sequence: Int, text: String, kind: TranscriptSegmentUpdateKind = .partial
) -> RecognitionUpdate {
    RecognitionUpdate(
        segment: TranscriptSegmentUpdate(
            segmentID: id, sequence: sequence,
            stableText: kind == .partial ? "" : text,
            partialText: kind == .partial ? text : "", kind: kind
        ),
        shouldDimPartialText: kind == .partial
    )
}

@MainActor
private func chunk() -> AudioChunk {
    AudioChunk(samples: Array(repeating: 0.1, count: 160), sampleRate: 160, boundaryReason: .silence)
}

@MainActor
private func pending(_ state: AppState) -> Bool {
    state.pendingFeedbackPresentation(maximumItemCount: 8).hasVisibleItems
}

@MainActor
private func render(_ view: TranscriptTextViewportView) throws -> NSBitmapImageRep {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw PresentationCheckFailure.failed("Could not create a native viewport bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(view.bounds)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

@MainActor
private func compareRightEdge(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep, width: Int = 60) throws {
    try require(left.pixelsWide == right.pixelsWide && left.pixelsHigh == right.pixelsHigh, "Bitmap dimensions differ")
    var difference: CGFloat = 0
    var ink: CGFloat = 0
    for y in 0..<left.pixelsHigh {
        for x in (left.pixelsWide - width)..<left.pixelsWide {
            guard let a = left.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                let b = right.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            else { throw PresentationCheckFailure.failed("Could not sample viewport pixels") }
            difference += abs(a.alphaComponent - b.alphaComponent)
            ink += b.alphaComponent
        }
    }
    try require(ink > 5, "The latest text must actually draw visible glyphs")
    try require(difference / ink < 0.03, "The newest glyphs differ from the reference tail: \(difference / ink)")
}

@MainActor
private func saveSnapshot(_ bitmap: NSBitmapImageRep, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["VOICEPANEL_TRANSCRIPT_CHECK_ARTIFACT_DIR"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
    image.lockFocus()
    let bounds = NSRect(origin: .zero, size: image.size)
    NSColor.white.setFill()
    bounds.fill()
    if let cgImage = bitmap.cgImage, let context = NSGraphicsContext.current?.cgContext {
        context.setBlendMode(.normal)
        context.draw(cgImage, in: bounds)
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
        let flattened = NSBitmapImageRep(data: tiff),
        let data = flattened.representation(using: .png, properties: [:])
    else {
        throw PresentationCheckFailure.failed("Could not encode viewport snapshot")
    }
    try data.write(to: directory.appendingPathComponent(name))
}

@main
private struct TranscriptPresentationChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try checkDraftAndFinalLifetime()
        try checkCallbackOrderingAndReset()
        try checkContinuousFinalAcknowledgement()
        try checkPendingDraftTimeline()
        try checkDraftStylingLifetime()
        try await checkScrollScheduling()
        try checkNativeSingleLineRendering()
        try checkNativeWrappedRendering()
        try checkAnimationCatchup()
        try checkLongTranscriptUpdates()
        print("All 10 native transcript presentation checks passed.")
    }

    @MainActor
    private static func checkDraftAndFinalLifetime() throws {
        let state = AppState()
        state.phase = .listening
        state.hasLiveDraftText = true
        state.recognitionUsesAudioChunks = true
        state.updatePendingFeedbackVoiceActivity(recordingDuration: 1, voiceActivityState: .speech)
        let first = chunk()
        state.applyRecognitionUpdate(update(id: first.id, sequence: 0, text: "Apple draft"))
        try require(pending(state), "Apple draft must not acknowledge pending final audio")
        state.queueRecognitionChunk(first)
        state.updatePendingFeedbackVoiceActivity(recordingDuration: 1.5, voiceActivityState: .speech)
        let activeDuration = state.activePendingFeedbackVoicedDuration
        state.applyRecognitionUpdate(update(id: first.id, sequence: 0, text: "Final text", kind: .segmentFinal))
        try require(
            state.activePendingFeedbackVoicedDuration == activeDuration, "An older final must not clear new speech")
        try require(state.frozenPendingFeedbackItemCount > 0, "Final text alone must not resolve a chunk")
        let second = chunk()
        state.queueRecognitionChunk(second)
        state.resolveRecognitionChunk(id: first.id, failed: false)
        try require(pending(state), "The last queued final chunk must keep the loader visible")
        state.phase = .stopping
        state.finishAudioCapture()
        try require(pending(state), "Stop must preserve queued final work")
        state.phase = .finalizing
        try require(pending(state), "Finalization must preserve queued final work")
        state.resolveRecognitionChunk(id: second.id, failed: false)
        try require(!pending(state), "The loader must clear after the last final outcome")
        state.finishRecognitionEngine()
        try require(state.pendingFeedbackItemExtent == 0, "Engine completion must clear all feedback")
        print("PASS  Draft, older finals, Stop, and finalization preserve the last pending chunk")
    }

    @MainActor
    private static func checkCallbackOrderingAndReset() throws {
        let state = AppState()
        state.phase = .listening
        state.recognitionUsesAudioChunks = true
        let completedEarly = chunk()
        state.resolveRecognitionChunk(id: completedEarly.id, failed: false)
        state.queueRecognitionChunk(completedEarly)
        try require(
            !pending(state) && !state.pendingRecognitionWork.hasWork, "Early completion must not leave phantom work")
        let failed = chunk()
        state.queueRecognitionChunk(failed)
        state.resolveRecognitionChunk(id: failed.id, failed: true)
        try require(!pending(state), "Failed final chunks must resolve their loader")
        state.updatePendingFeedbackVoiceActivity(recordingDuration: 2, voiceActivityState: .speech)
        state.finishAudioCapture()
        try require(pending(state), "The stopped live tail must stay pending until its final chunk is registered")
        let finalTail = chunk()
        state.queueRecognitionChunk(finalTail)
        try require(pending(state), "Stop handoff must preserve feedback")
        state.finishRecognitionEngine()
        try require(!pending(state), "Authoritative engine finish must remove stale bookkeeping")
        state.resetForNewSession()
        try require(!state.recognitionUsesAudioChunks && !pending(state), "A new session must reset presentation state")
        state.phase = .failed
        state.queueRecognitionChunk(chunk())
        try require(!pending(state), "Terminal phases must not show a pending loader")
        print("PASS  Callback races, failure, final-tail handoff, and session reset")
    }

    @MainActor
    private static func checkContinuousFinalAcknowledgement() throws {
        let state = AppState()
        state.phase = .listening
        state.updatePendingFeedbackVoiceActivity(recordingDuration: 0.5, voiceActivityState: .speech)
        let id = UUID()
        state.applyRecognitionUpdate(update(id: id, sequence: 0, text: "Interim"))
        try require(pending(state), "An interim Apple-only result is still awaiting finalization")
        state.applyRecognitionUpdate(update(id: id, sequence: 0, text: "Final", kind: .segmentFinal))
        try require(!pending(state), "A continuous recognizer's final must acknowledge its tail")
        print("PASS  Continuous Apple recognition acknowledges only final text")
    }

    @MainActor
    private static func checkPendingDraftTimeline() throws {
        let state = AppState()
        state.phase = .listening
        state.recognitionUsesAudioChunks = true
        let ids = (0..<4).map { _ in UUID() }

        func requireVisible(_ expected: String, drafts: [Bool]) throws {
            let presentation = state.transcriptPresentation
            try require(presentation.combinedText == expected, "The recording timeline changed unexpectedly")
            try require(
                presentation.runs.map(\.text).joined() == expected,
                "Full preview dropped or reordered text while final recognition was pending")
            try require(presentation.runs.map(\.isDraft) == drafts, "Draft styling moved to the wrong segment")
            try require(!presentation.multilineText.contains("\n"), "A chunk boundary inserted a newline")
        }

        state.applyRecognitionUpdate(update(id: ids[0], sequence: 0, text: "Начало записи"))
        state.applyRecognitionUpdate(update(id: ids[1], sequence: 1, text: "продолжение фразы"))
        try requireVisible("Начало записи продолжение фразы", drafts: [true, true])
        state.applyRecognitionUpdate(update(id: ids[2], sequence: 2, text: "следующие слова"))
        try requireVisible("Начало записи продолжение фразы следующие слова", drafts: [true, true, true])

        // Finals may arrive out of order while earlier drafts are still visible.
        state.applyRecognitionUpdate(update(id: ids[1], sequence: 1, text: "уточнённая фраза", kind: .segmentFinal))
        try requireVisible("Начало записи уточнённая фраза следующие слова", drafts: [true, false, true])
        try require(state.shouldDimPartialText, "An older final must not remove styling from pending drafts")
        state.applyRecognitionUpdate(update(id: ids[0], sequence: 0, text: "Начало записи.", kind: .segmentFinal))
        try requireVisible("Начало записи. уточнённая фраза следующие слова", drafts: [false, false, true])
        state.applyRecognitionUpdate(update(id: ids[3], sequence: 3, text: "следующие слова и конец"))
        try requireVisible(
            "Начало записи. уточнённая фраза следующие слова и конец", drafts: [false, false, true, true])

        // Explicit dictation line breaks remain intact in the full preview.
        state.applyRecognitionUpdate(update(id: ids[3], sequence: 3, text: "\nНовый абзац"))
        try require(
            state.transcriptPresentation.runs.map(\.text).joined() == state.combinedTranscript,
            "Full preview flattened an explicit line break")
        try require(state.combinedTranscript.hasSuffix("\nНовый абзац"), "An explicit dictation newline disappeared")
        print("PASS  Full preview retains multiple drafts, out-of-order finals, overlaps, and explicit newlines")
    }

    @MainActor
    private static func checkDraftStylingLifetime() throws {
        let state = AppState()
        state.phase = .listening
        let first = UUID()
        let second = UUID()
        state.applyRecognitionUpdates([
            update(id: first, sequence: 0, text: "Первый черновик"),
            update(id: second, sequence: 1, text: "Второй черновик"),
            update(id: first, sequence: 0, text: "Первый финал", kind: .segmentFinal),
        ])
        try require(
            state.transcriptPresentation.runs.map(\.shouldDim) == [false, true],
            "An older final changed live draft styling")
        state.applyRecognitionUpdate(update(id: second, sequence: 1, text: "Второй финал", kind: .segmentFinal))
        try require(!state.shouldDimPartialText, "Finalized text must not remain dimmed")
        state.applyRecognitionUpdate(update(id: UUID(), sequence: 2, text: "Новый черновик"))
        state.discardTranscriptContent()
        try require(
            !state.shouldDimPartialText && state.transcriptPresentation.runs.isEmpty, "Discard retained draft styling")
        state.resetForNewSession()
        state.applyRecognitionUpdate(
            RecognitionUpdate(
                segment: TranscriptSegmentUpdate(
                    segmentID: second, sequence: 0, stableText: "Apple Speech",
                    partialText: "", kind: .partial
                ), shouldDimPartialText: false
            )
        )
        try require(!state.transcriptPresentation.runs[0].shouldDim, "Standalone Speech inherited hybrid draft styling")
        print("PASS  Draft styling survives delayed finals and resets for standalone recognition")
    }

    @MainActor
    private static func checkScrollScheduling() async throws {
        let scroll = TranscriptScrollCoordinator(interval: .milliseconds(30))
        var events: [String] = []
        for index in 0..<12 {
            scroll.schedule { events.append("\(index)") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!events.isEmpty, "Continuous updates indefinitely postponed scrolling")
        try require(events.count < 12, "Rapid updates were not coalesced")
        try await Task.sleep(for: .milliseconds(50))
        try require(events.last == "11", "The final pending scroll was lost")
        scroll.schedule { events.append("до") }
        scroll.schedule { events.append("да") }
        try await Task.sleep(for: .milliseconds(50))
        try require(
            events.last == "да" && !events.contains("до"), "A same-length correction kept a stale scroll action")
        let count = events.count
        scroll.schedule { events.append("закрыто") }
        scroll.cancel()
        try await Task.sleep(for: .milliseconds(50))
        try require(events.count == count, "A closed preview executed a pending scroll")
        scroll.schedule { events.append("снова") }
        try await Task.sleep(for: .milliseconds(50))
        try require(events.last == "снова", "Reopening the preview did not resume scrolling")
        print("PASS  Continuous, same-length, cancelled, and resumed transcript scrolling")
    }

    @MainActor
    private static func checkLongTranscriptUpdates() throws {
        let state = AppState()
        state.phase = .listening
        state.recognitionUsesAudioChunks = true
        let old = UUID()
        state.applyRecognitionUpdate(
            update(
                id: old, sequence: 0, text: String(repeating: "Длинная запись.\n", count: 10_000), kind: .segmentFinal)
        )
        let live = UUID()
        for index in 0..<300 {
            state.applyRecognitionUpdate(
                update(id: live, sequence: 1, text: "Первый ряд\r\nВторой↵Последние слова \(index)")
            )
            try require(
                state.compactTranscriptText.hasSuffix("Последние слова \(index)"), "A rapid draft update disappeared")
            try require(state.compactTranscriptText.count <= 1_200, "Compact text must remain bounded")
            try require(!state.compactTranscriptText.contains(where: { $0.isNewline }), "Compact text must never wrap")
            try require(
                state.transcriptPresentation.multilineText.hasSuffix("Последние слова \(index)"),
                "Large panel tail is stale")
        }
        try require(state.combinedTranscript.count > 100_000, "Full transcript must retain the entire recording")
        state.finalizeResult()
        state.editableText += "\nПравка результата"
        try require(state.compactTranscriptText.hasSuffix("Правка результата"), "Result edits must update the viewport")
        print("PASS  300 Apple revisions after a 150,000-character multiline recording")
    }

    @MainActor
    private static func checkNativeSingleLineRendering() throws {
        let view = TranscriptTextViewportView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        let reference = TranscriptTextViewportView(frame: view.frame)
        let prefix = String(repeating: "Старый текст. ", count: 1_000)
        for width: CGFloat in [170, 300, 540] {
            for fontSize: CGFloat in [14, 16, 19] {
                view.setFrameSize(NSSize(width: width, height: 32))
                reference.setFrameSize(view.frame.size)
                view.update(text: prefix + "\nКОНЕЦ 12345", fontSize: fontSize, reduceMotion: true)
                reference.update(
                    text: String(repeating: "Ж ", count: 200) + "КОНЕЦ 12345", fontSize: fontSize, reduceMotion: true)
                let actual = try render(view)
                try compareRightEdge(actual, render(reference))
                try saveSnapshot(actual, name: "compact-tail.png")
                view.update(text: prefix + "\u{2028}НОВЫЙ 67890", fontSize: fontSize, reduceMotion: true)
                reference.update(
                    text: String(repeating: "Ж ", count: 200) + "НОВЫЙ 67890", fontSize: fontSize, reduceMotion: true)
                try compareRightEdge(render(view), render(reference))
                try require(view.drawingOrigin < 0, "Overflow must follow the right edge")
            }
        }
        view.update(text: "Коротко", fontSize: 14)
        try require(view.drawingOrigin == 0, "A shorter correction must return to the leading edge immediately")
        print("PASS  Native glyph rendering follows updates, line separators, all font sizes, and resized bounds")
    }

    @MainActor
    private static func checkNativeWrappedRendering() throws {
        let view = TranscriptTextViewportView(frame: NSRect(x: 0, y: 0, width: 400, height: 90))
        let reference = TranscriptTextViewportView(frame: view.frame)
        let prefix = String(repeating: "Очень старый абзац\n", count: 1_000)
        for width: CGFloat in [220, 400, 600] {
            view.setFrameSize(NSSize(width: width, height: 90))
            reference.setFrameSize(view.frame.size)
            let tail = "Первый новый ряд\nВторой новый ряд\nПоследний ряд 67890"
            view.update(text: prefix + tail, fontSize: 19, maximumLines: 3)
            reference.update(text: tail, fontSize: 19, maximumLines: 3)
            let actual = try render(view)
            try saveSnapshot(actual, name: "large-tail.png")
            let expected = try render(reference)
            try require(
                actual.representation(using: .png, properties: [:])
                    == expected.representation(using: .png, properties: [:]),
                "Large panel must draw the last three lines, never the first three")
        }
        print("PASS  Native multiline panel draws the last three rows after wrapping and resizing")
    }

    @MainActor
    private static func checkAnimationCatchup() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 28), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let view = TranscriptTextViewportView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        window.contentView = view
        let base = String(repeating: "Текст ", count: 40)
        view.update(text: base, fontSize: 14)
        let previous = view.drawingOrigin
        view.update(text: base + "я", fontSize: 14)
        try require(view.drawingOrigin == previous, "A small append should begin its short animation")
        for index in 0..<20 {
            view.update(text: base + String(repeating: "я", count: index + 1), fontSize: 14)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.13))
        _ = try render(view)
        let expected = min(0, view.bounds.width - view.intrinsicContentSize.width)
        try require(abs(view.drawingOrigin - expected) < 0.01, "Rapid updates must catch up within 130ms")
        view.update(text: base + " Совершенно новая длинная фраза", fontSize: 14)
        try require(
            view.drawingOrigin == min(0, view.bounds.width - view.intrinsicContentSize.width),
            "Large revisions must render immediately")
        view.update(text: base + " Совершенно новая длинная фраза я", fontSize: 14)
        view.update(text: base + " Совершенно новая длинная фраза я", fontSize: 14, reduceMotion: true)
        try require(
            view.drawingOrigin == min(0, view.bounds.width - view.intrinsicContentSize.width),
            "Reduced motion must cancel an in-progress animation")
        window.contentView = nil
        print("PASS  Rapid animation catch-up, immediate large revisions, and reduced motion")
    }
}
