import Combine
import Foundation

enum LocalONNXRuntimeLoadState: Equatable {
    case inactive
    case notInstalled(LocalONNXModelID)
    case downloading(LocalONNXModelID, Double)
    case verifying(LocalONNXModelID, Double)
    case loading(LocalONNXModelID, Double)
    case ready(LocalONNXModelID)
    case failed(LocalONNXModelID, String)

    var model: LocalONNXModelID? {
        switch self {
        case .inactive: return nil
        case .notInstalled(let model), .downloading(let model, _), .verifying(let model, _),
            .loading(let model, _), .ready(let model), .failed(let model, _):
            return model
        }
    }

    var isPreparing: Bool {
        switch self {
        case .downloading, .verifying, .loading: return true
        default: return false
        }
    }

    var menuTitle: String {
        switch self {
        case .inactive: return "Local ASR · Inactive"
        case .notInstalled(let model): return "\(model.title) · Not installed"
        case .downloading(let model, let progress): return "Downloading \(model.title) · \(Int(progress * 100))%"
        case .verifying(let model, let progress): return "Verifying \(model.title) · \(Int(progress * 100))%"
        case .loading(let model, let progress): return "Loading \(model.title) · \(Int(progress * 100))%"
        case .ready(let model): return "\(model.title) · Ready"
        case .failed(let model, _): return "\(model.title) · Failed"
        }
    }
}

@MainActor
final class LocalONNXRuntimeManager: ObservableObject {
    @Published private(set) var state: LocalONNXRuntimeLoadState = .inactive

    private let models: LocalONNXModelManager
    private var runtime: LocalONNXRuntime?
    private var task: Task<LocalONNXRuntime, Error>?
    private var taskModel: LocalONNXModelID?
    private var preparationID = UUID()
    private var cancellables = Set<AnyCancellable>()

    init(models: LocalONNXModelManager) {
        self.models = models
        models.$states
            .sink { [weak self] states in
                Task { @MainActor in self?.reflectInstallState(states) }
            }
            .store(in: &cancellables)
    }

    func isReady(_ model: LocalONNXModelID) -> Bool {
        runtime?.model == model && state == .ready(model)
    }

    func markSelected(_ model: LocalONNXModelID) {
        if isReady(model) { return }
        if runtime?.model != model || taskModel != model { unload() }
        state = models.isInstalled(model) ? .inactive : .notInstalled(model)
    }

    func markRecoveryBlocked(_ model: LocalONNXModelID) {
        unload()
        state = .failed(model, "Previous load crashed · open Settings to retry")
    }

    func preloadIfInstalled(
        _ model: LocalONNXModelID,
        numberOfThreads: Int,
        provider: String
    ) {
        guard models.isInstalled(model), !isReady(model) else { return }
        Task { [weak self] in
            _ = try? await self?.prepare(
                model,
                installIfNeeded: false,
                numberOfThreads: numberOfThreads,
                provider: provider
            )
        }
    }

    func prepare(
        _ model: LocalONNXModelID,
        installIfNeeded: Bool,
        numberOfThreads: Int,
        provider: String
    ) async throws -> LocalONNXRuntime {
        if let runtime, runtime.model == model {
            state = .ready(model)
            return runtime
        }
        if taskModel == model, let task { return try await task.value }

        unload()
        let currentID = UUID()
        preparationID = currentID
        taskModel = model

        if !models.isInstalled(model), !installIfNeeded {
            state = .notInstalled(model)
            taskModel = nil
            throw LocalONNXModelError.missingModel
        }

        let loadTask = Task<LocalONNXRuntime, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let package = try await self.models.ensureInstalled(model)
            try Task.checkCancellation()
            self.state = .loading(model, 0)
            return try await LocalONNXRuntime.load(
                package: package,
                numberOfThreads: numberOfThreads,
                provider: provider
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.preparationID == currentID else { return }
                    self.state = .loading(model, progress)
                }
            }
        }
        task = loadTask

        do {
            let loaded = try await loadTask.value
            guard preparationID == currentID else { throw CancellationError() }
            runtime = loaded
            state = .ready(model)
            task = nil
            taskModel = nil
            return loaded
        } catch {
            if preparationID == currentID {
                state =
                    error is CancellationError
                    ? (models.isInstalled(model) ? .inactive : .notInstalled(model))
                    : .failed(model, error.localizedDescription)
                task = nil
                taskModel = nil
            }
            throw error
        }
    }

    func unload() {
        preparationID = UUID()
        task?.cancel()
        task = nil
        taskModel = nil
        runtime = nil
        state = .inactive
    }

    func remove(_ model: LocalONNXModelID) throws {
        if runtime?.model == model || taskModel == model { unload() }
        try models.remove(model)
        state = .notInstalled(model)
    }

    private func reflectInstallState(_ states: [LocalONNXModelID: LocalONNXModelInstallState]) {
        guard let model = taskModel else { return }
        switch states[model] ?? .notInstalled {
        case .downloading(let progress): state = .downloading(model, progress)
        case .verifying(let progress): state = .verifying(model, progress)
        case .failed(let message): state = .failed(model, message)
        case .notInstalled, .installed: break
        }
    }
}
