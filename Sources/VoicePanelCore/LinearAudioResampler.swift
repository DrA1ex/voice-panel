import Foundation

public enum LinearAudioResampler {
    public static let whisperSampleRate: Double = 16_000

    public static func resampleMono(
        samples: [Float],
        from sourceSampleRate: Double,
        to targetSampleRate: Double = whisperSampleRate
    ) -> [Float] {
        guard !samples.isEmpty,
            sourceSampleRate > 0,
            targetSampleRate > 0
        else {
            return []
        }

        if abs(sourceSampleRate - targetSampleRate) < 0.5 {
            return samples
        }

        let outputCount = max(
            1,
            Int((Double(samples.count) * targetSampleRate / sourceSampleRate).rounded())
        )
        let sourceLastIndex = samples.count - 1
        let sourceStep = sourceSampleRate / targetSampleRate
        var output = Array(repeating: Float(0), count: outputCount)

        for outputIndex in 0..<outputCount {
            let sourcePosition = min(
                Double(sourceLastIndex),
                Double(outputIndex) * sourceStep
            )
            let lowerIndex = min(sourceLastIndex, Int(sourcePosition.rounded(.down)))
            let upperIndex = min(sourceLastIndex, lowerIndex + 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            output[outputIndex] = samples[lowerIndex] * (1 - fraction) + samples[upperIndex] * fraction
        }

        return output
    }
}

/// Preserves fractional sample position across successive real-time buffers.
/// Stateless per-buffer resampling rounds every buffer independently, which can
/// gradually lose samples and introduce a small discontinuity at each boundary.
public struct StreamingLinearAudioResampler: Sendable {
    public let targetSampleRate: Double

    private var sourceSampleRate: Double?
    private var storage: [Float] = []
    private var storageHead = 0
    private var storageStartIndex: Int64 = 0
    private var nextSourcePosition: Double = 0

    public init(targetSampleRate: Double = LinearAudioResampler.whisperSampleRate) {
        self.targetSampleRate = targetSampleRate
    }

    public mutating func process(
        samples: [Float],
        from newSourceSampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty,
            newSourceSampleRate > 0,
            targetSampleRate > 0
        else {
            return []
        }

        if abs(newSourceSampleRate - targetSampleRate) < 0.5 {
            reset()
            sourceSampleRate = newSourceSampleRate
            return samples
        }

        if let sourceSampleRate,
            abs(sourceSampleRate - newSourceSampleRate) >= 0.5
        {
            reset()
        }
        sourceSampleRate = newSourceSampleRate
        storage.append(contentsOf: samples)

        let activeCount = storage.count - storageHead
        guard activeCount > 0 else { return [] }

        let endIndex = storageStartIndex + Int64(activeCount)
        let sourceStep = newSourceSampleRate / targetSampleRate
        let estimatedCount = max(
            0,
            Int((Double(activeCount) * targetSampleRate / newSourceSampleRate).rounded(.up))
        )
        var output: [Float] = []
        output.reserveCapacity(estimatedCount)

        while true {
            let lowerGlobalIndex = Int64(nextSourcePosition.rounded(.down))
            guard lowerGlobalIndex >= storageStartIndex,
                lowerGlobalIndex < endIndex
            else {
                break
            }

            let fraction = nextSourcePosition - Double(lowerGlobalIndex)
            let needsUpperSample = fraction > 0.000_000_1
            if needsUpperSample, lowerGlobalIndex + 1 >= endIndex {
                break
            }

            let lowerLocalIndex = storageHead + Int(lowerGlobalIndex - storageStartIndex)
            let upperLocalIndex = needsUpperSample ? lowerLocalIndex + 1 : lowerLocalIndex
            let interpolation = Float(fraction)
            output.append(
                storage[lowerLocalIndex] * (1 - interpolation)
                    + storage[upperLocalIndex] * interpolation
            )
            nextSourcePosition += sourceStep
        }

        discardConsumedPrefix()
        return output
    }

    public mutating func reset() {
        sourceSampleRate = nil
        storage.removeAll(keepingCapacity: true)
        storageHead = 0
        storageStartIndex = 0
        nextSourcePosition = 0
    }

    private mutating func discardConsumedPrefix() {
        let activeCount = storage.count - storageHead
        guard activeCount > 0 else { return }

        let nextLowerIndex = Int64(nextSourcePosition.rounded(.down))
        let dropCount = min(
            activeCount,
            max(0, Int(nextLowerIndex - storageStartIndex))
        )
        guard dropCount > 0 else { return }

        storageHead += dropCount
        storageStartIndex += Int64(dropCount)

        if storageHead >= 4_096, storageHead * 2 >= storage.count {
            storage.removeFirst(storageHead)
            storageHead = 0
        }
    }
}

/// Accumulates adjacent audio buffers without resampling each buffer in
/// isolation. The complete sample is converted once, avoiding per-buffer
/// rounding drift and a large number of temporary arrays in benchmark capture.
public struct LinearAudioSampleAccumulator: Sendable {
    private var samples: [Float] = []
    private var sourceSampleRate: Double?

    public init() {}

    public var isEmpty: Bool { samples.isEmpty }
    public var sampleCount: Int { samples.count }

    public mutating func append(samples newSamples: [Float], sampleRate: Double) {
        guard !newSamples.isEmpty, sampleRate > 0 else { return }

        guard let sourceSampleRate else {
            self.sourceSampleRate = sampleRate
            samples.append(contentsOf: newSamples)
            return
        }

        if abs(sourceSampleRate - sampleRate) < 0.5 {
            samples.append(contentsOf: newSamples)
        } else {
            samples.append(
                contentsOf: LinearAudioResampler.resampleMono(
                    samples: newSamples,
                    from: sampleRate,
                    to: sourceSampleRate
                )
            )
        }
    }

    public func resampled(to targetSampleRate: Double) -> [Float] {
        guard let sourceSampleRate else { return [] }
        return LinearAudioResampler.resampleMono(
            samples: samples,
            from: sourceSampleRate,
            to: targetSampleRate
        )
    }

    public mutating func reset(keepingCapacity: Bool = true) {
        samples.removeAll(keepingCapacity: keepingCapacity)
        sourceSampleRate = nil
    }
}
