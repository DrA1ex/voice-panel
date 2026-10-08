import Foundation

/// Buffers captured chunks until a recognition engine is ready, then routes
/// both the buffered prefix and all subsequent chunks through one ordered path.
public final class RecognitionDeferredChunkHandoff: @unchecked Sendable {
    public typealias Destination = (AudioChunk) -> Void

    private let lock = NSLock()
    private var pendingChunks: [AudioChunk] = []
    private var destination: Destination?

    public init() {}

    public func append(_ chunk: AudioChunk) {
        let destination: Destination? = withLock {
            guard let destination = self.destination else {
                pendingChunks.append(chunk)
                return nil
            }
            return destination
        }
        destination?(chunk)
    }

    /// Attaches exactly once and delivers the buffered prefix synchronously in
    /// capture order before live delivery can overtake it.
    public func attach(_ destination: @escaping Destination) {
        lock.lock()
        precondition(self.destination == nil, "A destination can only be attached once")
        let buffered = pendingChunks
        pendingChunks.removeAll(keepingCapacity: false)
        for chunk in buffered {
            destination(chunk)
        }
        // Publish the live destination only after the buffered prefix has been
        // handed off. append() waits on this lock, so it cannot overtake it.
        self.destination = destination
        lock.unlock()
    }

    public var pendingCount: Int {
        withLock { pendingChunks.count }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
