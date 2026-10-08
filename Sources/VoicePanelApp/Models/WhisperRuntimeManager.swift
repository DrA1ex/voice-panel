import Combine
import Foundation
import VoicePanelCore
import whisper

enum WhisperRuntimeLoadState: Equatable {
    case inactive
    case notInstalled(WhisperModelID)
    case downloading(WhisperModelID, Double)
    case verifying(WhisperModelID)
    case loading(WhisperModelID, Double)
    case ready(WhisperModelID)
    case failed(WhisperModelID, String)

    var model: WhisperModelID? {
        switch self {
        case .inactive: return nil
        case .notInstalled(let model),
            .downloading(let model, _),
            .verifying(let model),
            .loading(let model, _),
            .ready(let model),
            .failed(let model, _):
            return model
        }
    }

    var isPreparing: Bool {
        switch self {
        case .downloading, .verifying, .loading: return true
        default: return false
        }
    }

    var progress: Double? {
        switch self {
        case .downloading(_, let progress), .loading(_, let progress): return progress
        case .verifying: return 0.90
        case .ready: return 1
        default: return nil
        }
    }

    var menuTitle: String {
        switch self {
        case .inactive:
            return "Whisper model inactive"
        case .notInstalled(let model):
            return "\(model.title) · Not installed"
        case .downloading(let model, let progress):
            return "Downloading \(model.title)… \(Int(progress * 100))%"
        case .verifying(let model):
            return "Verifying \(model.title)…"
        case .loading(let model, let progress):
            return "Loading \(model.title)… \(Int(progress * 100))%"
        case .ready(let model):
            return "\(model.title) · Ready"
        case .failed(let model, let message):
            return "\(model.title) · \(message)"
        }
    }
}

@MainActor
final class WhisperRuntimeManager: ObservableObject {
    @Published private(set) var state: WhisperRuntimeLoadState = .inactive

    private let models: WhisperModelManager
    private var runtime: WhisperRuntime?
    private var preparationTask: Task<WhisperRuntime, Error>?
    private var preparationModel: WhisperModelID?
    private var preparationConfiguration: WhisperRuntimeConfiguration?
    private var preparationID = UUID()
    private var cancellables = Set<AnyCancellable>()

    init(models: WhisperModelManager) {
        self.models = models
        models.$states
            .sink { [weak self] states in
                Task { @MainActor in self?.reflectInstallState(states) }
            }
            .store(in: &cancellables)
        models.$coreMLStates
            .sink { [weak self] states in
                Task { @MainActor in self?.reflectCoreMLInstallState(states) }
            }
            .store(in: &cancellables)
    }

    func isReady(
        _ model: WhisperModelID,
        runtimeConfiguration: WhisperRuntimeConfiguration
    ) -> Bool {
        guard let runtime, runtime.model == model, state == .ready(model) else { return false }
        return runtime.runtimeConfiguration.requestedComputeMode
            == runtimeConfiguration.requestedComputeMode
            && runtime.runtimeConfiguration.flashAttention == runtimeConfiguration.flashAttention
    }

    func markSelected(
        _ model: WhisperModelID,
        runtimeConfiguration: WhisperRuntimeConfiguration
    ) {
        if isReady(model, runtimeConfiguration: runtimeConfiguration) { return }
        if runtime?.model != model
            || runtime?.runtimeConfiguration.requestedComputeMode
                != runtimeConfiguration.requestedComputeMode
            || runtime?.runtimeConfiguration.flashAttention != runtimeConfiguration.flashAttention
            || preparationModel != model
            || preparationConfiguration != runtimeConfiguration
        {
            preparationID = UUID()
            preparationTask?.cancel()
            preparationTask = nil
            preparationModel = nil
            preparationConfiguration = nil
            runtime = nil
        }
        state = models.isInstalled(model) ? .inactive : .notInstalled(model)
    }

    func markRecoveryBlocked(_ model: WhisperModelID) {
        unload()
        state = .failed(model, "Previous load crashed · open Settings to retry")
    }

