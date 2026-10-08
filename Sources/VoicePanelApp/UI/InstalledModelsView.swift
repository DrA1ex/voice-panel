import SwiftUI

struct InstalledModelsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    @ObservedObject var whisperModels: WhisperModelManager
    @ObservedObject var whisperRuntime: WhisperRuntimeManager
    @ObservedObject var whisperDraftRuntime: WhisperRuntimeManager
    @ObservedObject var gigaAMModels: GigaAMModelManager
    @ObservedObject var gigaAMRuntime: GigaAMRuntimeManager
    @ObservedObject var gigaAMDraftRuntime: GigaAMRuntimeManager
    @ObservedObject var localONNXModels: LocalONNXModelManager
    @ObservedObject var localONNXRuntime: LocalONNXRuntimeManager

    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: InstalledModelRemoval?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Installed Models")
                        .font(.title2.weight(.semibold))
                    Text("Remove downloaded model files without changing your other settings.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("installed-models.done")
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if hasInstalledModels {
                List {
                    if !whisperModels.installedModels.isEmpty {
                        Section("Whisper") {
                            ForEach(whisperModels.installedModels) { model in
                                modelRow(
                                    title: model.title,
                                    detail: model.detail,
                                    size: whisperModels.installedSize(for: model),
                                    isSelected: isWhisperModelSelected(model)
                                ) {
                                    pendingRemoval = .whisper(model)
                                }
                            }
                        }
                    }

                    if !whisperModels.installedCoreMLEncoders.isEmpty {
                        Section("Whisper Core ML Encoders") {
                            ForEach(whisperModels.installedCoreMLEncoders) { encoder in
                                modelRow(
                                    title: encoder.title,
                                    detail: "Shared by FP16, Q5, and Q8 variants of the same model family",
                                    size: whisperModels.installedCoreMLEncoderSize(for: encoder),
                                    isSelected: isWhisperCoreMLEncoderSelected(encoder)
                                ) {
                                    pendingRemoval = .whisperCoreML(encoder)
                                }
                            }
                        }
                    }

                    if !gigaAMModels.installedModels.isEmpty {
                        Section("GigaAM") {
                            ForEach(gigaAMModels.installedModels) { model in
                                modelRow(
                                    title: model.title,
                                    detail: model.capabilityLabel,
                                    size: gigaAMModels.installedSize(for: model),
                                    isSelected: isGigaAMModelSelected(model)
                                ) {
                                    pendingRemoval = .gigaAM(model)
                                }
                            }
                        }
                    }

                    if !localONNXModels.installedModels.isEmpty {
                        Section("Qwen and Parakeet") {
                            ForEach(localONNXModels.installedModels) { model in
                                modelRow(
                                    title: model.title,
                                    detail: model.capabilityLabel,
                                    size: localONNXModels.installedSize(for: model),
                                    isSelected: settings.selectedLocalONNXModel == model
                                ) {
                                    pendingRemoval = .localONNX(model)
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Installed Models",
                    systemImage: "internaldrive",
                    description: Text("Downloaded Whisper, GigaAM, Qwen, and Parakeet models will appear here.")
                )
            }

            Divider()

            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: totalInstalledSize, countStyle: .file) + " installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove All…", role: .destructive) {
                    pendingRemoval = .all
                }
                .disabled(!hasInstalledModels || state.phase.isRecordingRelated)
            }
            .padding(14)
        }
        .frame(minWidth: 650, minHeight: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("installed-models.root")
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button(removalButtonTitle, role: .destructive) { performPendingRemoval() }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The downloaded files will be deleted. You can download the models again later.")
        }
    }

    private func modelRow(
        title: String,
        detail: String,
        size: Int64,
        isSelected: Bool,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(.body.weight(.medium))
                    if isSelected {
                        Text("Selected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Remove", role: .destructive, action: onRemove)
                .disabled(state.phase.isRecordingRelated)
        }
        .padding(.vertical, 5)
    }

    private var hasInstalledModels: Bool {
        !whisperModels.installedModels.isEmpty
            || !whisperModels.installedCoreMLEncoders.isEmpty
            || !gigaAMModels.installedModels.isEmpty
            || !localONNXModels.installedModels.isEmpty
    }

    private func isWhisperModelSelected(_ model: WhisperModelID) -> Bool {
        settings.whisperModelID == model
            || (settings.effectiveWhisperDraftSource == .localWhisper
                && settings.whisperDraftModelID == model)
    }

    private func isWhisperCoreMLEncoderSelected(_ encoder: WhisperCoreMLEncoderID) -> Bool {
        guard settings.whisperComputeMode.permitsCoreML else { return false }
        return settings.whisperModelID.coreMLEncoder == encoder
            || (settings.effectiveWhisperDraftSource == .localWhisper
                && settings.whisperDraftModelID.coreMLEncoder == encoder)
    }

    private func isGigaAMModelSelected(_ model: GigaAMModelID) -> Bool {
        settings.gigaAMModelID == model
            || (settings.effectiveGigaAMDraftSource == .localGigaAM
                && settings.gigaAMDraftModelID == model)
    }

    private var totalInstalledSize: Int64 {
        whisperModels.installedModels.reduce(0) { $0 + whisperModels.installedSize(for: $1) }
            + whisperModels.installedCoreMLEncoders.reduce(0) {
                $0 + whisperModels.installedCoreMLEncoderSize(for: $1)
            }
            + gigaAMModels.installedModels.reduce(0) { $0 + gigaAMModels.installedSize(for: $1) }
            + localONNXModels.installedModels.reduce(0) { $0 + localONNXModels.installedSize(for: $1) }
    }

    private var removalTitle: String {
        switch pendingRemoval {
        case .all: return "Remove all installed models?"
        case .whisper(let model): return "Remove \(model.title)?"
        case .whisperCoreML(let encoder): return "Remove \(encoder.title)?"
        case .gigaAM(let model): return "Remove \(model.title)?"
        case .localONNX(let model): return "Remove \(model.title)?"
        case nil: return "Remove model?"
        }
    }

    private var removalButtonTitle: String {
        pendingRemoval == .all ? "Remove All" : "Remove Model"
    }

    private func performPendingRemoval() {
        errorMessage = nil
        do {
            switch pendingRemoval {
            case .whisper(let model):
                unloadWhisper(model)
                try whisperModels.remove(model)
            case .whisperCoreML(let encoder):
                unloadWhisperCoreML(encoder)
                try whisperModels.removeCoreMLEncoder(encoder)
            case .gigaAM(let model):
                unloadGigaAM(model)
                try gigaAMModels.remove(model)
            case .localONNX(let model):
                if localONNXRuntime.state.model == model { localONNXRuntime.unload() }
                try localONNXModels.remove(model)
            case .all:
                for model in whisperModels.installedModels {
                    unloadWhisper(model)
                    try whisperModels.remove(model)
                }
                for encoder in whisperModels.installedCoreMLEncoders {
                    unloadWhisperCoreML(encoder)
                    try whisperModels.removeCoreMLEncoder(encoder)
                }
                for model in gigaAMModels.installedModels {
                    unloadGigaAM(model)
                    try gigaAMModels.remove(model)
                }
                for model in localONNXModels.installedModels {
                    if localONNXRuntime.state.model == model { localONNXRuntime.unload() }
                    try localONNXModels.remove(model)
                }
            case nil:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        pendingRemoval = nil
    }

    private func unloadWhisper(_ model: WhisperModelID) {
        if whisperRuntime.state.model == model { whisperRuntime.unload() }
        if whisperDraftRuntime.state.model == model { whisperDraftRuntime.unload() }
    }

    private func unloadWhisperCoreML(_ encoder: WhisperCoreMLEncoderID) {
        if whisperRuntime.state.model?.coreMLEncoder == encoder { whisperRuntime.unload() }
        if whisperDraftRuntime.state.model?.coreMLEncoder == encoder { whisperDraftRuntime.unload() }
        if settings.whisperComputeMode.requestsCoreML,
            settings.whisperModelID.coreMLEncoder == encoder
        {
            settings.whisperComputeMode = .metal
        }
    }

    private func unloadGigaAM(_ model: GigaAMModelID) {
        if gigaAMRuntime.state.model == model { gigaAMRuntime.unload() }
        if gigaAMDraftRuntime.state.model == model { gigaAMDraftRuntime.unload() }
    }
}

private enum InstalledModelRemoval: Equatable {
    case whisper(WhisperModelID)
    case whisperCoreML(WhisperCoreMLEncoderID)
    case gigaAM(GigaAMModelID)
    case localONNX(LocalONNXModelID)
    case all
}

#if DEBUG
    @MainActor
    private struct InstalledModelsPreviewHost: View {
        private let environment: VoicePanelPreviewEnvironment

        init(populated: Bool) {
            let environment = VoicePanelPreviewEnvironment()
            if populated {
                environment.whisperModels.configurePreview(
                    installedModels: Array(WhisperModelID.allCases.prefix(2)),
                    installedCoreMLEncoders: Array(WhisperCoreMLEncoderID.allCases.prefix(1))
                )
                environment.gigaAMModels.configurePreview(
                    installedModels: Array(GigaAMModelID.allCases.prefix(1))
                )
                environment.localONNXModels.configurePreview(
                    installedModels: Array(LocalONNXModelID.allCases.prefix(2))
                )
            }
            self.environment = environment
        }

        var body: some View {
            InstalledModelsView(
                settings: environment.settings,
                state: environment.state,
                whisperModels: environment.whisperModels,
                whisperRuntime: environment.whisperRuntime,
                whisperDraftRuntime: environment.whisperDraftRuntime,
                gigaAMModels: environment.gigaAMModels,
                gigaAMRuntime: environment.gigaAMRuntime,
                gigaAMDraftRuntime: environment.gigaAMDraftRuntime,
                localONNXModels: environment.localONNXModels,
                localONNXRuntime: environment.localONNXRuntime
            )
            .frame(width: 760, height: 560)
        }
    }

    #Preview("Installed Models · Populated") {
        InstalledModelsPreviewHost(populated: true)
    }

    #Preview("Installed Models · Empty") {
        InstalledModelsPreviewHost(populated: false)
    }
#endif
