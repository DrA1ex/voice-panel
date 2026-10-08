public enum RecognitionQueuedResultPolicy {
    /// finish() closes the input queue, but does not invalidate work that was
    /// accepted before the close. Only cancellation/generation replacement or
    /// an inactive session may suppress that result.
    public static func shouldPublish(
        generationMatches: Bool,
        sessionIsActive: Bool
    ) -> Bool {
        generationMatches && sessionIsActive
    }
}
