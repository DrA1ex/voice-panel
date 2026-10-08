import Foundation
import VoicePanelCore

let audioImportProgressChecks: [CheckCase] = [
    CheckCase(name: "audio import progress uses processed audio duration") {
        let progress = AudioImportProgress(
            stage: .transcribing,
            currentChunk: 3,
            completedChunks: 2,
            totalChunks: 8,
            completedAudioDuration: 20,
            totalAudioDuration: 80,
            elapsedProcessingDuration: 10,
            estimatedRemainingDuration: 30
        )
        try expectEqual(progress.fractionCompleted, 0.25)
    },
    CheckCase(name: "audio import ETA scales from measured throughput") {
        let estimate = AudioImportProgress.estimateRemainingDuration(
            elapsedProcessingDuration: 12,
            completedAudioDuration: 24,
            totalAudioDuration: 84
        )
        try expectEqual(estimate, 30)
    },
    CheckCase(name: "audio import ETA waits for a completed chunk") {
        let estimate = AudioImportProgress.estimateRemainingDuration(
            elapsedProcessingDuration: 8,
            completedAudioDuration: 0,
            totalAudioDuration: 60
        )
        try expectEqual(estimate, nil)
    },
    CheckCase(name: "audio import progress preserves visible fallback detail in value equality") {
        let fallback = AudioImportProgress(
            stage: .analyzing,
            fallbackDescription: "Continuous transcription failed. Retrying with Profile VAD."
        )
        let sameFallback = AudioImportProgress(
            stage: .analyzing,
            fallbackDescription: "Continuous transcription failed. Retrying with Profile VAD."
        )
        let ordinary = AudioImportProgress(stage: .analyzing)

        try expectEqual(fallback, sameFallback)
        try expectEqual(
            fallback.fallbackDescription,
            "Continuous transcription failed. Retrying with Profile VAD."
        )
        try expectEqual(fallback == ordinary, false)
    },
    CheckCase(name: "compact preparing fallback presents text below an indeterminate indicator") {
        let progress = AudioImportProgress(
            stage: .preparing,
            fallbackDescription: "Retrying with Profile VAD."
        )
        let presentation = CompactAudioImportPresentation.resolve(
            phase: .preparing,
            isImportingAudioFile: true,
            progress: progress,
            preparationProgress: nil
        )

        try expectEqual(presentation.content, .recording)
        try expectEqual(presentation.recordingLayout, .dedicatedImportProgress)
        try expectEqual(
            presentation.elements,
            [.indeterminateIndicator, .fallbackDescription("Retrying with Profile VAD.")]
        )
    },
    CheckCase(name: "compact ordinary preparation retains the transcript row") {
        let presentation = CompactAudioImportPresentation.resolve(
            phase: .preparing,
            isImportingAudioFile: true,
            progress: AudioImportProgress(stage: .preparing),
            preparationProgress: nil
        )

        try expectEqual(presentation.content, .recording)
        try expectEqual(presentation.recordingLayout, .standardRecording)
    },
    CheckCase(name: "compact second preparation failure selects failure content") {
        let presentation = CompactAudioImportPresentation.resolve(
            phase: .failed,
            isImportingAudioFile: false,
            progress: nil,
            preparationProgress: nil
        )

        try expectEqual(presentation.content, .failure)
        try expectEqual(presentation.recordingLayout, .standardRecording)
        try expectEqual(presentation.elements, [])
    },
]
