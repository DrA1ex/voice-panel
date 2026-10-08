import VoicePanelCore

let transcriptStabilizerChecks: [CheckCase] = [
    CheckCase(name: "Recent words stay partial until repeated") {
        var stabilizer = TranscriptStabilizer(trailingUnstableWordCount: 2)

        let first = stabilizer.update(hypothesis: "one two three four", isFinal: false)
        try expectEqual(first.stableText, "")
        try expectEqual(first.partialText, "one two three four")

        let second = stabilizer.update(hypothesis: "one two three four five", isFinal: false)
        try expectEqual(second.stableText, "one two")
        try expectEqual(second.partialText, "three four five")

        let final = stabilizer.update(hypothesis: "one two three four five.", isFinal: true)
        try expectEqual(final.stableText, "one two three four five.")
        try expectEqual(final.partialText, "")
    }
]
