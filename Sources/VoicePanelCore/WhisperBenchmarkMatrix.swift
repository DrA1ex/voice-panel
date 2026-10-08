import Foundation

public enum WhisperBenchmarkVariant: Hashable, Identifiable, Sendable {
    case standard
    case legacyContext
    case contextualRetry(WhisperContextPromptMode)
    case boundaryBridge
    case continuousFullAudio

    public var id: String {
        switch self {
        case .standard:
            return "standard"
        case .legacyContext:
            return "legacy-context-control"
        case .contextualRetry(.legacyFixedWords):
            return "contextual-retry-legacy-fixed-words"
        case .contextualRetry(.lexicalOverlapAligned):
            return "contextual-retry-lexical-overlap-aligned"
        case .contextualRetry(.timestampAligned):
            return "contextual-retry-timestamp-aligned"
        case .boundaryBridge:
            return "boundary-bridge"
        case .continuousFullAudio:
            return "continuous-full-audio"
        }
    }

    public var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .legacyContext:
            return "Legacy Context (control)"
        case .contextualRetry(.legacyFixedWords):
            return "Contextual Retry — Legacy Fixed Words"
        case .contextualRetry(.lexicalOverlapAligned):
            return "Contextual Retry — Lexical Overlap"
        case .contextualRetry(.timestampAligned):
            return "Contextual Retry — Timestamp Aligned"
        case .boundaryBridge:
            return "Boundary Bridge"
        case .continuousFullAudio:
            return "Continuous Full Audio"
        }
    }

    public var usesExternalBoundaries: Bool {
        self != .continuousFullAudio
    }
}

extension WhisperBenchmarkVariant: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let identifier = try container.decode(String.self)
        guard let variant = Self.allCasesByIdentifier[identifier] else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown Whisper benchmark variant identifier: \(identifier)"
            )
        }
        self = variant
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    private static let allCasesByIdentifier = Dictionary(
        uniqueKeysWithValues: WhisperBenchmarkMatrix.defaultVariants.map { ($0.id, $0) }
    )
}

public struct WhisperBenchmarkAudioConfiguration: Codable, Equatable, Sendable {
    public let edgePadding: TimeInterval
    public let maximumChunkDurationOffset: TimeInterval

    public init(
        edgePadding: TimeInterval,
        maximumChunkDurationOffset: TimeInterval
    ) {
        self.edgePadding = edgePadding.isFinite ? min(max(0, edgePadding), 30) : 0
        self.maximumChunkDurationOffset =
            maximumChunkDurationOffset.isFinite ? maximumChunkDurationOffset : 0
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            edgePadding: try container.decode(TimeInterval.self, forKey: .edgePadding),
            maximumChunkDurationOffset: try container.decode(
                TimeInterval.self,
                forKey: .maximumChunkDurationOffset
            )
        )
    }

    public func edgePaddingSampleCount(sampleRate: Double) -> Int? {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let count = (edgePadding * sampleRate).rounded()
        guard count.isFinite, count >= 0, count < Double(Int.max) else { return nil }
        return Int(count)
    }

    public func paddedSamples(
        _ samples: [Float],
        sampleRate: Double = 16_000
    ) -> [Float] {
        guard !samples.isEmpty,
            let silenceSampleCount = edgePaddingSampleCount(sampleRate: sampleRate),
            silenceSampleCount > 0,
            silenceSampleCount <= (Int.max - samples.count) / 2
        else { return samples }

        var padded = [Float]()
        padded.reserveCapacity(samples.count + (silenceSampleCount * 2))
        padded.append(contentsOf: repeatElement(0, count: silenceSampleCount))
        padded.append(contentsOf: samples)
        padded.append(contentsOf: repeatElement(0, count: silenceSampleCount))
        return padded
    }

    public func maximumChunkDuration(from profileDuration: TimeInterval) -> TimeInterval {
        let base = profileDuration.isFinite ? profileDuration : 2
        return min(max(base + maximumChunkDurationOffset, 2), 30)
    }
}

public struct WhisperBenchmarkMatrixEntry: Codable, Equatable, Identifiable, Sendable {
    public let variant: WhisperBenchmarkVariant
    public let audioConfiguration: WhisperBenchmarkAudioConfiguration?

    public var id: String {
        guard let audioConfiguration else { return variant.id }
        return
            "\(variant.id)-padding-\(audioConfiguration.edgePadding)-offset-"
            + "\(audioConfiguration.maximumChunkDurationOffset)"
    }

    public init(
        variant: WhisperBenchmarkVariant,
        audioConfiguration: WhisperBenchmarkAudioConfiguration?
    ) {
        self.variant = variant
        self.audioConfiguration = variant.usesExternalBoundaries ? audioConfiguration : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            variant: try container.decode(WhisperBenchmarkVariant.self, forKey: .variant),
            audioConfiguration: try container.decodeIfPresent(
                WhisperBenchmarkAudioConfiguration.self,
                forKey: .audioConfiguration
            )
        )
    }
}

public enum WhisperBenchmarkMatrix {
    public static let defaultVariants: [WhisperBenchmarkVariant] = [
        .standard,
        .legacyContext,
        .contextualRetry(.legacyFixedWords),
        .contextualRetry(.lexicalOverlapAligned),
        .contextualRetry(.timestampAligned),
        .boundaryBridge,
        .continuousFullAudio,
    ]

    public static func make(
        edgePaddings: [TimeInterval],
        maximumChunkDurationOffset: TimeInterval
    ) -> [WhisperBenchmarkMatrixEntry] {
        defaultVariants.flatMap { variant in
            guard variant.usesExternalBoundaries else {
                return [WhisperBenchmarkMatrixEntry(variant: variant, audioConfiguration: nil)]
            }
            return edgePaddings.map { padding in
                WhisperBenchmarkMatrixEntry(
                    variant: variant,
                    audioConfiguration: WhisperBenchmarkAudioConfiguration(
                        edgePadding: padding,
                        maximumChunkDurationOffset: maximumChunkDurationOffset
                    )
                )
            }
        }
    }
}
