import Foundation
import VoicePanelCore

let captureTimelineChecks: [CheckCase] = [
    CheckCase(name: "Untimed draft corrections retain old word positions and appended repetitions") {
        let original = DraftTokenTiming.observedTokens(text: "ещё раз", previous: [], captureTime: 2)
        let extended = DraftTokenTiming.observedTokens(text: "ещё раз ещё раз", previous: original, captureTime: 10)
        try expectEqual(extended.map(\.captureTime), [2, 2, 10, 10])
        let revised = DraftTokenTiming.observedTokens(text: "снова раз ещё раз", previous: extended, captureTime: 12)
        try expectEqual(revised.map(\.captureTime), [2, 2, 10, 10])
        let inserted = DraftTokenTiming.observedTokens(
            text: "ещё один раз ещё раз", previous: extended, captureTime: 12)
        try expectEqual(inserted.map(\.captureTime), [2, 2, 2, 10, 10])
    },
    CheckCase(name: "Apple utterance restarts keep closed phrases without duplicating revisions") {
        var utterances = SpeechUtteranceAccumulator()
        utterances.observe("Сегодня мы проверяем", closesUtterance: false)
        utterances.observe("Сегодня мы проверяем", closesUtterance: true)
        try expect(utterances.observe("После", closesUtterance: false), "Restart after metadata was not detected")
        try expectEqual(utterances.text, "Сегодня мы проверяем После")
        utterances.observe("", closesUtterance: false)
        try expectEqual(utterances.text, "Сегодня мы проверяем После", "An empty result erased the hypothesis")

        var cumulative = SpeechUtteranceAccumulator()
        cumulative.observe("Третье фраза", closesUtterance: true)
        cumulative.observe("Третья фраза идёт", closesUtterance: false)
        try expectEqual(cumulative.text, "Третья фраза идёт", "A revised cumulative hypothesis was duplicated")

        var revised = SpeechUtteranceAccumulator()
        revised.observe("по то му что", closesUtterance: false)
        revised.observe("потому что", closesUtterance: false)
        try expectEqual(revised.text, "потому что", "A shortened revision was treated as a new utterance")
        revised.observe("потому что мы долго ждали ответа", closesUtterance: false)
        revised.observe("Новая", closesUtterance: false)
        try expectEqual(revised.text, "потому что мы долго ждали ответа Новая")
    },
    CheckCase(name: "Retrospective audio cuts retain their captured positions") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0, postRollDuration: 0, overlapDuration: 0,
                maximumChunkDuration: 2, minimumChunkDuration: 0,
                forcedBoundaryMode: .deferredPauseBalanced, deferredBoundaryDecisionDuration: 5
            ))
        var chunks = segmenter.process(
            samples: Array(repeating: 0.1, count: 50), sampleRate: 10, event: .speechStarted,
            captureStartTime: 10
        )
        chunks += segmenter.finishChunks()
        try expectEqual(chunks.map(\.captureTimeRange), [10..<12, 12..<14, 14..<15])
    },
    CheckCase(name: "Captured positions account for pre-roll and trimmed silence") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0.5, postRollDuration: 0.1, overlapDuration: 0,
                maximumChunkDuration: 20, minimumChunkDuration: 0
            ))
        _ = segmenter.process(
            samples: Array(repeating: 0, count: 10), sampleRate: 10, event: .silence, captureStartTime: 0)
        _ = segmenter.process(
            samples: Array(repeating: 0.1, count: 10), sampleRate: 10, event: .speechStarted, captureStartTime: 1)
        let chunks = segmenter.process(
            samples: Array(repeating: 0, count: 10), sampleRate: 10, event: .speechEnded(silenceDuration: 1),
            captureStartTime: 2)
        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].captureTimeRange, 0.5..<2.1)
    },
    CheckCase(name: "Fallback chunking retains timing through overlapping audio windows") {
        var accumulator = ForcedChunkAccumulator(configuration: .init(maximumChunkDuration: 2, overlapDuration: 0.5))
        let chunks = accumulator.process(
            samples: Array(repeating: 0.1, count: 50), sampleRate: 10, hasSpeechEvidence: true, captureStartTime: 10)
        try expectEqual(chunks.map(\.captureTimeRange), [10..<12, 11.5..<13.5, 13..<15])
    },
    CheckCase(name: "Disjoint draft and final chunks preserve deliberately repeated phrases") {
        var session = TranscriptSession()
        let first = UUID()
        let second = UUID()
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: first, sequence: 0, stableText: "ещё раз", partialText: "", kind: .segmentFinal,
                allowsLeadingOverlap: false))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: second, sequence: 1, stableText: "", partialText: "ещё раз и дальше", kind: .partial,
                allowsLeadingOverlap: false))
        try expectEqual(session.combinedText, "ещё раз ещё раз и дальше")
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: second, sequence: 1, stableText: "ещё раз и дальше", partialText: "", kind: .segmentFinal,
                allowsLeadingOverlap: false))
        try expectEqual(session.finalizedText, "ещё раз ещё раз и дальше")
    },
    CheckCase(name: "Delayed drafts cannot undo a final revision or an empty final") {
        var session = TranscriptSession()
        let id = UUID()
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: id, sequence: 0, stableText: "Итог", partialText: "", kind: .segmentFinal))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: id, sequence: 0, stableText: "", partialText: "старый черновик", kind: .partial))
        try expectEqual(session.combinedText, "Итог")
        session.apply(
            TranscriptSegmentUpdate(segmentID: id, sequence: 0, stableText: "", partialText: "", kind: .segmentFinal))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: id, sequence: 0, stableText: "", partialText: "старый черновик", kind: .partial))
        try expectEqual(session.combinedText, "")
        try expect(session.segments[0].isFinal, "An empty final lost its terminal state")
    },
]
