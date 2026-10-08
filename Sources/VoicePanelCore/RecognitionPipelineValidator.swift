import Foundation

public struct RecognitionPipelineValidationChunk: Codable, Equatable, Sendable {
    public let boundaryReason: AudioChunkBoundaryReason
    public let duration: TimeInterval
    public let speechDuration: TimeInterval
    public let trailingOverlapDuration: TimeInterval

    public init(
        boundaryReason: AudioChunkBoundaryReason,
        duration: TimeInterval,
        speechDuration: TimeInterval,
        trailingOverlapDuration: TimeInterval = 0
    ) {
        self.boundaryReason = boundaryReason
        self.duration = duration
        self.speechDuration = speechDuration
        self.trailingOverlapDuration = max(0, trailingOverlapDuration)
    }

    private enum CodingKeys: String, CodingKey {
        case boundaryReason
        case duration
        case speechDuration
        case trailingOverlapDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            boundaryReason: try container.decode(
                AudioChunkBoundaryReason.self,
                forKey: .boundaryReason
            ),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            speechDuration: try container.decode(TimeInterval.self, forKey: .speechDuration),
            trailingOverlapDuration: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .trailingOverlapDuration
            ) ?? 0
        )
    }

    public var paddingDuration: TimeInterval {
        max(0, duration - speechDuration)
    }
}

public struct RecognitionPipelineValidationSummary: Codable, Equatable, Sendable {
    public let capturedDuration: TimeInterval
    public let minimumAcceptedDuration: TimeInterval
    public let acceptedByRecordingPolicy: Bool
    public let chunks: [RecognitionPipelineValidationChunk]
    public let rejectedResultCount: Int

    public init(
        capturedDuration: TimeInterval,
        minimumAcceptedDuration: TimeInterval,
        acceptedByRecordingPolicy: Bool,
        chunks: [RecognitionPipelineValidationChunk],
        rejectedResultCount: Int = 0
    ) {
        self.capturedDuration = capturedDuration
        self.minimumAcceptedDuration = minimumAcceptedDuration
        self.acceptedByRecordingPolicy = acceptedByRecordingPolicy
        self.chunks = chunks
        self.rejectedResultCount = max(0, rejectedResultCount)
    }

    public var acceptedAudioDuration: TimeInterval {
        chunks.reduce(0) { $0 + $1.duration }
    }

    public var detectedSpeechDuration: TimeInterval {
        chunks.reduce(0) { $0 + $1.speechDuration }
    }

    public var paddingDuration: TimeInterval {
        chunks.reduce(0) { $0 + $1.paddingDuration }
    }

    public var detectedSpeech: Bool {
        detectedSpeechDuration > 0
    }

    public func withRejectedResultCount(_ count: Int) -> RecognitionPipelineValidationSummary {
        RecognitionPipelineValidationSummary(
            capturedDuration: capturedDuration,
            minimumAcceptedDuration: minimumAcceptedDuration,
            acceptedByRecordingPolicy: acceptedByRecordingPolicy,
            chunks: chunks,
            rejectedResultCount: count
        )
    }
}

public enum RecognitionPipelineValidator {
    public struct Result: Sendable {
        public let chunks: [AudioChunk]
        public let summary: RecognitionPipelineValidationSummary

        public init(chunks: [AudioChunk], summary: RecognitionPipelineValidationSummary) {
            self.chunks = chunks
            self.summary = summary
        }
    }

    public static func process(
        samples: [Float],
        sampleRate: Double,
        vadConfiguration: VoiceActivityDetector.Configuration,
        segmenterConfiguration: AudioSegmenter.Configuration,
        detectionMode: VoiceActivityDetectionMode,
        minimumAcceptedDuration: TimeInterval = RecordingStopPolicy.defaultMinimumDuration,
        frameDuration: TimeInterval = 0.032,
        neuralSpeechDetector: (([Float], Double) -> Bool?)? = nil
    ) -> Result {
        guard !samples.isEmpty, sampleRate > 0 else {
            return Result(
                chunks: [],
                summary: RecognitionPipelineValidationSummary(
                    capturedDuration: 0,
                    minimumAcceptedDuration: minimumAcceptedDuration,
                    acceptedByRecordingPolicy: false,
                    chunks: []
                )
            )
        }

        let minimumDuration = max(0, minimumAcceptedDuration)
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: vadConfiguration,
            segmenterConfiguration: segmenterConfiguration,
            minimumChunkDeliveryDuration: minimumDuration,
            detectionMode: detectionMode
        )
        let frameSampleCount = max(1, Int((max(0.005, frameDuration) * sampleRate).rounded()))
        var emittedChunks: [AudioChunk] = []
        var offset = 0

        while offset < samples.count {
            let upperBound = min(samples.count, offset + frameSampleCount)
            let frame = Array(samples[offset..<upperBound])
            let rmsDB = decibels(from: frame)
            let neuralSpeech = neuralSpeechDetector?(frame, sampleRate)
            if let result = pipeline.process(
                samples: frame,
                sampleRate: sampleRate,
                rmsDB: rmsDB,
                neuralSpeechDetected: neuralSpeech
            ) {
                emittedChunks.append(contentsOf: result.chunks)
            }
            offset = upperBound
        }

        let stopResult = pipeline.stop(
            flushFinalChunk: true,
            forceChunkIfDurationAtLeast: minimumDuration
        )
        emittedChunks.append(contentsOf: stopResult.finalChunks)
        let accepted =
            RecordingStopPolicy.action(
                for: stopResult.capturedDuration,
                minimumDuration: minimumDuration
            ) == .flushAndFinalize
        if !accepted { emittedChunks.removeAll(keepingCapacity: false) }

        let chunkSummaries = emittedChunks.map { chunk in
            RecognitionPipelineValidationChunk(
                boundaryReason: chunk.boundaryReason,
                duration: chunk.duration,
                speechDuration: speechDuration(of: chunk),
                trailingOverlapDuration: chunk.trailingOverlapDuration
            )
        }
        return Result(
            chunks: emittedChunks,
            summary: RecognitionPipelineValidationSummary(
                capturedDuration: stopResult.capturedDuration,
                minimumAcceptedDuration: minimumDuration,
                acceptedByRecordingPolicy: accepted,
                chunks: chunkSummaries
            )
        )
    }

    private static func speechDuration(of chunk: AudioChunk) -> TimeInterval {
        guard chunk.sampleRate > 0 else { return 0 }
        if chunk.speechEvidenceAnalyzed {
            guard let range = chunk.speechRange else { return 0 }
            return Double(max(0, range.count)) / chunk.sampleRate
        }
        return chunk.duration
    }

    private static func decibels(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        let squareSum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(squareSum / Float(samples.count))
        return 20 * log10(max(rms, 0.000_001))
    }
}
