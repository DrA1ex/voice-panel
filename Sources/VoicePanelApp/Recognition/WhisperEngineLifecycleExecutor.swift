import Foundation

final class WhisperEngineLifecycleExecutor<State>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueIdentity = DispatchSpecificKey<UInt8>()
    private let state: State

    init(label: String, initialState: State) {
        queue = DispatchQueue(label: label)
        state = initialState
        queue.setSpecific(key: queueIdentity, value: 1)
    }

    func sync<T>(_ operation: (State) throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueIdentity) == 1 {
            return try operation(state)
        }
        return try queue.sync {
            try operation(state)
        }
    }
}