    func preloadIfInstalled(
        _ model: WhisperModelID,
        runtimeConfiguration: WhisperRuntimeConfiguration
    ) {
        guard models.isInstalled(model),
            !isReady(model, runtimeConfiguration: runtimeConfiguration)
        else {
            if isReady(model, runtimeConfiguration: runtimeConfiguration) {
                state = .ready(model)
            }
            return
        }
        Task { [weak self] in
            _ = try? await self?.prepare(
                model,
                runtimeConfiguration: runtimeConfiguration,
                installIfNeeded: false
            )
        }
    }

    func prepare(
        _ model: WhisperModelID,
        runtimeConfiguration: WhisperRuntimeConfiguration,
        installIfNeeded: Bool
    ) async throws -> WhisperRuntime {
        if let runtime,
            runtime.model == model,
            runtime.runtimeConfiguration.requestedComputeMode
                == runtimeConfiguration.requestedComputeMode,
            runtime.runtimeConfiguration.flashAttention == runtimeConfiguration.flashAttention
        {
            state = .ready(model)
            return runtime
        }

        if preparationModel == model,
            preparationConfiguration == runtimeConfiguration,
            let preparationTask
        {
            return try await preparationTask.value
        }

        preparationTask?.cancel()
        preparationID = UUID()
        let currentPreparationID = preparationID
        preparationModel = model
        preparationConfiguration = runtimeConfiguration
        runtime = nil

        if !models.isInstalled(model), !installIfNeeded {
            state = .notInstalled(model)
            preparationModel = nil
            preparationConfiguration = nil
            throw WhisperModelError.missingModel
        }

        let task = Task<WhisperRuntime, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let preparedFiles = try await self.models.prepareRuntimeFiles(
                for: model,
                requestedConfiguration: runtimeConfiguration,
                installIfNeeded: installIfNeeded
            )
            try Task.checkCancellation()

            self.state = .loading(model, 0)
            let loadedRuntime = try await WhisperRuntime.load(
                model: model,
                preparedFiles: preparedFiles
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                        self.preparationID == currentPreparationID,
                        self.preparationModel == model
                    else { return }
                    self.state = .loading(model, progress)
                }
            }
            try Task.checkCancellation()
            return loadedRuntime
        }
        preparationTask = task

        do {
            let loadedRuntime = try await task.value
            guard preparationID == currentPreparationID else {
                throw CancellationError()
            }
            runtime = loadedRuntime
            state = .ready(model)
            preparationTask = nil
            preparationModel = nil
            preparationConfiguration = nil
            return loadedRuntime
        } catch {
            if preparationID == currentPreparationID {
                if error is CancellationError {
                    state = models.isInstalled(model) ? .inactive : .notInstalled(model)
                } else {
                    state = .failed(model, error.localizedDescription)
                }
                preparationTask = nil
                preparationModel = nil
                preparationConfiguration = nil
            }
            throw error
        }
    }

    func unload() {
        preparationID = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        preparationModel = nil
        preparationConfiguration = nil
        runtime = nil
        state = .inactive
    }

    func remove(_ model: WhisperModelID) throws {
        if runtime?.model == model || preparationModel == model {
            unload()
        }
        try models.remove(model)
        state = .notInstalled(model)
    }

    private func reflectInstallState(_ states: [WhisperModelID: WhisperModelInstallState]) {
        guard let model = preparationModel else { return }
        switch states[model] ?? .notInstalled {
        case .downloading(let progress):
            state = .downloading(model, progress)
        case .verifying:
            state = .verifying(model)
        case .failed(let message):
            state = .failed(model, message)
        case .notInstalled, .installed:
            break
        }
    }

    private func reflectCoreMLInstallState(
        _ states: [WhisperCoreMLEncoderID: WhisperModelInstallState]
    ) {
        guard let model = preparationModel,
            preparationConfiguration?.requestedComputeMode.requestsCoreML == true,
            let encoder = model.coreMLEncoder
        else { return }
        switch states[encoder] ?? .notInstalled {
        case .downloading(let progress):
            state = .downloading(model, progress)
        case .verifying:
            state = .verifying(model)
        case .failed(let message):
            state = .failed(model, message)
        case .notInstalled, .installed:
            break
        }
    }
}
