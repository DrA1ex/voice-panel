import Combine
import Foundation

enum RussianTextCorrectionRuntimeState: Equatable {
    case inactive
    case notInstalled
    case downloading(Double)
    case verifying(Double)
    case loading
    case ready
    case failed(String)
}

@MainActor
final class RussianTextCorrectionRuntimeManager: ObservableObject {
    @Published private(set) var state: RussianTextCorrectionRuntimeState = .inactive

    private let models: RussianCorrectionModelManager
    private let model: RussianCorrectionModelID = .sageFREDT5Int8
    private var runtime: RussianTextCorrectionRuntime?
    private var task: Task<RussianTextCorrectionRuntime, Error>?
    private var cancellables = Set<AnyCancellable>()

    init(models: RussianCorrectionModelManager) {
        self.models = models
        models.$states
            .sink { [weak self] states in
                Task { @MainActor in self?.reflect(states[.sageFREDT5Int8] ?? .notInstalled) }
            }
            .store(in: &cancellables)
    }

    func prepare(installIfNeeded: Bool, numberOfThreads: Int) async throws -> RussianTextCorrectionRuntime {
        if let runtime {
            state = .ready
            return runtime
        }
        if let task { return try await task.value }
        if !models.isInstalled(model), !installIfNeeded {
            state = .notInstalled
            throw RussianCorrectionModelError.missingModel
        }

        let loadTask = Task<RussianTextCorrectionRuntime, Error> { [models] in
            let package = try await models.ensureInstalled(.sageFREDT5Int8)
            self.state = .loading
            return try await RussianTextCorrectionRuntime.load(
                package: package,
                numberOfThreads: numberOfThreads
            )
        }
        task = loadTask
        do {
            let loaded = try await loadTask.value
            runtime = loaded
            task = nil
            state = .ready
            return loaded
        } catch {
            task = nil
            state = error is CancellationError ? .inactive : .failed(error.localizedDescription)
            throw error
        }
    }

    func unload() {
        task?.cancel()
        task = nil
        runtime = nil
        state = .inactive
    }

    func removeModel() throws {
        unload()
        try models.remove(model)
        state = .notInstalled
    }

    private func reflect(_ installState: RussianCorrectionModelInstallState) {
        guard runtime == nil else { return }
        switch installState {
        case .notInstalled: state = .notInstalled
        case .downloading(let progress): state = .downloading(progress)
        case .verifying(let progress): state = .verifying(progress)
        case .installed: if task == nil { state = .inactive }
        case .failed(let message): state = .failed(message)
        }
    }
}
