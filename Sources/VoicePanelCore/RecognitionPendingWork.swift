import Foundation

public struct RecognitionPendingWork: Equatable, Sendable {
    public private(set) var currentAudioDuration: TimeInterval = 0
    public private(set) var queuedChunks: [UUID: TimeInterval] = [:]
    public private(set) var failedChunkCount = 0

    private var completedBeforeQueue: Set<UUID> = []
    private var failedBeforeQueue: Set<UUID> = []
    private var failedChunkIDs: Set<UUID> = []

    public init() {}

    public var queuedDuration: TimeInterval {
        queuedChunks.values.reduce(0, +)
    }

    public var totalDuration: TimeInterval {
        max(0, currentAudioDuration) + queuedDuration
    }

    public var chunkCount: Int {
        queuedChunks.count
    }

    public var hasWork: Bool {
        totalDuration > 0 || !queuedChunks.isEmpty
    }

    public mutating func updateCurrentAudioDuration(_ duration: TimeInterval) {
        currentAudioDuration = max(0, duration)
    }

    public mutating func queueChunk(id: UUID, duration: TimeInterval) {
        if completedBeforeQueue.remove(id) != nil {
            return
        }
        if failedBeforeQueue.remove(id) != nil {
            return
        }
        queuedChunks[id] = max(0, duration)
    }

    public mutating func completeChunk(id: UUID) {
        if queuedChunks.removeValue(forKey: id) == nil {
            completedBeforeQueue.insert(id)
        }
    }

    public mutating func failChunk(id: UUID) {
        if queuedChunks.removeValue(forKey: id) != nil {
            if failedChunkIDs.insert(id).inserted { failedChunkCount += 1 }
        } else if failedBeforeQueue.insert(id).inserted {
            if failedChunkIDs.insert(id).inserted { failedChunkCount += 1 }
        }
    }

    @discardableResult
    public mutating func recoverFailedChunk(id: UUID) -> Bool {
        guard failedChunkIDs.remove(id) != nil else { return false }
        failedBeforeQueue.remove(id)
        failedChunkCount = max(0, failedChunkCount - 1)
        return true
    }

    public mutating func finishCapture() {
        currentAudioDuration = 0
    }

    /// Engine completion is authoritative: all accepted chunks have left the
    /// runtime queue. Any IDs still present here are stale UI bookkeeping from
    /// callback ordering and must not keep finalization open forever.
    public mutating func finishEngine() {
        currentAudioDuration = 0
        queuedChunks.removeAll(keepingCapacity: true)
        completedBeforeQueue.removeAll(keepingCapacity: true)
        failedBeforeQueue.removeAll(keepingCapacity: true)
    }

    public mutating func reset() {
        currentAudioDuration = 0
        queuedChunks.removeAll(keepingCapacity: true)
        failedChunkCount = 0
        completedBeforeQueue.removeAll(keepingCapacity: true)
        failedBeforeQueue.removeAll(keepingCapacity: true)
        failedChunkIDs.removeAll(keepingCapacity: true)
    }

    public func placeholderCount(
        cadence: TimeInterval = 1,
        maximum: Int = 18
    ) -> Int {
        guard totalDuration > 0, cadence > 0, maximum > 0 else { return 0 }
        return min(maximum, max(0, Int(floor(totalDuration / cadence))))
    }
}
