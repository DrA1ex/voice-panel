#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
SWIFTC="$SWIFTC_BIN"

cat > "$TMP_DIR/sherpa_onnx.swift" <<'SWIFT'
import Foundation

public struct SherpaOnnxFeatureConfig {
    public var sample_rate: Int32 = 0
    public var feature_dim: Int32 = 0
    public init() {}
}
public struct SherpaOnnxOfflineTransducerModelConfig {
    public var encoder: UnsafePointer<CChar>? = nil
    public var decoder: UnsafePointer<CChar>? = nil
    public var joiner: UnsafePointer<CChar>? = nil
    public init() {}
}
public struct SherpaOnnxOfflineQwen3ASRModelConfig {
    public var conv_frontend: UnsafePointer<CChar>? = nil
    public var encoder: UnsafePointer<CChar>? = nil
    public var decoder: UnsafePointer<CChar>? = nil
    public var tokenizer: UnsafePointer<CChar>? = nil
    public var max_total_len: Int32 = 0
    public var max_new_tokens: Int32 = 0
    public var temperature: Float = 0
    public var top_p: Float = 0
    public var seed: Int32 = 0
    public var hotwords: UnsafePointer<CChar>? = nil
    public init() {}
}
public struct SherpaOnnxOfflineModelConfig {
    public var transducer = SherpaOnnxOfflineTransducerModelConfig()
    public var qwen3_asr = SherpaOnnxOfflineQwen3ASRModelConfig()
    public var tokens: UnsafePointer<CChar>? = nil
    public var num_threads: Int32 = 0
    public var provider: UnsafePointer<CChar>? = nil
    public var debug: Int32 = 0
    public var model_type: UnsafePointer<CChar>? = nil
    public init() {}
}
public struct SherpaOnnxOfflineRecognizerConfig {
    public var feat_config = SherpaOnnxFeatureConfig()
    public var model_config = SherpaOnnxOfflineModelConfig()
    public var decoding_method: UnsafePointer<CChar>? = nil
    public var max_active_paths: Int32 = 0
    public var hotwords_score: Float = 0
    public init() {}
}
public struct SherpaOnnxOfflineRecognizerResult {
    public var text: UnsafePointer<CChar>? = nil
    public init() {}
}

public func SherpaOnnxCreateOfflineRecognizer(
    _ config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>?
) -> OpaquePointer? { OpaquePointer(bitPattern: 1) }
public func SherpaOnnxDestroyOfflineRecognizer(_ recognizer: OpaquePointer?) {}
public func SherpaOnnxCreateOfflineStream(_ recognizer: OpaquePointer?) -> OpaquePointer? {
    OpaquePointer(bitPattern: 2)
}
public func SherpaOnnxDestroyOfflineStream(_ stream: OpaquePointer?) {}
public func SherpaOnnxAcceptWaveformOffline(
    _ stream: OpaquePointer?,
    _ sampleRate: Int32,
    _ samples: UnsafePointer<Float>?,
    _ count: Int32
) {}
public func SherpaOnnxDecodeOfflineStream(_ recognizer: OpaquePointer?, _ stream: OpaquePointer?) {}
public func SherpaOnnxGetOfflineStreamResult(
    _ stream: OpaquePointer?
) -> UnsafePointer<SherpaOnnxOfflineRecognizerResult>? { nil }
public func SherpaOnnxDestroyOfflineRecognizerResult(
    _ result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>?
) {}
SWIFT

cat > "$TMP_DIR/VoicePanelCore.swift" <<'SWIFT'
import Foundation

public enum AudioChunkBoundaryReason: String, Equatable, Sendable {
    case silence
    case maximumDuration
    case balancedPause
    case stopped
    case inputChanged
}

