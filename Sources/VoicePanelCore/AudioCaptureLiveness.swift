import Foundation

/// Tracks delivery of valid PCM buffers, including silence. Use a monotonic
/// clock so wall-clock changes cannot hide a stalled input or cause a retry.
public struct AudioCaptureLiveness: Sendable {
    public enum Status: Equatable, Sendable {
        case inactive
        case waitingForFirstBuffer
        case receiving
        case stalled
    }

    private var startedAt: TimeInterval?
    private var lastBufferAt: TimeInterval?

    public init() {}

    public mutating func start(at time: TimeInterval) {
        startedAt = time
        lastBufferAt = nil
    }

    public mutating func receivedBuffer(at time: TimeInterval) {
        guard startedAt != nil else { return }
        lastBufferAt = time
    }

    public mutating func suspend() {
        startedAt = nil
        lastBufferAt = nil
    }

    public func status(at time: TimeInterval) -> Status {
        guard let startedAt else { return .inactive }
        if let lastBufferAt {
            return time - lastBufferAt >= 2 ? .stalled : .receiving
        }
        return time - startedAt >= 1 ? .stalled : .waitingForFirstBuffer
    }
}
