import Foundation

/// Defines the ordering contract at the recording/recognizer boundary.
/// Every final chunk must enter the recognizer before it is told that no more
/// audio is coming.
public enum RecognitionStopHandoff {
    public static func perform(
        finalChunks: [AudioChunk],
        acceptsChunks: Bool,
        append: (AudioChunk) -> Void,
        prepareToFinish: () -> Void,
        finish: () -> Void
    ) {
        if acceptsChunks {
            for chunk in finalChunks {
                append(chunk)
            }
        }
        prepareToFinish()
        finish()
    }
}
