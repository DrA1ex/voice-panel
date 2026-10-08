import Foundation

public struct WhisperBoundaryAcceptedChunk: Equatable, Sendable {
    public let segmentID: UUID
    public let sequence: Int
    public let result: WhisperTranscriptionResult
    public let boundaryReason: AudioChunkBoundaryReason
    public let audioDuration: TimeInterval

    public init(
        segmentID: UUID,
        sequence: Int,
        result: WhisperTranscriptionResult,
        boundaryReason: AudioChunkBoundaryReason,
        audioDuration: TimeInterval
    ) {
        self.segmentID = segmentID
        self.sequence = sequence
        self.result = result
        self.boundaryReason = boundaryReason
        self.audioDuration = audioDuration
    }
}

public struct WhisperBoundaryBridgeSource: Equatable, Sendable {
    public let segmentID: UUID
    public let sequence: Int
    public let result: WhisperTranscriptionResult
    public let boundaryReason: AudioChunkBoundaryReason
    public let audioDuration: TimeInterval
    public let resampledSamples: [Float]
    public let sampleRate: Double

    public init(
        chunk: WhisperBoundaryAcceptedChunk,
        resampledSamples: [Float],
        sampleRate: Double
    ) {
        segmentID = chunk.segmentID
        sequence = chunk.sequence
        result = chunk.result
        boundaryReason = chunk.boundaryReason
        audioDuration = chunk.audioDuration
        self.resampledSamples = resampledSamples
        self.sampleRate = sampleRate
    }

    public var acceptedChunk: WhisperBoundaryAcceptedChunk {
        WhisperBoundaryAcceptedChunk(
            segmentID: segmentID,
            sequence: sequence,
            result: result,
            boundaryReason: boundaryReason,
            audioDuration: audioDuration
        )
    }
}

public struct WhisperBoundarySessionState: Sendable {
    private static let maximumRetainedAudioDuration: TimeInterval = 3.5

    public private(set) var boundaryBridgeSource: WhisperBoundaryBridgeSource?
    public private(set) var repairAttemptCount = 0
    public private(set) var repairRejectionCount = 0

    public init() {}

    public var contextualRetrySource: WhisperBoundaryAcceptedChunk? {
        boundaryBridgeSource?.acceptedChunk
    }

    public mutating func recordAccepted(_ chunk: WhisperBoundaryAcceptedChunk) {
        recordAccepted(chunk, resampledSamples: [], sampleRate: 0)
    }

    public mutating func recordAccepted(
        _ chunk: WhisperBoundaryAcceptedChunk,
        resampledSamples: [Float],
        sampleRate: Double
    ) {
        guard chunk.boundaryReason == .maximumDuration, !chunk.result.text.isEmpty else {
            boundaryBridgeSource = nil
            return
        }
        let retainedSamples: [Float]
        let requestedSampleCount = Self.maximumRetainedAudioDuration * sampleRate
        if !sampleRate.isFinite || sampleRate <= 0 || !requestedSampleCount.isFinite {
            retainedSamples = []
        } else if requestedSampleCount < Double(resampledSamples.count) {
            var retainedSampleCount = Int(requestedSampleCount.rounded(.down))
            // Division can round one ULP above the duration bound at an exotic
            // fractional sample rate even though the multiplication was floored.
            if Double(retainedSampleCount) / sampleRate
                > Self.maximumRetainedAudioDuration
            {
                retainedSampleCount -= 1
            }
            retainedSamples = Array(
                resampledSamples.suffix(max(0, retainedSampleCount))
            )
        } else {
            retainedSamples = resampledSamples
        }
        boundaryBridgeSource = WhisperBoundaryBridgeSource(
            chunk: chunk,
            resampledSamples: retainedSamples,
            sampleRate: sampleRate
        )
    }

    public mutating func recordEmptyOutput() {
        boundaryBridgeSource = nil
    }

    public mutating func recordRejectedHallucination() {
        boundaryBridgeSource = nil
    }

    public mutating func recordError() {
        boundaryBridgeSource = nil
    }

    public mutating func recordCandidateFailure() {
        boundaryBridgeSource = nil
    }

    public mutating func recordCancellation() {
        boundaryBridgeSource = nil
    }

    public mutating func recordRepairAttempt() {
        repairAttemptCount += 1
    }

    public mutating func recordRepairRejection() {
        repairRejectionCount += 1
    }

    public func contextualRevision(
        from baseline: WhisperBoundaryAcceptedChunk,
        result: WhisperTranscriptionResult
    ) -> WhisperBoundaryAcceptedChunk {
        WhisperBoundaryAcceptedChunk(
            segmentID: baseline.segmentID,
            sequence: baseline.sequence,
            result: result,
            boundaryReason: baseline.boundaryReason,
            audioDuration: baseline.audioDuration
        )
    }

    public mutating func reset() {
        boundaryBridgeSource = nil
        repairAttemptCount = 0
        repairRejectionCount = 0
    }
}
