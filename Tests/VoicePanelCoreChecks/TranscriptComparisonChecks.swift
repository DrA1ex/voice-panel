import Foundation
import VoicePanelCore

let transcriptComparisonChecks: [CheckCase] = [
    CheckCase(name: "Transcript comparison marks only inserted and removed words") {
        let comparison = TranscriptComparison.compare(
            "это первая версия текста",
            "это обновлённая версия текста"
        )
        try expectEqual(comparison.removedWordCount, 1)
        try expectEqual(comparison.insertedWordCount, 1)
        try expectEqual(comparison.left.filter(\.isChanged).count, 1)
        try expectEqual(comparison.right.filter(\.isChanged).count, 1)
    },
    CheckCase(name: "Transcript comparison handles repeated boundary words") {
        let comparison = TranscriptComparison.compare(
            "мы проверили проверили результат",
            "мы проверили результат"
        )
        try expectEqual(comparison.removedWordCount, 1)
        try expectEqual(comparison.insertedWordCount, 0)
        try expectEqual(comparison.left.filter(\.isChanged).count, 1)
    },
]
