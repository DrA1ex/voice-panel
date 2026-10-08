import Foundation
import VoicePanelCore

let transcriptSessionChecks: [CheckCase] = [
    CheckCase(name: "Finalized segment remains when the next segment changes") {
        var session = TranscriptSession()
        let firstID = UUID()
        let secondID = UUID()

        session.apply(
            TranscriptSegmentUpdate(
                segmentID: firstID,
                sequence: 0,
                stableText: "Первая законченная фраза.",
                partialText: "",
                kind: .segmentFinal
            ))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: secondID,
                sequence: 1,
                stableText: "",
                partialText: "Начало второй",
                kind: .partial
            ))

        try expectEqual(session.combinedText, "Первая законченная фраза. Начало второй")

        session.apply(
            TranscriptSegmentUpdate(
                segmentID: secondID,
                sequence: 1,
                stableText: "",
                partialText: "Исправленная вторая фраза",
                kind: .partial
            ))

        try expectEqual(session.combinedText, "Первая законченная фраза. Исправленная вторая фраза")
    },

    CheckCase(name: "An update replaces only the matching segment") {
        var session = TranscriptSession()
        let firstID = UUID()
        let secondID = UUID()

        session.apply(
            TranscriptSegmentUpdate(
                segmentID: firstID,
                sequence: 0,
                stableText: "Один",
                partialText: "",
                kind: .segmentFinal
            ))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: secondID,
                sequence: 1,
                stableText: "Два",
                partialText: "",
                kind: .segmentFinal
            ))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: secondID,
                sequence: 1,
                stableText: "Два исправлено",
                partialText: "",
                kind: .segmentFinal
            ))

        try expectEqual(session.segments.count, 2)
        try expectEqual(session.combinedText, "Один Два исправлено")
        try expectEqual(session.segments[0].revision, 1)
        try expectEqual(session.segments[1].revision, 2)
    },

    CheckCase(name: "Boundary bridge revises two final segments without duplicating the join") {
        var session = TranscriptSession()
        let previousID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let currentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        session.apply(
            TranscriptSegmentUpdate(
                segmentID: previousID,
                sequence: 4,
                stableText: "слева общий якорь старое",
                partialText: "",
                kind: .segmentFinal
            ))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: currentID,
                sequence: 5,
                stableText: "старое продолжение справа",
                partialText: "",
                kind: .segmentFinal
            ))

        session.apply(
            TranscriptSegmentUpdate(
                segmentID: previousID,
                sequence: 4,
                stableText: "слева общий якорь исправленный",
                partialText: "",
                kind: .segmentFinal
            ))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: currentID,
                sequence: 5,
                stableText: "переход продолжение справа",
                partialText: "",
                kind: .segmentFinal
            ))

        try expectEqual(session.segments.count, 2)
        try expectEqual(session.segments.map(\.id), [previousID, currentID])
        try expectEqual(session.segments.map(\.sequence), [4, 5])
        try expectEqual(session.segments.map(\.revision), [2, 2])
        try expectEqual(
            session.combinedText,
            "слева общий якорь исправленный переход продолжение справа"
        )
    },

    CheckCase(name: "Multiword overlap is removed between final segments") {
        var session = TranscriptSession()

        session.apply(
            TranscriptSegmentUpdate(
                segmentID: UUID(),
                sequence: 0,
                stableText: "это длинная тестовая фраза",
                partialText: "",
                kind: .segmentFinal
            ))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: UUID(),
                sequence: 1,
                stableText: "тестовая фраза продолжается дальше",
                partialText: "",
                kind: .sessionFinal
            ))

        try expectEqual(session.combinedText, "это длинная тестовая фраза продолжается дальше")
        try expect(session.isFinal, "session must be marked final")
    },

    CheckCase(name: "Finalized transcript excludes live draft-only segments") {
        var session = TranscriptSession()
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: UUID(), sequence: 0, stableText: "",
                partialText: "Apple draft must not be copied", kind: .partial
            ))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: UUID(), sequence: 1, stableText: "Final local text",
                partialText: "", kind: .segmentFinal
            ))
        try expectEqual(session.finalizedText, "Final local text")
    },

    CheckCase(name: "Transcript session preserves newlines between updates") {
        var session = TranscriptSession()
        let firstID = UUID()
        let breakID = UUID()
        let secondID = UUID()

        session.apply(
            TranscriptSegmentUpdate(
                segmentID: firstID,
                sequence: 0,
                stableText: "Первая строка",
                partialText: "",
                kind: .segmentFinal
            ))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: breakID,
                sequence: 1,
                stableText: "↵",
                partialText: "",
                kind: .segmentFinal
            ))
        session.apply(
            TranscriptSegmentUpdate(
                segmentID: secondID,
                sequence: 2,
                stableText: "Вторая строка",
                partialText: "",
                kind: .sessionFinal
            ))

        try expectEqual(session.combinedText, "Первая строка\nВторая строка")
    },
]
