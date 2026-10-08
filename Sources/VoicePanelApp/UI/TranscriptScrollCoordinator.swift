import Combine
import Foundation

/// Coalesces scroll requests without postponing them while speech keeps arriving.
@MainActor
final class TranscriptScrollCoordinator: ObservableObject {
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var pendingAction: (@MainActor () -> Void)?

    init(interval: Duration = .milliseconds(180)) {
        self.interval = interval
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        pendingAction = action
        guard task == nil else { return }
        let interval = interval
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            let action = self.pendingAction
            self.pendingAction = nil
            self.task = nil
            action?()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingAction = nil
    }

    deinit {
        task?.cancel()
    }
}
