import Foundation

public enum GigaAMInferenceLimit {
    public static let sampleRate: Double = 16_000
    /// Leave two seconds of safety headroom below GigaAM's 25-second model limit.
    public static let maximumDuration: TimeInterval = 23
    public static let maximumSampleCount = Int(sampleRate * maximumDuration)

    public static func accepts(sampleCount: Int) -> Bool {
        sampleCount <= maximumSampleCount
    }
}

public struct OfflineASRChunkPolicy: Equatable, Sendable {
    public var preferredDuration: TimeInterval
    public var maximumDuration: TimeInterval
    public var overlapDuration: TimeInterval
    public var boundarySearchDuration: TimeInterval
    public var retryCount: Int
    public var splitOnFailure: Bool

    public init(
        preferredDuration: TimeInterval = 18,
        maximumDuration: TimeInterval = 20,
        overlapDuration: TimeInterval = 0.4,
        boundarySearchDuration: TimeInterval = 2,
        retryCount: Int = 1,
        splitOnFailure: Bool = true
    ) {
        self.preferredDuration = preferredDuration
        self.maximumDuration = maximumDuration
        self.overlapDuration = overlapDuration
        self.boundarySearchDuration = boundarySearchDuration
        self.retryCount = retryCount
        self.splitOnFailure = splitOnFailure
        normalize()
    }

    public mutating func normalize() {
        maximumDuration = min(max(maximumDuration, 3), 20)
        preferredDuration = min(max(preferredDuration, 2), maximumDuration)
        overlapDuration = min(max(overlapDuration, 0), min(2, maximumDuration / 4))
        boundarySearchDuration = min(max(boundarySearchDuration, 0), 5)
        retryCount = min(max(retryCount, 0), 3)
    }

    public func normalized() -> OfflineASRChunkPolicy {
        var copy = self
        copy.normalize()
        return copy
    }

    public func segmenterConfiguration(
        preRollDuration: TimeInterval = 0.25,
        postRollDuration: TimeInterval = 0.15,
        maximumDurationLimit: TimeInterval? = nil
    ) -> AudioSegmenter.Configuration {
        let value = normalized()
        // Let VAD close the chunk on a natural pause. During uninterrupted
        // speech, wait only through the configured boundary-search window and
        // then force a cut, while the recognition engine still enforces the
        // independent hard maximum as a final safety boundary.
        var softLimit = min(
            value.maximumDuration,
            value.preferredDuration + value.boundarySearchDuration
        )
        if let maximumDurationLimit,
            maximumDurationLimit.isFinite,
            maximumDurationLimit > 0
        {
            softLimit = min(softLimit, maximumDurationLimit)
        }
        return AudioSegmenter.Configuration(
            preRollDuration: preRollDuration,
            postRollDuration: postRollDuration,
            overlapDuration: value.overlapDuration,
            maximumChunkDuration: softLimit,
            minimumChunkDuration: 0.25
        )
    }

    public func split(_ chunk: AudioChunk) -> [AudioChunk] {
        let value = normalized()
        guard value.splitOnFailure,
            chunk.duration > 1,
            chunk.samples.count >= 2
        else { return [chunk] }

        let overlapSamples = max(0, Int((value.overlapDuration * chunk.sampleRate).rounded()))
        let midpoint = chunk.samples.count / 2
        let leftEnd = min(chunk.samples.count, midpoint + overlapSamples / 2)
        let rightStart = max(0, midpoint - overlapSamples / 2)
        guard leftEnd > 0, rightStart < chunk.samples.count else { return [chunk] }
        let actualOverlapDuration =
            chunk.sampleRate > 0 ? Double(max(0, leftEnd - rightStart)) / chunk.sampleRate : 0

        return [
            AudioChunk(
                samples: Array(chunk.samples[..<leftEnd]),
                sampleRate: chunk.sampleRate,
                boundaryReason: .maximumDuration,
                trailingOverlapDuration: actualOverlapDuration
            ),
            AudioChunk(
                samples: Array(chunk.samples[rightStart...]),
                sampleRate: chunk.sampleRate,
                boundaryReason: chunk.boundaryReason,
                trailingOverlapDuration: chunk.trailingOverlapDuration
            ),
        ]
    }

    /// Applies the independent inference ceiling before audio reaches the model.
    /// This is intentionally separate from VAD segmentation: imported audio,
    /// benchmarks, or future callers may supply a chunk from another source.
    public func chunksBoundedToInferenceLimit(_ chunk: AudioChunk) -> [AudioChunk] {
        let value = normalized()
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0 else { return [chunk] }
        let maximumSampleCount = max(
            1,
            Int((GigaAMInferenceLimit.maximumDuration * chunk.sampleRate).rounded(.down))
        )
        guard chunk.samples.count > maximumSampleCount else { return [chunk] }

        let overlapSampleCount = max(
            0,
            Int((value.overlapDuration * chunk.sampleRate).rounded(.down))
        )
        let step = max(1, maximumSampleCount - overlapSampleCount)
        var chunks: [AudioChunk] = []
        var start = 0
        while start < chunk.samples.count {
            let end = min(chunk.samples.count, start + maximumSampleCount)
            chunks.append(
                AudioChunk(
                    samples: Array(chunk.samples[start..<end]),
                    sampleRate: chunk.sampleRate,
                    boundaryReason: end == chunk.samples.count
                        ? chunk.boundaryReason : .maximumDuration,
                    trailingOverlapDuration: end == chunk.samples.count
                        ? chunk.trailingOverlapDuration
                        : Double(max(0, end - min(chunk.samples.count, start + step)))
                            / chunk.sampleRate
                ))
            if end == chunk.samples.count { break }
            start += step
        }
        return chunks
    }
}

public typealias GigaAMChunkPolicy = OfflineASRChunkPolicy