public struct AudioChunk: Equatable, Sendable {
    public let id: UUID
    public let samples: [Float]
    public let sampleRate: Double
    public let boundaryReason: AudioChunkBoundaryReason
    public let trailingOverlapDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        samples: [Float],
        sampleRate: Double,
        boundaryReason: AudioChunkBoundaryReason,
        trailingOverlapDuration: TimeInterval = 0
    ) {
        self.id = id
        self.samples = samples
        self.sampleRate = sampleRate
        self.boundaryReason = boundaryReason
        self.trailingOverlapDuration = trailingOverlapDuration
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

public struct OfflineASRChunkPolicy: Equatable, Sendable {
    public var preferredDuration: TimeInterval = 15
    public var maximumDuration: TimeInterval = 20
    public var overlapDuration: TimeInterval = 0.4
    public var boundarySearchDuration: TimeInterval = 2
    public var retryCount: Int = 1
    public var splitOnFailure: Bool = true

    public init() {}
    public func normalized() -> OfflineASRChunkPolicy { self }
    public func split(_ chunk: AudioChunk) -> [AudioChunk] { [chunk] }
}

public enum TranscriptSegmentUpdateKind: String, Equatable, Sendable {
    case partial
    case segmentFinal
    case sessionFinal
}

public struct TranscriptSegmentUpdate: Equatable, Sendable {
    public let segmentID: UUID
    public let sequence: Int
    public let stableText: String
    public let partialText: String
    public let kind: TranscriptSegmentUpdateKind

    public init(
        segmentID: UUID,
        sequence: Int,
        stableText: String,
        partialText: String,
        kind: TranscriptSegmentUpdateKind
    ) {
        self.segmentID = segmentID
        self.sequence = sequence
        self.stableText = stableText
        self.partialText = partialText
        self.kind = kind
    }
}

public enum TranscriptTextNormalizer {
    public static func normalize(_ text: String) -> String { text }
}

public enum TranscriptTextMerger {
    public static func merge(_ texts: [String]) -> String { texts.joined(separator: " ") }
}

public enum LinearAudioResampler {
    public static func resampleMono(samples: [Float], from sampleRate: Double) -> [Float] { samples }
}

public struct RecognitionHallucinationGuard: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var isEnabled: Bool
        public init(isEnabled: Bool = false) { self.isEnabled = isEnabled }
        public static let disabled = Configuration()
    }

    public init() {}

    public func rejectionReason(
        for text: String,
        chunk: AudioChunk,
        configuration: Configuration
    ) -> String? { nil }
}

public enum RecognitionQueuedResultPolicy {
    public static func shouldPublish(
        generationMatches: Bool,
        sessionIsActive: Bool
    ) -> Bool {
        generationMatches && sessionIsActive
    }
}
SWIFT

cat > "$TMP_DIR/AppStubs.swift" <<'SWIFT'
import Foundation
import VoicePanelCore

final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()
    func beginModelLoad(engine: String, modelID: String, modelURL: URL) -> UUID { UUID() }
    func endModelLoad(token: UUID, engine: String, modelID: String, result: String) {}
}

enum RecognitionEngineError: Error {
    case modelCouldNotBeLoaded(String)
    case localONNXInferenceFailed(String)
}

enum RecognitionChunkOutcome {
    case completed(UUID)
    case failed(UUID, message: String)
}

enum RecognitionAudioInputMode {
    case continuousBuffers
    case vadChunks
}

struct RecognitionUpdate {
    let segment: TranscriptSegmentUpdate
    let shouldDimPartialText: Bool
}

struct RecognitionPerformanceMetrics {
    let engineName: String
    let queueDepth: Int
    let chunkDuration: TimeInterval
    let processingDuration: TimeInterval
}

protocol RecognitionEngine: AnyObject {
    var audioInputMode: RecognitionAudioInputMode { get }
    var finalizationTimeout: TimeInterval { get }
    var displayName: String { get }
    var onUpdate: ((RecognitionUpdate) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)? { get set }
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func requestAuthorization() async throws
    func start(localeIdentifier: String) async throws
    func append(_ chunk: AudioChunk)
    func finish()
    func cancel()
}
SWIFT

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name sherpa_onnx \
    "$TMP_DIR/sherpa_onnx.swift" -emit-module-path "$TMP_DIR/sherpa_onnx.swiftmodule"
"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name VoicePanelCore \
    "$TMP_DIR/VoicePanelCore.swift" -emit-module-path "$TMP_DIR/VoicePanelCore.swiftmodule"

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -typecheck -swift-version 5 -I "$TMP_DIR" \
    "$TMP_DIR/AppStubs.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/LocalONNX/LocalONNXModelCatalog.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/LocalONNX/LocalONNXRuntime.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/LocalONNXRecognitionEngine.swift"

echo "Qwen3-ASR and Parakeet sherpa-onnx bridge type-check passed."
