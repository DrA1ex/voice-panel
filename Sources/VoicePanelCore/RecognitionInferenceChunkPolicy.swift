import Foundation

public enum RecognitionInferenceChunkPolicy {
    /// The segmenter has already applied the active profile's pre-roll and
    /// post-roll. Admission may reject a chunk proven silent, but must not
    /// trim accepted audio again and silently override those profile margins.
    public static func admittedChunk(_ chunk: AudioChunk) -> AudioChunk? {
        chunk.speechEvidenceAnalyzed && chunk.speechRange == nil ? nil : chunk
    }
}
