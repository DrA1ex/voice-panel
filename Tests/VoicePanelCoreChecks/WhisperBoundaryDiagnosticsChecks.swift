import Foundation
import VoicePanelCore

let whisperBoundaryDiagnosticsChecks: [CheckCase] = [
    CheckCase(name: "boundary diagnostics clamp ordinary numeric metadata") {
        let diagnostics = WhisperBoundaryRepairDiagnostics(
            strategy: .boundaryBridge,
            attempted: true,
            accepted: false,
            reasonCode: .candidateFailed,
            inferenceCount: 100,
            inferenceDuration: 100_000,
            changedBoundaryWordCounts: .init(
                baseline: -4,
                replacement: 100
            )
        )

        try expectEqual(diagnostics.inferenceCount, 2)
        try expect(diagnostics.inferenceDuration <= 3_600, "diagnostic timing was not bounded")
        try expectEqual(diagnostics.changedBoundaryWordCounts.baseline, 0)
        try expectEqual(diagnostics.changedBoundaryWordCounts.replacement, 24)
    },
    CheckCase(name: "boundary diagnostics replace invalid timings with zero") {
        for duration in [Double.nan, .infinity, -.infinity, -1] {
            let diagnostics = WhisperBoundaryRepairDiagnostics(
                strategy: .contextualRetry,
                attempted: true,
                accepted: false,
                reasonCode: .candidateCancelled,
                inferenceCount: 2,
                inferenceDuration: duration,
                changedBoundaryWordCounts: .init(baseline: 0, replacement: 0)
            )

            try expectEqual(diagnostics.inferenceDuration, 0)
        }
    },
    CheckCase(name: "encoded boundary diagnostics contain only bounded metadata") {
        let privateValues = [
            "private baseline sentence",
            "private candidate sentence",
            "private source sentence",
        ]
        let diagnostics = WhisperBoundaryRepairDiagnostics(
            strategy: .contextualRetry,
            attempted: true,
            accepted: true,
            reasonCode: .accepted,
            inferenceCount: 2,
            inferenceDuration: 1.25,
            changedBoundaryWordCounts: .init(baseline: 3, replacement: 4)
        )

        let data = try JSONEncoder().encode(diagnostics)
        let object = try JSONSerialization.jsonObject(with: data)
        let encodedKeys = recursivelyCollectedKeys(from: object)
        let encodedStrings = recursivelyCollectedStrings(from: object)
        let forbiddenTextKeys = Set([
            "baselineText",
            "candidateText",
            "sourceText",
            "transcript",
            "prompt",
        ])

        try expect(
            encodedKeys.isDisjoint(with: forbiddenTextKeys),
            "diagnostic JSON contained a transcript-bearing key"
        )
        try expect(
            Set(encodedStrings).isDisjoint(with: privateValues),
            "diagnostic JSON contained private recognition text"
        )

        let decoded = try JSONDecoder().decode(
            WhisperBoundaryRepairDiagnostics.self,
            from: data
        )
        try expectEqual(decoded, diagnostics)
    },
    CheckCase(name: "boundary diagnostics decoding applies missing-field defaults") {
        let diagnostics = try JSONDecoder().decode(
            WhisperBoundaryRepairDiagnostics.self,
            from: Data("{}".utf8)
        )

        try expectEqual(diagnostics.strategy, .standard)
        try expectEqual(diagnostics.attempted, false)
        try expectEqual(diagnostics.accepted, false)
        try expectEqual(diagnostics.reasonCode, .baselineOnly)
        try expectEqual(diagnostics.inferenceCount, 0)
        try expectEqual(diagnostics.inferenceDuration, 0)
        try expectEqual(diagnostics.changedBoundaryWordCounts, .init(baseline: 0, replacement: 0))
    },
    CheckCase(name: "boundary diagnostics decoding reapplies numeric bounds") {
        let data = Data(
            #"""
            {
              "strategy": "boundaryBridge",
              "attempted": true,
              "accepted": false,
              "reasonCode": "candidateFailed",
              "inferenceCount": 99,
              "inferenceDuration": 100000,
              "changedBoundaryWordCounts": {
                "baseline": -7,
                "replacement": 100
              }
            }
            """#.utf8
        )
        let diagnostics = try JSONDecoder().decode(
            WhisperBoundaryRepairDiagnostics.self,
            from: data
        )

        try expectEqual(diagnostics.strategy, .boundaryBridge)
        try expectEqual(diagnostics.inferenceCount, 2)
        try expectEqual(diagnostics.inferenceDuration, 3_600)
        try expectEqual(diagnostics.changedBoundaryWordCounts.baseline, 0)
        try expectEqual(diagnostics.changedBoundaryWordCounts.replacement, 24)

        let nonfiniteData = try PropertyListSerialization.data(
            fromPropertyList: ["inferenceDuration": Double.nan],
            format: .binary,
            options: 0
        )
        let nonfinite = try PropertyListDecoder().decode(
            WhisperBoundaryRepairDiagnostics.self,
            from: nonfiniteData
        )
        try expectEqual(nonfinite.inferenceDuration, 0)
    },
    CheckCase(name: "changed word counts decoding defaults and clamps individual fields") {
        let missing = try JSONDecoder().decode(
            WhisperBoundaryChangedWordCounts.self,
            from: Data(#"{"replacement":4}"#.utf8)
        )
        try expectEqual(missing.baseline, 0)
        try expectEqual(missing.replacement, 4)

        let malformed = try JSONDecoder().decode(
            WhisperBoundaryChangedWordCounts.self,
            from: Data(#"{"baseline":-1,"replacement":99}"#.utf8)
        )
        try expectEqual(malformed.baseline, 0)
        try expectEqual(malformed.replacement, 24)
    },
]

private func recursivelyCollectedKeys(from value: Any) -> Set<String> {
    if let dictionary = value as? [String: Any] {
        return dictionary.reduce(into: Set(dictionary.keys)) { result, entry in
            result.formUnion(recursivelyCollectedKeys(from: entry.value))
        }
    }
    if let array = value as? [Any] {
        return array.reduce(into: []) { result, element in
            result.formUnion(recursivelyCollectedKeys(from: element))
        }
    }
    return []
}

private func recursivelyCollectedStrings(from value: Any) -> [String] {
    if let string = value as? String { return [string] }
    if let dictionary = value as? [String: Any] {
        return dictionary.values.flatMap(recursivelyCollectedStrings)
    }
    if let array = value as? [Any] {
        return array.flatMap(recursivelyCollectedStrings)
    }
    return []
}
