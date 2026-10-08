import AppKit
import Combine
import CoreAudio
import Darwin
import Foundation
import Speech
import SwiftUI
import UniformTypeIdentifiers
import VoicePanelCore

@MainActor
private final class SettingsAppStateActivity: ObservableObject {
    @Published private(set) var phase: AppState.Phase
    @Published private(set) var inputDeviceWarning: String?

    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        phase = state.phase
        inputDeviceWarning = state.inputDeviceWarning

        state.$phase
            .sink { [weak self] in self?.phase = $0 }
            .store(in: &cancellables)
        state.$inputDeviceWarning
            .sink { [weak self] in self?.inputDeviceWarning = $0 }
            .store(in: &cancellables)
    }
}

private struct SettingsLiveInputMonitoringView: View {
    @ObservedObject var state: AppState

    let onStop: () -> Void

    @ViewBuilder
    var body: some View {
        InputLevelMeterView(
            currentDB: state.currentLevelDB,
            noiseFloorDB: state.noiseFloorDB,
            thresholdDB: state.thresholdDB,
            state: state.voiceActivityState,
            isTesting: state.phase == .monitoring
        )

        HStack {
            Label(
                state.voiceActivityState == .speech ? "Speech detected" : "Background / pause",
                systemImage: state.voiceActivityState == .speech
                    ? "waveform.circle.fill" : "waveform.circle"
            )
            .foregroundStyle(state.voiceActivityState == .speech ? Color.green : Color.secondary)
            Spacer()
            Button("Stop Test", action: onStop)
                .accessibilityIdentifier("general.input-test")
        }
    }
}

#if DEBUG
    #Preview("Settings · Input Monitoring") {
        SettingsLiveInputMonitoringView(
            state: AppState(),
            onStop: {}
        )
        .frame(width: 620)
        .padding()
    }
#endif

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let state: AppState
    @ObservedObject var whisperModels: WhisperModelManager
    @ObservedObject var whisperRuntime: WhisperRuntimeManager
    @ObservedObject var whisperDraftRuntime: WhisperRuntimeManager
    @ObservedObject var gigaAMModels: GigaAMModelManager
    @ObservedObject var gigaAMRuntime: GigaAMRuntimeManager
    @ObservedObject var gigaAMDraftRuntime: GigaAMRuntimeManager
    @ObservedObject var localONNXModels: LocalONNXModelManager
    @ObservedObject var localONNXRuntime: LocalONNXRuntimeManager
    @ObservedObject var sileroVADModels: SileroVADModelManager
    @ObservedObject var russianCorrectionModels: RussianCorrectionModelManager
    @ObservedObject var russianCorrectionRuntime: RussianTextCorrectionRuntimeManager
    @ObservedObject var history: HistoryModel
    @ObservedObject var presentationContext: SettingsPresentationContext

    let coordinator: TranscriptionCoordinator
    let onHotKeyChanged: () -> Void
    let onOpenAudioFileChooser: () -> Void

    init(
        settings: AppSettings,
        state: AppState,
        whisperModels: WhisperModelManager,
        whisperRuntime: WhisperRuntimeManager,
        whisperDraftRuntime: WhisperRuntimeManager,
        gigaAMModels: GigaAMModelManager,
        gigaAMRuntime: GigaAMRuntimeManager,
        gigaAMDraftRuntime: GigaAMRuntimeManager,
        localONNXModels: LocalONNXModelManager,
        localONNXRuntime: LocalONNXRuntimeManager,
        sileroVADModels: SileroVADModelManager,
        russianCorrectionModels: RussianCorrectionModelManager,
        russianCorrectionRuntime: RussianTextCorrectionRuntimeManager,
        history: HistoryModel,
        coordinator: TranscriptionCoordinator,
        presentationContext: SettingsPresentationContext,
        initialPage: SettingsPage = .uiTestingInitialPage,
        modelBenchmark: ModelBenchmarkRunner? = nil,
        onHotKeyChanged: @escaping () -> Void,
        onOpenAudioFileChooser: @escaping () -> Void = {}
    ) {
        _settings = ObservedObject(wrappedValue: settings)
        self.state = state
        _whisperModels = ObservedObject(wrappedValue: whisperModels)
        _whisperRuntime = ObservedObject(wrappedValue: whisperRuntime)
        _whisperDraftRuntime = ObservedObject(wrappedValue: whisperDraftRuntime)
        _gigaAMModels = ObservedObject(wrappedValue: gigaAMModels)
        _gigaAMRuntime = ObservedObject(wrappedValue: gigaAMRuntime)
        _gigaAMDraftRuntime = ObservedObject(wrappedValue: gigaAMDraftRuntime)
        _localONNXModels = ObservedObject(wrappedValue: localONNXModels)
        _localONNXRuntime = ObservedObject(wrappedValue: localONNXRuntime)
        _sileroVADModels = ObservedObject(wrappedValue: sileroVADModels)
        _russianCorrectionModels = ObservedObject(wrappedValue: russianCorrectionModels)
        _russianCorrectionRuntime = ObservedObject(wrappedValue: russianCorrectionRuntime)
        _history = ObservedObject(wrappedValue: history)
        _presentationContext = ObservedObject(wrappedValue: presentationContext)
        _performanceSettings = StateObject(
            wrappedValue: AppSettings.makeIsolatedPerformanceCopy(of: settings)
        )
        _stateActivity = StateObject(
            wrappedValue: SettingsAppStateActivity(state: state)
        )
        _modelBenchmark = StateObject(
            wrappedValue: modelBenchmark
                ?? ModelBenchmarkRunner(
                    monitorsAudioInputDevices: !AppRuntimeEnvironment.suppressesLiveServices
                )
        )
        _selectedPage = State(initialValue: initialPage)
        self.coordinator = coordinator
        self.onHotKeyChanged = onHotKeyChanged
        self.onOpenAudioFileChooser = onOpenAudioFileChooser
    }

    @State private var selectedPage: SettingsPage = .general
    @State private var devices: [AudioInputDevice] = []
    @State private var appleSpeechLanguages: [RecognitionLanguageOption] = []
    @State private var whisperLanguages: [RecognitionLanguageOption] = []
    @State private var modelActionError: String?
    @State private var speechAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var showsInstalledModels = false
    @State private var asksToDisableHistory = false
    @State private var showsContextEditor = false
    @State private var showsVocabularyEditor = false
    @State private var showsSaveRecognitionPreset = false
    @State private var validationReferenceTranscript = ""
    @State private var validationNotes = ""
    @State private var validationRepetitions = 3
    @State private var validationExportMessage: String?
    @State private var validationExportFailed = false
    @StateObject private var modelBenchmark: ModelBenchmarkRunner
    @StateObject private var performanceSettings: AppSettings
    @StateObject private var stateActivity: SettingsAppStateActivity
    @State private var performanceConfigurationMessage: String?
    @State private var performanceTestMode: PerformanceTestMode = .modelBenchmark
    @State private var selectedPerformanceRunID: UUID?
    @State private var performanceReportExpanded = false
    @State private var performanceModelSpecificExpanded = false
    @State private var performanceAdvancedPipelineExpanded = false
    @State private var performanceWhisperComparisonAdvancedExpanded = false
    @State private var whisperComparisonEdgePadding: TimeInterval = 0
    @State private var whisperComparisonMaximumChunkOffset: TimeInterval = 0
    @State private var asksToReplacePerformanceSample = false
    @State private var isRestoringPerformanceRunConfiguration = false
    @State private var restoredPerformanceRunID: UUID?
    @State private var comparedPerformanceRunIDs: Set<UUID> = []
    @State private var showsPerformanceComparison = false

    private var uiTestingEnabled: Bool {
        AppRuntimeEnvironment.isUITesting
    }

    private var suppressesLiveServices: Bool {
        AppRuntimeEnvironment.suppressesLiveServices
    }

    var body: some View {
        TabView(selection: $selectedPage) {
            ForEach(SettingsPage.allCases) { page in
                settingsDetail(for: page)
                    .tabItem {
                        Label(page.navigationTitle, systemImage: page.systemImage)
                            .accessibilityIdentifier("settings.tab.\(page.rawValue)")
                    }
                    .tag(page)
            }
        }
        .accessibilityIdentifier("settings.root")
        .frame(minWidth: 1120, idealWidth: 1180, minHeight: 700, idealHeight: 780)
        .overlay(alignment: .bottomTrailing) {
            if uiTestingEnabled {
                Button("Open Audio File Chooser") {
                    onOpenAudioFileChooser()
                }
                .controlSize(.mini)
                .accessibilityIdentifier("ui-test.open-audio-panel")
                .padding(10)
            }
        }
        .onAppear {
            if suppressesLiveServices {
                devices = []
            } else {
                devices = AudioInputDeviceManager.inputDevices()
            }
            appleSpeechLanguages = RecognitionLanguageCatalog.appleSpeechOptions()
            whisperLanguages = RecognitionLanguageCatalog.whisperOptions()
            if !suppressesLiveServices {
                whisperModels.refresh()
                gigaAMModels.refresh()
                localONNXModels.refresh()
                sileroVADModels.refresh()
            }
            validateSelectedLanguage()
            updateVAD()
            if !suppressesLiveServices {
                installEffectiveSileroVADIfNeeded()
            }
            refreshSpeechAuthorizationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSpeechAuthorizationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .voicePanelAudioInputDevicesDidChange)) { _ in
            devices = AudioInputDeviceManager.inputDevices()
        }
        .onChange(of: selectedPage) { _, page in
            if page != .general, state.phase == .monitoring {
                coordinator.stopMonitoring()
            }
        }
        .onDisappear {
            if state.phase == .monitoring { coordinator.stopMonitoring() }
            modelBenchmark.discardSample()
        }
        .sheet(isPresented: $showsInstalledModels) {
            InstalledModelsView(
                settings: settings,
                state: state,
                whisperModels: whisperModels,
                whisperRuntime: whisperRuntime,
                whisperDraftRuntime: whisperDraftRuntime,
                gigaAMModels: gigaAMModels,
                gigaAMRuntime: gigaAMRuntime,
                gigaAMDraftRuntime: gigaAMDraftRuntime,
                localONNXModels: localONNXModels,
                localONNXRuntime: localONNXRuntime
            )
        }
        .sheet(isPresented: $showsContextEditor) {
            RecognitionTextEditorSheet(
                title: "Recognition Context",
                help:
                    "Describe the subject, writing style, and punctuation you expect. Whisper can use this as an optional initial prompt.",
                placeholder:
                    "Technical discussion about macOS development. Preserve product names and use normal punctuation.",
                initialText: settings.recognitionContext
            ) { settings.recognitionContext = $0 }
        }
        .sheet(isPresented: $showsVocabularyEditor) {
            RecognitionTextEditorSheet(
                title: "Recognition Vocabulary",
                help: "Enter names and technical terms separated by new lines, commas, or semicolons.",
                placeholder: "VoicePanel\nQwen\nsherpa-onnx\nCore ML\nSwiftUI",
                initialText: settings.recognitionVocabulary
            ) { settings.recognitionVocabulary = $0 }
        }
        .sheet(isPresented: $showsSaveRecognitionPreset) {
            RecognitionPresetNameSheet { name in
                settings.saveCurrentRecognitionPreset(named: name)
            }
        }
        .sheet(isPresented: $showsPerformanceComparison) {
            if let comparison = selectedPerformanceComparison {
                PerformancePipelineComparisonSheet(
                    left: comparison.left,
                    right: comparison.right
                )
            }
        }
        .confirmationDialog(
            "Disable and delete transcript history?",
            isPresented: $asksToDisableHistory
        ) {
            Button("Disable and Delete History", role: .destructive) {
                settings.historyStorageMode = .none
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All saved transcripts, including pinned items, will be deleted. This cannot be undone.")
        }
        .confirmationDialog(
            "Record a new comparison sample?",
            isPresented: $asksToReplacePerformanceSample
        ) {
            Button("Record New Sample", role: .destructive) {
                beginPerformanceSampleRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new sample starts a new comparison and clears the current sample history.")
        }
    }

    private func settingsDetail(for page: SettingsPage) -> some View {
        VStack(spacing: 0) {
            settingsPageHeader(page)
            Divider()
            if page == .performance {
                performanceToolbar
                performanceTestWorkspace
            } else {
                Form {
                    switch page {
                    case .general:
                        generalSection
                    case .performance:
                        EmptyView()
                    case .workflow:
                        recordingSection
                        completionSection
                        compactPanelSection
                    case .history:
                        historySection
                    case .advanced:
                        advancedSection
                    }
                }
                .formStyle(.grouped)
                .accessibilityIdentifier("settings.form.\(page.rawValue)")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("settings.page.\(page.rawValue)")
    }

    private func settingsPageHeader(_ page: SettingsPage) -> some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: page.systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                if !page.subtitle.isEmpty {
                    Text(page.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, page == .performance ? 10 : 18)
    }

    @ViewBuilder
    private var generalSection: some View {
        Section("Microphone") {
            Picker("Input device", selection: $settings.selectedInputDeviceID) {
                Text("Follow system default").tag(UInt32(0))
                ForEach(devices) { device in Text(device.name).tag(UInt32(device.id)) }
                if settings.selectedInputDeviceID != 0,
                    !devices.contains(where: { UInt32($0.id) == settings.selectedInputDeviceID })
                {
                    Text("Unavailable selected microphone").tag(settings.selectedInputDeviceID)
                }
            }
            .accessibilityIdentifier("general.input-device")
            .onChange(of: settings.selectedInputDeviceID) { _, _ in
                coordinator.selectedInputDeviceDidChange()
            }
            .disabled(stateActivity.phase.isRecordingRelated || modelBenchmark.isRunning)

            if let warning = stateActivity.inputDeviceWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("Environment", selection: $settings.microphoneEnvironmentProfile) {
                ForEach(MicrophoneEnvironmentProfileID.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("general.environment")
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
            .onChange(of: settings.microphoneEnvironmentProfile) { _, _ in updateVAD() }

            Text(settings.microphoneEnvironmentProfile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                "The environment changes the speech threshold. Noise floor is measured from the current microphone and should stay stable while the room is unchanged."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)

            if stateActivity.phase == .monitoring && presentationContext.isVisible {
                SettingsLiveInputMonitoringView(
                    state: state,
                    onStop: { coordinator.stopMonitoring() }
                )
            } else {
                InputLevelMeterView(
                    currentDB: -90,
                    noiseFloorDB: state.noiseFloorDB,
                    thresholdDB: state.thresholdDB,
                    state: .silence,
                    isTesting: false
                )

                HStack {
                    Label("Background / pause", systemImage: "waveform.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Test Input") { coordinator.startMonitoring() }
                        .accessibilityIdentifier("general.input-test")
                        .disabled(
                            stateActivity.phase.isRecordingRelated || modelBenchmark.isRunning
                        )
                }
            }

            if settings.microphoneEnvironmentProfile == .custom {
                Button("Edit Custom Environment…") { selectedPage = .advanced }
            }
        }

        Section("Recognition") {
            if settings.recognitionBackend != .appleSpeech {
                Picker("Profile", selection: $settings.recognitionProfile) {
                    ForEach(RecognitionProfileID.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .accessibilityIdentifier("general.profile")
                .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
                .onChange(of: settings.recognitionProfile) { _, _ in
                    updateVAD()
                    installEffectiveSileroVADIfNeeded()
                }

                Text(settings.recognitionProfile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.effectiveVoiceActivityDetectionMode != .energy {
                    sileroStatusLabel
                }
            }

            Picker("Engine", selection: $settings.recognitionBackend) {
                ForEach(AppSettings.RecognitionBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .accessibilityIdentifier("general.engine")
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
            .onChange(of: settings.recognitionBackend) { _, _ in
                modelActionError = nil
                if modelBenchmark.isRunning { modelBenchmark.cancel() }
                settings.reconcileDraftSelections()
                validateSelectedLanguage()
                installEffectiveSileroVADIfNeeded()
            }

            engineSelectionControls(showAvailability: false, showCoreML: true)
        }

        if settings.recognitionBackend != .appleSpeech {
            Section("Live draft") {
                generalLiveDraftControls
            }
        }

        Section("Model files") {
            generalModelFileControls

            Button {
                showsInstalledModels = true
            } label: {
                Label("Manage Installed Models…", systemImage: "internaldrive")
            }
            .accessibilityIdentifier("general.manage-models")
            Text("Install, inspect, or remove local recognition models and Whisper Core ML encoders.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

        Section("Current setup") {
            LabeledContent("Recognition") {
                Text("\(settings.recognitionBackend.title) · \(activeModelTitle)")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Language") {
                Text(activeLanguageTitle)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Microphone") {
                Text(activeInputDeviceTitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Processing") {
                Text(activeProcessingTitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text(generalPipelineSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let modelActionError {
            Section("Issue") {
                Text(modelActionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func engineSelectionControls(
        showAvailability: Bool,
        showCoreML: Bool
    ) -> some View {
        switch settings.recognitionBackend {
        case .appleSpeech:
            Label(speechAuthorizationLabel, systemImage: speechAuthorizationSymbol)
                .foregroundStyle(speechAuthorizationColor)
            Picker("Language", selection: $settings.appleSpeechLanguageIdentifier) {
                ForEach(appleSpeechLanguages) { option in
                    languageLabel(option).tag(option.id)
                }
            }
            if speechAuthorizationStatus == .denied || speechAuthorizationStatus == .restricted {
                Button("Open Speech Recognition Settings") { openSpeechPrivacySettings() }
            }

        case .whisper:
            Picker("Model", selection: $settings.whisperModelID) {
                ForEach(WhisperModelID.allCases) { model in
                    Text(model.title).tag(model)
                }
            }
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
            .onChange(of: settings.whisperModelID) { _, model in
                if modelBenchmark.isRunning { modelBenchmark.cancel() }
                if model.coreMLEncoder == nil, settings.whisperComputeMode.requestsCoreML {
                    settings.whisperComputeMode = .metal
                }
                settings.reconcileDraftSelections()
                validateSelectedLanguage()
                modelActionError = nil
            }

            Picker("Language", selection: $settings.whisperLanguageCode) {
                ForEach(whisperLanguages) { option in
                    languageLabel(option).tag(option.id)
                }
            }
            .disabled(settings.whisperModelID.isEnglishOnly || modelBenchmark.isRunning)
            .onChange(of: settings.whisperLanguageCode) { _, _ in
                settings.reconcileDraftSelections()
            }

            Picker("Compute", selection: $settings.whisperComputeMode) {
                ForEach(availableWhisperComputeModes(for: settings.whisperModelID)) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

            if showAvailability {
                selectedModelAvailability
            }
            if showCoreML {
                whisperCoreMLControls(for: settings.whisperModelID)
            }

        case .gigaAM:
            Picker("Model", selection: $settings.gigaAMModelID) {
                ForEach(GigaAMModelID.allCases) { model in
                    Text("\(model.title) — \(model.capabilityLabel)").tag(model)
                }
            }
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
            .onChange(of: settings.gigaAMModelID) { _, _ in
                if modelBenchmark.isRunning { modelBenchmark.cancel() }
                settings.reconcileDraftSelections()
                modelActionError = nil
            }

            LabeledContent("Language") {
                Text("Russian").foregroundStyle(.secondary)
            }
            Picker("Compute", selection: $settings.gigaAMExecutionProvider) {
                ForEach(AppSettings.GigaAMExecutionProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            if showAvailability {
                selectedModelAvailability
            }

        case .qwen3ASR:
            Picker("Qwen3-ASR model", selection: $settings.qwen3ASRModelID) {
                ForEach(LocalONNXModelID.qwen3ASRChoices) { model in
                    Text(model.title).tag(model)
                }
            }
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
            .onChange(of: settings.qwen3ASRModelID) { _, _ in
                if modelBenchmark.isRunning { modelBenchmark.cancel() }
                modelActionError = nil
            }
            LabeledContent("Language") {
                Text("Automatic multilingual recognition").foregroundStyle(.secondary)
            }
            Picker("Compute", selection: $settings.localONNXExecutionProvider) {
                ForEach(AppSettings.LocalONNXExecutionProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            if showAvailability {
                selectedModelAvailability
            }

        case .parakeet:
            LabeledContent("Model") {
                Text(LocalONNXModelID.parakeetTDT06BV3Int8.title)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Language") {
                Text("Automatic European-language recognition").foregroundStyle(.secondary)
            }
            Picker("Compute", selection: $settings.localONNXExecutionProvider) {
                ForEach(AppSettings.LocalONNXExecutionProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            if showAvailability {
                selectedModelAvailability
            }
        }
    }

    @ViewBuilder
    private var selectedModelAvailability: some View {
        let isInstalled: Bool = {
            switch settings.recognitionBackend {
            case .appleSpeech:
                return true
            case .whisper:
                return whisperModels.isInstalled(settings.whisperModelID)
            case .gigaAM:
                return gigaAMModels.isInstalled(settings.gigaAMModelID)
            case .qwen3ASR, .parakeet:
                guard let model = settings.selectedLocalONNXModel else { return false }
                return localONNXModels.isInstalled(model)
            }
        }()

        HStack {
            Label(
                isInstalled ? "Selected model is installed" : "Selected model must be installed",
                systemImage: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
            )
            .foregroundStyle(isInstalled ? Color.green : Color.secondary)
        }
    }

    @ViewBuilder
    private var generalModelFileControls: some View {
        switch settings.recognitionBackend {
        case .appleSpeech:
            Text("Apple Speech is built into macOS and does not require a downloaded model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .whisper:
            whisperModelControls(
                model: settings.whisperModelID,
                runtime: whisperRuntime,
                roleLabel: "Final model"
            )
        case .gigaAM:
            gigaAMModelControls(
                model: settings.gigaAMModelID,
                runtime: gigaAMRuntime,
                roleLabel: "Final model"
            )
        case .qwen3ASR, .parakeet:
            if let model = settings.selectedLocalONNXModel {
                localONNXModelControls(model: model)
            }
        }
    }

    private var performanceTestWorkspace: some View {
        HStack(alignment: .top, spacing: 12) {
            performanceSampleSidebar
                .frame(width: 350)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("performance.sample-sidebar")

            performanceConfigurationPanel
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("performance.configuration-panel")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var performanceConfigurationPanel: some View {
        VStack(spacing: 0) {
            performanceStatusBar

            Form {
                performanceSection
            }
            .formStyle(.grouped)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("performance.configuration-scroll")
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var performanceToolbar: some View {
        HStack(alignment: .center, spacing: 10) {
            Picker("Test stage", selection: $performanceTestMode) {
                Text("1. Model Benchmark")
                    .tag(PerformanceTestMode.modelBenchmark)
                    .accessibilityIdentifier("performance.mode-option.model-benchmark")
                Text("2. Pipeline Validation")
                    .tag(PerformanceTestMode.pipelineValidation)
                    .accessibilityIdentifier("performance.mode-option.pipeline-validation")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 330)
            .accessibilityIdentifier("performance.mode-picker")
            .disabled(modelBenchmark.isRunning)
            .onChange(of: performanceTestMode) { _, mode in
                if !isRestoringPerformanceRunConfiguration {
                    validationRepetitions = mode == .modelBenchmark ? 3 : 1
                }
                performanceConfigurationMessage = nil
            }

            Spacer(minLength: 12)

            Button("Reset") {
                performanceSettings.replacePerformanceConfiguration(from: settings)
                showPerformanceConfigurationMessage("Test configuration reset.")
            }
            .controlSize(.small)
            .disabled(modelBenchmark.isRunning || performanceConfigurationMatchesGeneral)
            .help("Reset test settings from General")

            Button("Save as Active Setup") {
                savePerformanceSetup()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                state.phase.isRecordingRelated || modelBenchmark.isRunning
                    || performanceConfigurationMatchesGeneral
            )

            if modelBenchmark.isRunning {
                Button("Cancel Test", role: .cancel) {
                    modelBenchmark.cancel()
                }
                .controlSize(.small)
            } else {
                Button {
                    runPerformanceTest()
                } label: {
                    Label(
                        performanceTestMode == .pipelineValidation
                            ? "Validate Pipeline" : "Run Benchmark",
                        systemImage: "play.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    !modelBenchmark.hasRecordedSample
                        || performanceSettings.recognitionBackend == .appleSpeech
                        || state.phase.isRecordingRelated
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("performance.toolbar")
    }

    @ViewBuilder
    private var performanceStatusBar: some View {
        if modelBenchmark.isRunning || modelBenchmark.errorMessage != nil
            || modelBenchmark.inputWarning != nil
            || performanceConfigurationMessage != nil
        {
            VStack(alignment: .leading, spacing: 7) {
                if modelBenchmark.isRunning {
                    Text(modelBenchmark.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let errorMessage = modelBenchmark.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                if let inputWarning = modelBenchmark.inputWarning {
                    Label(inputWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }

                if modelBenchmark.isRunning, !modelBenchmark.isRecordingSample {
                    if modelBenchmark.showsDeterminateProgress {
                        ProgressView(value: modelBenchmark.progress)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let performanceConfigurationMessage {
                    Text(performanceConfigurationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("performance.whisper-comparison-status")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
        }
    }

    private var performanceSampleSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                performanceSampleControls

                if modelBenchmark.isRecordingSample {
                    ProgressView(value: min(modelBenchmark.progress, 1))
                }

                if let result = displayedPerformanceResult {
                    performanceResultCard(result)
                        .id(result.id)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(16)
            .animation(
                .easeInOut(duration: 0.22),
                value: displayedPerformanceResultLayoutKey
            )

            if !modelBenchmark.runs.isEmpty {
                Divider()
                performanceHistory
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
            } else {
                Spacer(minLength: 12)
            }

            Divider()
            HStack {
                Text("Current sample")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(modelBenchmark.hasRecordedSample ? "Active" : "Empty")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var performanceSampleControls: some View {
        if modelBenchmark.hasRecordedSample {
            Text(
                String(
                    format: "%@ · %.1f s",
                    modelBenchmark.sampleDisplayName
                        ?? modelBenchmark.sampleEnvironment?.microphone
                        ?? inputDeviceTitle(for: performanceSettings),
                    modelBenchmark.recordedSampleDuration,
                )
            )
            .font(.callout.weight(.medium))
            .lineLimit(2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Record New") {
                        if modelBenchmark.runs.isEmpty {
                            beginPerformanceSampleRecording()
                        } else {
                            asksToReplacePerformanceSample = true
                        }
                    }
                    .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

                    Button("Import Audio…") {
                        presentPerformanceAudioImporter()
                    }
                    .accessibilityIdentifier("performance.import-audio")
                    .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

                    Button(modelBenchmark.isPlayingSample ? "Stop" : "Play") {
                        if modelBenchmark.isPlayingSample {
                            modelBenchmark.stopSamplePlayback()
                        } else {
                            modelBenchmark.playRecordedSample()
                        }
                    }
                    .disabled(modelBenchmark.isRunning)
                }

                HStack(spacing: 8) {
                    Button("Save Audio…") {
                        presentPerformanceAudioExporter()
                    }
                    .disabled(modelBenchmark.isRunning)

                    Button("Discard", role: .destructive) {
                        modelBenchmark.discardSample()
                        selectedPerformanceRunID = nil
                    }
                    .disabled(modelBenchmark.isRunning)
                }
            }
            .controlSize(.small)
        } else {
            Picker("Microphone", selection: $performanceSettings.selectedInputDeviceID) {
                Text("Follow system default").tag(UInt32(0))
                ForEach(devices) { device in
                    Text(device.name).tag(UInt32(device.id))
                }
                if performanceSettings.selectedInputDeviceID != 0,
                    !devices.contains(where: {
                        UInt32($0.id) == performanceSettings.selectedInputDeviceID
                    })
                {
                    Text("Unavailable selected microphone")
                        .tag(performanceSettings.selectedInputDeviceID)
                }
            }
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

            Button("Record Sample · 30 s max") {
                beginPerformanceSampleRecording()
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

            Button("Import Audio…") {
                presentPerformanceAudioImporter()
            }
            .accessibilityIdentifier("performance.import-audio")
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
        }

        if modelBenchmark.isRecordingSample {
            Button("Stop Recording") {
                modelBenchmark.stopRecording()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var displayedPerformanceResult: RecognitionValidationRun? {
        if let selectedPerformanceRunID,
            let selected = modelBenchmark.runs.first(where: { $0.id == selectedPerformanceRunID })
        {
            return selected
        }
        return modelBenchmark.result ?? modelBenchmark.runs.last
    }

    private var effectiveSelectedPerformanceRunID: UUID? {
        selectedPerformanceRunID ?? modelBenchmark.result?.id ?? modelBenchmark.runs.last?.id
    }

    private var displayedPerformanceResultLayoutKey: String {
        guard let result = displayedPerformanceResult else { return "none" }
        return [
            result.id.uuidString,
            String(result.transcript.count),
            String(result.pipelineSummary?.chunks.count ?? -1),
            String(result.pipelineSummary?.rejectedResultCount ?? -1),
            String(performanceResultUsesCurrentConfiguration(result)),
        ].joined(separator: "|")
    }

    private func performanceResultUsesCurrentConfiguration(
        _ result: RecognitionValidationRun
    ) -> Bool {
        guard
            let storedSignature =
                result.target.configuration?["performanceConfigurationSignature"]
        else {
            // Runs created before configuration signatures were introduced remain viewable.
            return true
        }
        return performanceTestMode(for: result) == performanceTestMode
            && storedSignature == currentPerformanceConfigurationSignature
    }

    private var performanceWhisperBoundaryStrategyBinding: Binding<WhisperBoundaryStrategy> {
        Binding(
            get: { performanceSettings.whisperInferenceConfiguration.boundaryStrategy },
            set: { strategy in
                if performanceSettings.recognitionProfile != .custom {
                    performanceSettings.beginCustomizingRecognitionProfile()
                }
                performanceSettings.whisperBoundaryStrategy = strategy
            }
        )
    }

    private func performanceResultCard(_ result: RecognitionValidationRun) -> some View {
        let usesCurrentConfiguration = performanceResultUsesCurrentConfiguration(result)
        return VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(
                            result.id == modelBenchmark.result?.id && usesCurrentConfiguration
                                ? "Latest" : "Previous"
                        )
                        .font(.callout.weight(.semibold))
                        Text(
                            result.pipelineSummary == nil ? "Model Benchmark" : "Pipeline Validation"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if result.id != modelBenchmark.result?.id {
                            if restoredPerformanceRunID == result.id {
                                Text("Setup loaded")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("performance.setup-loaded")
                                    .accessibilityLabel(
                                        "Setup loaded; \(performanceConfigurationAccessibilitySummary)"
                                    )
                                    .accessibilityValue(performanceConfigurationAccessibilitySummary)
                            } else {
                                Text("View only")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if !usesCurrentConfiguration {
                        Label(
                            "Settings changed. Run \(performanceTestMode == .pipelineValidation ? "Validate Pipeline" : "Run Benchmark") to update this result.",
                            systemImage: "arrow.clockwise.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("performance.result-configuration-changed")
                    }

                    if let summary = result.pipelineSummary {
                        HStack(spacing: 7) {
                            performanceResultBadge(result.target.profile)
                            performanceResultBadge("\(summary.chunks.count) chunks")
                            performanceResultBadge("\(summary.rejectedResultCount) rejected")
                        }
                    } else {
                        Text("\(result.modelName) · \(result.target.compute)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(inferenceSummary(for: result))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let accuracy = accuracy(for: result) {
                        Text(accuracySummary(accuracy))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let configurationSummary = validationConfigurationSummary(for: result) {
                        Text(configurationSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(result.transcript.isEmpty ? "No text recognized" : result.transcript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(12)
            }
        }
        .frame(minHeight: 120, idealHeight: 210, maxHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("performance.result-card")
    }

    private func performanceResultBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }

    private var performanceHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("History · \(modelBenchmark.runs.count)")
                    .font(.headline)
                Spacer()
                Text("Current sample")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(modelBenchmark.runs.reversed())) { run in
                        performanceHistoryRow(run)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .accessibilityIdentifier("performance.history-scroll")
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                Button("Compare Selected…") {
                    showsPerformanceComparison = true
                }
                .disabled(selectedPerformanceComparison == nil || modelBenchmark.isRunning)
                .accessibilityIdentifier("performance.compare-selected")

                Button("Export JSON…") {
                    exportValidationReport()
                }

                Button("Clear History", role: .destructive) {
                    modelBenchmark.clearRuns()
                    selectedPerformanceRunID = nil
                    comparedPerformanceRunIDs.removeAll()
                    validationExportMessage = nil
                }
                .disabled(modelBenchmark.isRunning)

                Spacer(minLength: 8)
            }
            .controlSize(.small)

            if let validationExportMessage {
                Text(validationExportMessage)
                    .font(.caption)
                    .foregroundStyle(validationExportFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func performanceHistoryRow(_ run: RecognitionValidationRun) -> some View {
        let isSelected = run.id == effectiveSelectedPerformanceRunID
        let isCurrent = run.id == modelBenchmark.result?.id

        let isCompared = comparedPerformanceRunIDs.contains(run.id)
        return HStack(spacing: 8) {
            if performanceRunSupportsComparison(run) {
                Button {
                    togglePerformanceComparisonSelection(run)
                } label: {
                    Image(systemName: isCompared ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isCompared ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isCompared ? "Remove from comparison" : "Select for comparison")
                .accessibilityLabel(
                    isCompared ? "Selected for comparison" : "Select for comparison"
                )
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Button {
                selectPerformanceRun(run)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(performanceHistoryTitle(for: run))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if isCurrent {
                            Text("Current")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(performanceHistorySummary(for: run))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(performanceHistoryDate(for: run.testedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isSelected
                                ? Color.accentColor
                                : Color(nsColor: .separatorColor).opacity(0.55),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(modelBenchmark.isRunning)
        }
        .accessibilityIdentifier(isCurrent ? "performance.history.current" : "performance.history.previous")
        .disabled(modelBenchmark.isRunning)
    }

    private var selectedPerformanceComparison:
        (
            left: PerformancePipelineComparisonItem,
            right: PerformancePipelineComparisonItem
        )?
    {
        let selected = modelBenchmark.runs
            .filter {
                performanceRunSupportsComparison($0)
                    && comparedPerformanceRunIDs.contains($0.id)
            }
            .sorted { $0.testedAt < $1.testedAt }
        guard selected.count == 2 else { return nil }
        guard
            let left = performanceComparisonItem(for: selected[0]),
            let right = performanceComparisonItem(for: selected[1])
        else {
            return nil
        }
        return (left, right)
    }

    private func performanceRunSupportsComparison(_ run: RecognitionValidationRun) -> Bool {
        run.pipelineSummary != nil && modelBenchmark.pipelineVisualization(for: run.id) != nil
    }

    private func performanceComparisonItem(
        for run: RecognitionValidationRun
    ) -> PerformancePipelineComparisonItem? {
        guard
            let summary = run.pipelineSummary,
            let visualization = modelBenchmark.pipelineVisualization(for: run.id)
        else {
            return nil
        }
        return PerformancePipelineComparisonItem(
            run: run,
            visualization: visualization,
            summary: summary,
            reusesPreviousChunkContext: run.target.configuration?["reusePreviousChunkContext"]
                .map { $0 == "enabled" }
        )
    }

    private func togglePerformanceComparisonSelection(_ run: RecognitionValidationRun) {
        if comparedPerformanceRunIDs.remove(run.id) != nil { return }
        if comparedPerformanceRunIDs.count == 2,
            let oldest = modelBenchmark.runs
                .filter({ comparedPerformanceRunIDs.contains($0.id) })
                .min(by: { $0.testedAt < $1.testedAt })
        {
            comparedPerformanceRunIDs.remove(oldest.id)
        }
        comparedPerformanceRunIDs.insert(run.id)
    }

    private func performanceHistoryTitle(for run: RecognitionValidationRun) -> String {
        run.pipelineSummary == nil ? run.target.model : run.target.profile
    }

    private func performanceHistorySummary(for run: RecognitionValidationRun) -> String {
        if let summary = run.pipelineSummary {
            let chunks = summary.chunks.count == 1 ? "1 chunk" : "\(summary.chunks.count) chunks"
            if summary.rejectedResultCount > 0 {
                return "\(chunks) · \(summary.rejectedResultCount) rejected"
            }
            return chunks
        }
        return String(format: "RTF %.2f · %d passes", run.realTimeFactor, run.repetitionCount)
    }

    private func performanceHistoryDate(for date: Date) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        }
        return "\(day), \(date.formatted(.dateTime.hour().minute()))"
    }

    @ViewBuilder
    private var performanceSection: some View {
        switch performanceTestMode {
        case .modelBenchmark:
            modelBenchmarkConfigurationSection
        case .pipelineValidation:
            pipelineValidationConfigurationSection
        }
        if !modelBenchmark.whisperComparisonResults.isEmpty {
            performanceWhisperComparisonResults
        }
        performanceScoringAndReportSection
    }

    @ViewBuilder
    private var modelBenchmarkConfigurationSection: some View {
        Section {
            Picker("Engine", selection: $performanceSettings.recognitionBackend) {
                ForEach(AppSettings.RecognitionBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
            .accessibilityIdentifier("performance.engine-picker")
            .onChange(of: performanceSettings.recognitionBackend) { _, _ in
                modelActionError = nil
                performanceSettings.reconcileDraftSelections()
            }

            if performanceSettings.recognitionBackend == .appleSpeech {
                Text(
                    "Apple Speech uses a live system session and cannot run against a reusable offline sample. Choose a local engine for benchmark testing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                performanceEngineSelectionControls

                LabeledContent("Model size") {
                    Text(modelSizeTitle(for: performanceSettings))
                        .foregroundStyle(.secondary)
                }

                performanceModelInferenceControls

                if performanceSettings.recognitionBackend == .whisper {
                    performanceWhisperComparisonControls
                }
            }
        } header: {
            Text("Benchmark Target")
                .accessibilityIdentifier("performance.configuration-heading")
        }
    }

    private var performanceWhisperComparisonControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Run Whisper Comparison") {
                if suppressesLiveServices {
                    showPerformanceConfigurationMessage("Whisper comparison controls are ready.")
                } else {
                    runWhisperComparison()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("performance.run-whisper-comparison")
            .disabled(!modelBenchmark.hasRecordedSample || modelBenchmark.isRunning)

            SettingsDisclosureGroup(
                title: "Advanced Whisper Comparison",
                accessibilityIdentifier: "performance.whisper-comparison-advanced-toggle",
                isExpanded: $performanceWhisperComparisonAdvancedExpanded
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Edge padding") {
                        TextField(
                            "Seconds",
                            value: $whisperComparisonEdgePadding,
                            format: .number.precision(.fractionLength(0...2))
                        )
                        .frame(width: 90)
                        .accessibilityIdentifier("performance.whisper-edge-padding")
                    }
                    LabeledContent("Forced-cut offset") {
                        TextField(
                            "Seconds",
                            value: $whisperComparisonMaximumChunkOffset,
                            format: .number.precision(.fractionLength(0...2))
                        )
                        .frame(width: 90)
                        .accessibilityIdentifier("performance.whisper-forced-cut-offset")
                    }
                    Text(
                        "Padding is applied to a fresh 16 kHz copy before VAD. The offset adjusts the selected profile's maximum chunk duration within 2–30 seconds."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var performanceWhisperComparisonResults: some View {
        Section("Whisper Comparison") {
            ForEach(modelBenchmark.whisperComparisonResults) { presentation in
                let run = presentation.run
                let execution = presentation.execution
                VStack(alignment: .leading, spacing: 5) {
                    Text(execution.entry.variant.title)
                        .font(.callout.weight(.semibold))
                    HStack(spacing: 8) {
                        if let accuracy = accuracy(for: run) {
                            Text(
                                String(
                                    format: "WER %.1f%% · CER %.1f%%",
                                    accuracy.wordErrorRate * 100,
                                    accuracy.characterErrorRate * 100
                                )
                            )
                        }
                        let punctuation = RecognitionPunctuationScorer.score(
                            reference: validationReferenceTranscript,
                            hypothesis: run.transcript
                        )
                        Text(String(format: "Punctuation F1 %.2f", punctuation.f1))
                    }
                    .font(.caption.monospacedDigit())
                    Text(
                        "Attempts \(execution.repairAttemptCount) · accepted \(execution.acceptedRepairCount) · fallback \(execution.fallbackCount) · inferences \(execution.inferenceCount) · \(String(format: "%.2f s", run.processingDuration)) · RTF \(String(format: "%.2f", run.realTimeFactor))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var performanceModelInferenceControls: some View {
        SettingsDisclosureGroup(
            title: "Model-specific inference",
            accessibilityIdentifier: "performance.model-specific-toggle",
            isExpanded: $performanceModelSpecificExpanded
        ) {
            VStack(alignment: .leading, spacing: 10) {
                switch performanceSettings.recognitionBackend {
                case .appleSpeech:
                    EmptyView()

                case .whisper:
                    Stepper(
                        "Threads: \(performanceSettings.whisperThreadCount)",
                        value: $performanceSettings.whisperThreadCount,
                        in: 1...16
                    )
                    Toggle("Flash Attention", isOn: $performanceSettings.whisperFlashAttention)
                    Picker(
                        "Boundary repair",
                        selection: performanceWhisperBoundaryStrategyBinding
                    ) {
                        ForEach(WhisperBoundaryStrategy.allCases) { strategy in
                            Text(strategy.title).tag(strategy)
                        }
                    }
                    Text(performanceSettings.whisperBoundaryStrategy.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if performanceSettings.recognitionProfile == .custom {
                        Toggle(
                            "Use configured context",
                            isOn: $performanceSettings.recognitionContextEnabled
                        )
                        Toggle(
                            "Use configured vocabulary",
                            isOn: $performanceSettings.recognitionVocabularyEnabled
                        )
                        Toggle(
                            "Custom decoding strategy",
                            isOn: $performanceSettings.whisperCustomDecodingEnabled
                        )
                        if performanceSettings.whisperCustomDecodingEnabled {
                            Picker("Decoding", selection: $performanceSettings.whisperDecodingStrategy) {
                                ForEach(WhisperDecodingStrategy.allCases) { strategy in
                                    Text(strategy.title).tag(strategy)
                                }
                            }
                            if performanceSettings.whisperDecodingStrategy == .greedy {
                                Stepper(
                                    "Candidates: \(performanceSettings.whisperGreedyBestOf)",
                                    value: $performanceSettings.whisperGreedyBestOf,
                                    in: 1...8
                                )
                            } else {
                                Stepper(
                                    "Beam size: \(performanceSettings.whisperBeamSize)",
                                    value: $performanceSettings.whisperBeamSize,
                                    in: 1...10
                                )
                            }
                        }
                    } else {
                        Text(
                            "Decoder, configured prompt, and vocabulary currently follow the \(performanceSettings.recognitionProfile.title) profile."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Button("Customize Inference Settings…") {
                            performanceSettings.beginCustomizingRecognitionProfile()
                        }
                    }

                case .gigaAM:
                    Stepper(
                        "Threads: \(performanceSettings.gigaAMThreadCount)",
                        value: $performanceSettings.gigaAMThreadCount,
                        in: 1...16
                    )
                    durationControl(
                        title: "Maximum model chunk",
                        value: $performanceSettings.gigaAMMaximumChunkDuration,
                        range: 1...20,
                        step: 0.5,
                        suffix: "s"
                    )

                case .qwen3ASR, .parakeet:
                    Stepper(
                        "Threads: \(performanceSettings.localONNXThreadCount)",
                        value: $performanceSettings.localONNXThreadCount,
                        in: 1...16
                    )
                    durationControl(
                        title: "Maximum model chunk",
                        value: $performanceSettings.localONNXMaximumChunkDuration,
                        range: 1...20,
                        step: 0.5,
                        suffix: "s"
                    )
                }
            }
            .disabled(modelBenchmark.isRunning)
        }
    }

    @ViewBuilder
    private var pipelineValidationConfigurationSection: some View {
        Section {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recognition model")
                    Text(
                        "\(performanceSettings.recognitionBackend.title) · \(modelTitle(for: performanceSettings)) · \(computeTitle(for: performanceSettings))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(
                        modelBenchmarkTargetMatchesGeneral
                            ? "From active setup" : "Selected in Model Benchmark"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Change Model") {
                    performanceTestMode = .modelBenchmark
                    validationRepetitions = 3
                }
                .disabled(modelBenchmark.isRunning)
            }

            if performanceSettings.recognitionBackend == .appleSpeech {
                Text("Choose a local engine in Model Benchmark before validating the pipeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Profile", selection: $performanceSettings.recognitionProfile) {
                    ForEach(RecognitionProfileID.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .disabled(modelBenchmark.isRunning)
                .accessibilityIdentifier("performance.pipeline-profile")
                .onChange(of: performanceSettings.recognitionProfile) { _, _ in
                    installPerformanceSileroVADIfNeeded()
                }

                Text(performanceSettings.recognitionProfile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Environment", selection: $performanceSettings.microphoneEnvironmentProfile) {
                    ForEach(MicrophoneEnvironmentProfileID.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(modelBenchmark.isRunning)

                if performanceSettings.effectiveVoiceActivityDetectionMode != .energy {
                    sileroStatusLabel
                }

                performancePipelineStageStatus
                performancePipelineSummary
                performancePipelineInspectionView
                performanceAdvancedPipelineControls
            }
        } header: {
            Text("Pipeline Setup")
                .accessibilityIdentifier("performance.configuration-heading")
        }
    }

    @ViewBuilder
    private var performancePipelineStageStatus: some View {
        if performanceTestMode == .pipelineValidation,
            modelBenchmark.isRunning,
            let stage = modelBenchmark.pipelineStage
        {
            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(stage.title)
                        .font(.callout.weight(.medium))
                    Text(stage.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
            )
            .accessibilityIdentifier("performance.pipeline-stage")
        }
    }

    private var performancePipelineSummary: some View {
        let tuning = performanceSettings.effectiveRecognitionConfiguration.tuning
        let segmenter = performanceSettings.makeFinalRecognitionSegmenterConfiguration()
        return VStack(alignment: .leading, spacing: 5) {
            LabeledContent("VAD") {
                Text(tuning.voiceActivityDetectionMode.title)
                    .foregroundStyle(.secondary)
            }
            if performanceSettings.recognitionBackend == .whisper {
                LabeledContent("Forced-chunk guard") {
                    Text("Isolated Silero check")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Phrase boundary") {
                Text(
                    "\(tuning.endOfSpeechSilenceDuration.formatted(.number.precision(.fractionLength(2)))) s silence"
                )
                .foregroundStyle(.secondary)
            }
            LabeledContent("Audio margins") {
                Text(
                    "\(tuning.preRollDuration.formatted(.number.precision(.fractionLength(2)))) / \(tuning.postRollDuration.formatted(.number.precision(.fractionLength(2)))) s"
                )
                .foregroundStyle(.secondary)
            }
            LabeledContent("Maximum chunk") {
                Text(
                    "\(segmenter.maximumChunkDuration.formatted(.number.precision(.fractionLength(1)))) s"
                )
                .foregroundStyle(.secondary)
            }
            LabeledContent("Pause-balanced chunking") {
                Text(tuning.pauseBalancedChunkingEnabled ? "Enabled" : "Disabled")
                    .foregroundStyle(.secondary)
            }
            if segmenter.overlapDuration > 0 {
                LabeledContent("Forced-boundary overlap") {
                    Text(
                        "\(segmenter.overlapDuration.formatted(.number.precision(.fractionLength(2)))) s"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Result protection") {
                Text(tuning.hallucinationProtectionEnabled ? "Enabled" : "Disabled")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Boundary cleanup") {
                Text(tuning.finalTranscriptCleanupEnabled ? "Enabled" : "Disabled")
                    .foregroundStyle(.secondary)
            }
            if performanceSettings.recognitionBackend == .gigaAM {
                LabeledContent("Russian correction") {
                    Text(tuning.gigaAMRussianCorrectionEnabled ? "Enabled" : "Disabled")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var performancePipelineInspectionView: some View {
        if performanceTestMode == .pipelineValidation,
            let visualization = displayedPerformancePipelineVisualization,
            let summary = displayedPerformancePipelineSummary
        {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pipeline visualization")
                        .font(.headline)
                    Text(performancePipelineStatistics(visualization: visualization, summary: summary))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                PerformancePipelineVisualizationView(
                    visualization: visualization,
                    summary: summary,
                    reusesPreviousChunkContext: displayedPipelineContextReuse
                )

            }
            .padding(.vertical, 4)
        }
    }

    private func performancePipelineStatistics(
        visualization: PerformancePipelineVisualization,
        summary: RecognitionPipelineValidationSummary
    ) -> String {
        let speechRegionCount = visualization.speechSpans.reduce(into: 0) { count, span in
            if span.kind == .speech { count += 1 }
        }
        return [
            timeTitle(visualization.duration),
            "VAD \(durationTitle(visualization.analysisDuration))",
            "\(speechRegionCount) speech region\(speechRegionCount == 1 ? "" : "s")",
            "\(summary.chunks.count) accepted chunk\(summary.chunks.count == 1 ? "" : "s")",
            "\(summary.rejectedResultCount) rejected result\(summary.rejectedResultCount == 1 ? "" : "s")",
        ].joined(separator: " · ")
    }

    private var displayedPipelineContextReuse: Bool? {
        if modelBenchmark.isRunning {
            guard performanceSettings.recognitionBackend == .whisper else { return nil }
            return performanceSettings.whisperInferenceConfiguration.boundaryStrategy
                == .contextualRetry
        }
        guard
            let value = displayedPerformanceResult?.target.configuration?["reusePreviousChunkContext"]
        else {
            return nil
        }
        return value == "enabled"
    }

    private var displayedPerformancePipelineSummary: RecognitionPipelineValidationSummary? {
        if modelBenchmark.isRunning {
            return modelBenchmark.pipelineSummary
        }
        guard let result = displayedPerformanceResult,
            performanceResultUsesCurrentConfiguration(result)
        else {
            return nil
        }
        return result.pipelineSummary
    }

    private var displayedPerformancePipelineVisualization: PerformancePipelineVisualization? {
        if modelBenchmark.isRunning {
            return modelBenchmark.pipelineVisualization
        }
        guard let result = displayedPerformanceResult, result.pipelineSummary != nil else {
            return nil
        }
        guard performanceResultUsesCurrentConfiguration(result) else { return nil }
        return modelBenchmark.pipelineVisualization(for: result.id)
    }

    private var performanceAdvancedPipelineControls: some View {
        SettingsDisclosureGroup(
            title: "Advanced Pipeline Parameters",
            accessibilityIdentifier: "performance.advanced-pipeline-toggle",
            isExpanded: $performanceAdvancedPipelineExpanded
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if performanceSettings.recognitionProfile == .custom {
                    Picker("VAD engine", selection: $performanceSettings.voiceActivityDetectionMode) {
                        ForEach(VoiceActivityDetectionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: performanceSettings.voiceActivityDetectionMode) { _, mode in
                        if mode != .energy { installEffectiveSileroVADIfNeeded() }
                    }

                    if performanceSettings.voiceActivityDetectionMode != .energy {
                        HStack {
                            Text("Speech probability")
                            Slider(
                                value: $performanceSettings.sileroThreshold,
                                in: 0.2...0.8,
                                step: 0.05
                            )
                            Text(
                                performanceSettings.sileroThreshold.formatted(
                                    .number.precision(.fractionLength(2))
                                )
                            )
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                        }
                        durationControl(
                            title: "Minimum neural speech",
                            value: $performanceSettings.sileroMinimumSpeechDuration,
                            range: 0.05...0.5,
                            step: 0.05,
                            suffix: "s"
                        )
                    }

                    durationControl(
                        title: "Speech end pause",
                        value: $performanceSettings.voiceEndSilenceDuration,
                        range: 0.2...1.5,
                        step: 0.05,
                        suffix: "s"
                    )
                    durationControl(
                        title: "Audio before speech",
                        value: $performanceSettings.voicePreRollDuration,
                        range: 0...1,
                        step: 0.05,
                        suffix: "s"
                    )
                    durationControl(
                        title: "Audio after speech",
                        value: $performanceSettings.voicePostRollDuration,
                        range: 0...1,
                        step: 0.05,
                        suffix: "s"
                    )
                    if performanceSettings.recognitionBackend == .whisper {
                        durationControl(
                            title: "Maximum Whisper chunk",
                            value: $performanceSettings.whisperChunkDuration,
                            range: 2...30,
                            step: 0.5,
                            suffix: "s"
                        )
                        durationControl(
                            title: "Whisper chunk overlap",
                            value: $performanceSettings.whisperOverlapDuration,
                            range: 0...2,
                            step: 0.1,
                            suffix: "s"
                        )
                    }
                    Toggle(
                        "Pause-balanced chunking",
                        isOn: $performanceSettings.pauseBalancedChunkingEnabled
                    )
                    Text(
                        "Keeps bounded lookahead and splits chunked recognition audio inside a real pause. Apple Speech retains this setting but uses continuous buffers."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Toggle(
                        "Discard obvious hallucination loops",
                        isOn: $performanceSettings.hallucinationProtectionEnabled
                    )
                    Toggle(
                        "Clean chunk boundaries in the final transcript",
                        isOn: $performanceSettings.finalTranscriptCleanupEnabled
                    )
                    if performanceSettings.recognitionBackend == .gigaAM {
                        Toggle(
                            "Apply safe Russian SAGE corrections",
                            isOn: $performanceSettings.gigaAMRussianCorrectionEnabled
                        )
                    }
                } else {
                    if performanceSettings.recognitionBackend == .gigaAM,
                        let duration = performanceSettings.recognitionProfile
                            .defaultGigaAMChunkDuration
                    {
                        LabeledContent("Maximum GigaAM chunk") {
                            Text(
                                duration.formatted(
                                    .number.precision(.fractionLength(1))
                                ) + " s"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    Text("Built-in profiles keep these values together for repeatable comparison.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Customize This Profile…") {
                        performanceSettings.beginCustomizingRecognitionProfile()
                    }
                }

                Divider()

                if performanceSettings.microphoneEnvironmentProfile == .custom {
                    Picker("Energy sensitivity", selection: $performanceSettings.vadPreset) {
                        ForEach(AppSettings.VADPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(
                        "Adaptive energy threshold",
                        isOn: $performanceSettings.adaptiveVAD
                    )
                    if !performanceSettings.adaptiveVAD {
                        HStack {
                            Text("Energy threshold")
                            Slider(
                                value: $performanceSettings.manualThresholdDB,
                                in: -65...(-15),
                                step: 1
                            )
                            Text("\(Int(performanceSettings.manualThresholdDB)) dB")
                                .monospacedDigit()
                                .frame(width: 54, alignment: .trailing)
                        }
                    }
                } else {
                    Button("Customize Environment…") {
                        performanceSettings.beginCustomizingMicrophoneEnvironment()
                    }
                }
            }
            .disabled(modelBenchmark.isRunning)
        }
    }

    private var performanceScoringAndReportSection: some View {
        Section {
            SettingsDisclosureGroup(
                title: "Scoring & Report",
                accessibilityIdentifier: "performance.scoring-report-toggle",
                isExpanded: $performanceReportExpanded
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Inference passes", selection: $validationRepetitions) {
                        Text("1 pass").tag(1)
                        Text("3 passes").tag(3)
                        Text("5 passes").tag(5)
                    }
                    .pickerStyle(.segmented)
                    .disabled(modelBenchmark.isRunning)
                    .accessibilityIdentifier("performance.inference-passes")

                    TextField(
                        "Reference transcript for WER/CER (optional)",
                        text: $validationReferenceTranscript,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .accessibilityIdentifier("performance.reference-transcript")

                    TextField(
                        "Room, microphone distance, speaking style, or other notes",
                        text: $validationNotes,
                        axis: .vertical
                    )
                    .lineLimit(2...4)

                    LabeledContent("Mac") {
                        Text(ValidationSystemInfo.hardware)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("System") {
                        Text(ValidationSystemInfo.operatingSystem)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Sample microphone") {
                        Text(
                            modelBenchmark.sampleEnvironment?.microphone
                                ?? inputDeviceTitle(for: performanceSettings)
                        )
                        .foregroundStyle(.secondary)
                    }

                    Text(
                        "System and microphone metadata are added to exported reports automatically. Recorded audio is never exported."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private var performanceEngineSelectionControls: some View {
        switch performanceSettings.recognitionBackend {
        case .appleSpeech:
            Label(speechAuthorizationLabel, systemImage: speechAuthorizationSymbol)
                .foregroundStyle(speechAuthorizationColor)

        case .whisper:
            Picker("Model", selection: $performanceSettings.whisperModelID) {
                ForEach(WhisperModelID.allCases) { model in
                    Text(model.title).tag(model)
                }
            }
            .disabled(modelBenchmark.isRunning)
            .onChange(of: performanceSettings.whisperModelID) { _, model in
                if model.coreMLEncoder == nil,
                    performanceSettings.whisperComputeMode.requestsCoreML
                {
                    performanceSettings.whisperComputeMode = .metal
                }
                performanceSettings.reconcileDraftSelections()
                modelActionError = nil
            }

            Picker("Language", selection: $performanceSettings.whisperLanguageCode) {
                ForEach(whisperLanguages) { option in
                    languageLabel(option).tag(option.id)
                }
            }
            .disabled(performanceSettings.whisperModelID.isEnglishOnly || modelBenchmark.isRunning)

            Picker("Compute", selection: $performanceSettings.whisperComputeMode) {
                ForEach(availableWhisperComputeModes(for: performanceSettings.whisperModelID)) {
                    mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(modelBenchmark.isRunning)

            performanceSelectedModelAvailability

        case .gigaAM:
            Picker("Model", selection: $performanceSettings.gigaAMModelID) {
                ForEach(GigaAMModelID.allCases) { model in
                    Text("\(model.title) — \(model.capabilityLabel)").tag(model)
                }
            }
            .disabled(modelBenchmark.isRunning)
            .onChange(of: performanceSettings.gigaAMModelID) { _, _ in
                performanceSettings.reconcileDraftSelections()
                modelActionError = nil
            }

            LabeledContent("Language") {
                Text("Russian").foregroundStyle(.secondary)
            }
            Picker("Compute", selection: $performanceSettings.gigaAMExecutionProvider) {
                ForEach(AppSettings.GigaAMExecutionProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            performanceSelectedModelAvailability

        case .qwen3ASR:
            Picker("Qwen3-ASR model", selection: $performanceSettings.qwen3ASRModelID) {
                ForEach(LocalONNXModelID.qwen3ASRChoices) { model in
                    Text(model.title).tag(model)
                }
            }
            .disabled(modelBenchmark.isRunning)
            .onChange(of: performanceSettings.qwen3ASRModelID) { _, _ in
                modelActionError = nil
            }
            LabeledContent("Language") {
                Text("Automatic multilingual recognition").foregroundStyle(.secondary)
            }
            Picker("Compute", selection: $performanceSettings.localONNXExecutionProvider) {
                ForEach(AppSettings.LocalONNXExecutionProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            performanceSelectedModelAvailability

        case .parakeet:
            LabeledContent("Model") {
                Text(LocalONNXModelID.parakeetTDT06BV3Int8.title)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Language") {
                Text("Automatic European-language recognition").foregroundStyle(.secondary)
            }
            Picker("Compute", selection: $performanceSettings.localONNXExecutionProvider) {
                ForEach(AppSettings.LocalONNXExecutionProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            performanceSelectedModelAvailability
        }
    }

    @ViewBuilder
    private var performanceSelectedModelAvailability: some View {
        let isInstalled: Bool = {
            switch performanceSettings.recognitionBackend {
            case .appleSpeech:
                return true
            case .whisper:
                return whisperModels.isInstalled(performanceSettings.whisperModelID)
            case .gigaAM:
                return gigaAMModels.isInstalled(performanceSettings.gigaAMModelID)
            case .qwen3ASR, .parakeet:
                guard let model = performanceSettings.selectedLocalONNXModel else { return false }
                return localONNXModels.isInstalled(model)
            }
        }()

        Label(
            isInstalled ? "Selected model is installed" : "Selected model must be installed",
            systemImage: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
        )
        .foregroundStyle(isInstalled ? Color.green : Color.secondary)
    }

    @ViewBuilder
    private var advancedSection: some View {
        microphoneActivationAdvancedSection
        if settings.recognitionBackend == .appleSpeech {
            appleSpeechAdvancedSection
        } else {
            recognitionTuningSection
            engineAdvancedSection
        }
        importedWhisperFilesSection
    }

    @ViewBuilder
    private var importedWhisperFilesSection: some View {
        Section("Imported Whisper Files") {
            Picker(
                "Imported Whisper files",
                selection: $settings.whisperFileTranscriptionMode
            ) {
                ForEach(WhisperFileTranscriptionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(settings.recognitionBackend != .whisper)
            .accessibilityIdentifier("advanced.whisper-file-mode")
            Text(settings.whisperFileTranscriptionMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.whisperFileTranscriptionMode == .continuousFullAudio {
                Text(
                    "Whisper handles internal windows; VoicePanel boundary repair is not used for this file mode."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var microphoneActivationAdvancedSection: some View {
        Section("Speech Detection") {
            LabeledContent("Environment") {
                Text(settings.microphoneEnvironmentProfile.title)
                    .foregroundStyle(.secondary)
            }
            Text(settings.microphoneEnvironmentProfile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.microphoneEnvironmentProfile == .custom {
                Picker("Energy sensitivity", selection: $settings.vadPreset) {
                    ForEach(AppSettings.VADPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.vadPreset) { _, _ in updateVAD() }

                Toggle("Adaptive energy threshold", isOn: $settings.adaptiveVAD)
                    .onChange(of: settings.adaptiveVAD) { _, _ in updateVAD() }
                if !settings.adaptiveVAD {
                    HStack {
                        Text("Energy threshold")
                        Slider(value: $settings.manualThresholdDB, in: -65...(-15), step: 1)
                            .onChange(of: settings.manualThresholdDB) { _, _ in updateVAD() }
                        Text("\(Int(settings.manualThresholdDB)) dB")
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            } else {
                Button("Customize Environment…") {
                    settings.beginCustomizingMicrophoneEnvironment()
                    updateVAD()
                }
                .accessibilityIdentifier("advanced.customize-environment")
            }

            Toggle(
                settings.recognitionBackend == .appleSpeech
                    ? "Do not send detected silence to Apple Speech"
                    : "Do not send detected silence to continuous Apple Speech draft",
                isOn: $settings.suppressDetectedSilence
            )
            .disabled(!usesAppleSpeechDraft)

            if settings.recognitionBackend != .appleSpeech {
                Divider()
                LabeledContent("Recognition VAD") {
                    Text(settings.effectiveVoiceActivityDetectionMode.title)
                        .foregroundStyle(.secondary)
                }

                if settings.recognitionProfile == .custom {
                    Picker("VAD engine", selection: $settings.voiceActivityDetectionMode) {
                        ForEach(VoiceActivityDetectionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
                    .onChange(of: settings.voiceActivityDetectionMode) { _, mode in
                        updateVAD()
                        if mode != .energy { installSileroVADIfNeeded() }
                    }

                    Text(settings.voiceActivityDetectionMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.voiceActivityDetectionMode != .energy {
                        HStack {
                            Label(
                                sileroVADModels.statusText,
                                systemImage: sileroVADModels.isInstalled
                                    ? "checkmark.circle.fill" : "arrow.down.circle"
                            )
                            .foregroundStyle(
                                sileroVADModels.isInstalled ? Color.green : Color.secondary
                            )
                            Spacer()
                            if sileroVADModels.isInstalled {
                                Button("Remove") {
                                    do { try sileroVADModels.remove() } catch {
                                        modelActionError = error.localizedDescription
                                    }
                                }
                                .disabled(state.phase.isRecordingRelated)
                            } else {
                                Button("Install") { installSileroVADIfNeeded() }
                                    .disabled(sileroVADModels.state == .downloading)
                            }
                        }

                        HStack {
                            Text("Speech probability")
                            Slider(value: $settings.sileroThreshold, in: 0.2...0.8, step: 0.05)
                            Text(
                                settings.sileroThreshold.formatted(
                                    .number.precision(.fractionLength(2))
                                )
                            )
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                        }
                        Text("Higher values reject more noise but may miss quiet speech.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        durationControl(
                            title: "Minimum neural speech",
                            value: $settings.sileroMinimumSpeechDuration,
                            range: 0.05...0.5,
                            step: 0.05,
                            suffix: "s"
                        )
                    }
                } else {
                    Text("Controlled by the \(settings.recognitionProfile.title) profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appleSpeechAdvancedSection: some View {
        Section("Apple Speech") {
            Toggle("Require on-device recognition", isOn: $settings.appleSpeechOnDeviceOnly)
            Toggle("Automatic punctuation", isOn: $settings.appleSpeechAddsPunctuation)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vocabulary")
                    Text(vocabularySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Edit…") { showsVocabularyEditor = true }
            }

            Text(
                "Apple Speech supports contextual vocabulary, but Whisper decoding, chunk overlap, result-loop filtering, and local-model execution settings do not apply."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var engineAdvancedSection: some View {
        switch settings.recognitionBackend {
        case .appleSpeech:
            EmptyView()

        case .whisper:
            Section("Whisper execution") {
                Toggle("Flash Attention", isOn: $settings.whisperFlashAttention)
                    .disabled(
                        !settings.whisperComputeMode.supportsFlashAttention
                            || state.phase.isRecordingRelated
                            || modelBenchmark.isRunning
                    )
                Stepper(
                    "CPU threads: \(settings.whisperThreadCount)",
                    value: $settings.whisperThreadCount,
                    in: 1...16
                )
                Text(
                    "Compute mode is selected on General. Decoder strategy and chunking remain in the profile controls above."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

        case .gigaAM:
            Section("GigaAM engine tuning") {
                durationControl(
                    title: "Preferred final chunk",
                    value: $settings.gigaAMPreferredChunkDuration,
                    range: 3...20,
                    step: 0.5,
                    suffix: "s"
                )
                durationControl(
                    title: "Hard chunk limit",
                    value: $settings.gigaAMMaximumChunkDuration,
                    range: 3...20,
                    step: 0.5,
                    suffix: "s"
                )
                durationControl(
                    title: "Overlap",
                    value: $settings.gigaAMOverlapDuration,
                    range: 0...2,
                    step: 0.1,
                    suffix: "s"
                )
                durationControl(
                    title: "Boundary search window",
                    value: $settings.gigaAMBoundarySearchDuration,
                    range: 0...5,
                    step: 0.25,
                    suffix: "s"
                )
                Stepper("Retry count: \(settings.gigaAMRetryCount)", value: $settings.gigaAMRetryCount, in: 0...3)
                Toggle("Split a failed chunk and retry both halves", isOn: $settings.gigaAMSplitOnFailure)
                Stepper("Threads: \(settings.gigaAMThreadCount)", value: $settings.gigaAMThreadCount, in: 1...16)
            }

        case .qwen3ASR, .parakeet:
            Section("Local ONNX engine") {
                durationControl(
                    title: "Preferred final chunk",
                    value: $settings.localONNXPreferredChunkDuration,
                    range: 3...20,
                    step: 0.5,
                    suffix: "s"
                )
                durationControl(
                    title: "Hard chunk limit",
                    value: $settings.localONNXMaximumChunkDuration,
                    range: 3...20,
                    step: 0.5,
                    suffix: "s"
                )
                durationControl(
                    title: "Overlap",
                    value: $settings.localONNXOverlapDuration,
                    range: 0...2,
                    step: 0.1,
                    suffix: "s"
                )
                durationControl(
                    title: "Boundary search window",
                    value: $settings.localONNXBoundarySearchDuration,
                    range: 0...5,
                    step: 0.25,
                    suffix: "s"
                )
                Stepper(
                    "Retry count: \(settings.localONNXRetryCount)",
                    value: $settings.localONNXRetryCount,
                    in: 0...3
                )
                Toggle(
                    "Split a failed chunk and retry both halves",
                    isOn: $settings.localONNXSplitOnFailure
                )
                Stepper(
                    "Threads: \(settings.localONNXThreadCount)",
                    value: $settings.localONNXThreadCount,
                    in: 1...16
                )
            }
        }
    }

    private func modelTitle(for configuration: AppSettings) -> String {
        switch configuration.recognitionBackend {
        case .appleSpeech: return "Built into macOS"
        case .whisper: return configuration.whisperModelID.title
        case .gigaAM: return configuration.gigaAMModelID.title
        case .qwen3ASR, .parakeet:
            return configuration.selectedLocalONNXModel?.title ?? "Not selected"
        }
    }

    private func modelSizeTitle(for configuration: AppSettings) -> String {
        switch configuration.recognitionBackend {
        case .appleSpeech:
            return "Managed by macOS"
        case .whisper:
            return configuration.whisperModelID.sizeLabel
        case .gigaAM:
            return configuration.gigaAMModelID.sizeLabel
        case .qwen3ASR, .parakeet:
            return configuration.selectedLocalONNXModel?.sizeLabel ?? "Unknown"
        }
    }

    private func computeTitle(for configuration: AppSettings) -> String {
        switch configuration.recognitionBackend {
        case .appleSpeech:
            return configuration.appleSpeechOnDeviceOnly ? "On-device" : "System"
        case .whisper:
            return configuration.whisperComputeMode.title
        case .gigaAM:
            return configuration.gigaAMExecutionProvider.title
        case .qwen3ASR, .parakeet:
            return configuration.localONNXExecutionProvider.title
        }
    }

    private func inputDeviceTitle(for configuration: AppSettings) -> String {
        if configuration.selectedInputDeviceID == 0 {
            return "System default"
        }
        return devices.first(where: {
            UInt32($0.id) == configuration.selectedInputDeviceID
        })?.name ?? "Unavailable selected microphone"
    }

    private func languageTitle(for configuration: AppSettings) -> String {
        switch configuration.recognitionBackend {
        case .appleSpeech:
            return appleSpeechLanguages.first(where: {
                $0.id == configuration.appleSpeechLanguageIdentifier
            })?.title ?? configuration.appleSpeechLanguageIdentifier
        case .whisper:
            if configuration.whisperModelID.isEnglishOnly { return "English" }
            return whisperLanguages.first(where: {
                $0.id == configuration.whisperLanguageCode
            })?.title ?? configuration.whisperLanguageCode
        case .gigaAM:
            return "Russian"
        case .qwen3ASR, .parakeet:
            return "Auto language"
        }
    }

    private var activeModelTitle: String { modelTitle(for: settings) }
    private var activeModelSizeTitle: String { modelSizeTitle(for: settings) }
    private var activeComputeTitle: String { computeTitle(for: settings) }
    private var activeInputDeviceTitle: String { inputDeviceTitle(for: settings) }
    private var activeLanguageTitle: String { languageTitle(for: settings) }

    private var activeProcessingTitle: String {
        if settings.recognitionBackend == .appleSpeech {
            return "\(settings.microphoneEnvironmentProfile.title) · \(activeComputeTitle)"
        }
        return
            "\(settings.recognitionProfile.title) · \(settings.microphoneEnvironmentProfile.title) · \(activeComputeTitle)"
    }

    private var currentValidationTarget: RecognitionValidationTarget {
        RecognitionValidationTarget(
            engine: performanceSettings.recognitionBackend.title,
            model: modelTitle(for: performanceSettings),
            modelSize: modelSizeTitle(for: performanceSettings),
            compute: computeTitle(for: performanceSettings),
            profile: performanceSettings.recognitionBackend == .appleSpeech
                ? "System managed"
                : (performanceTestMode == .modelBenchmark
                    ? "Model only" : performanceSettings.recognitionProfile.title),
            language: languageTitle(for: performanceSettings),
            configuration: currentValidationConfiguration
        )
    }

    private var currentValidationConfiguration: [String: String]? {
        var configuration: [String: String] = [:]
        if let snapshot = performanceSettings.encodedPerformanceConfigurationSnapshot() {
            configuration["performanceSetupSnapshot"] = snapshot
            configuration["performanceSetupScope"] = "model-and-pipeline"
        }
        configuration["performanceTestMode"] = performanceTestMode.rawValue
        configuration["performanceConfigurationSignature"] =
            currentPerformanceConfigurationSignature
        if performanceSettings.recognitionBackend == .whisper {
            let inference = performanceSettings.whisperInferenceConfiguration
            configuration["reusePreviousChunkContext"] =
                inference.boundaryStrategy == .contextualRetry
                ? "enabled" : "disabled"
            configuration["whisperBoundaryStrategy"] = inference.boundaryStrategy.rawValue
            configuration["whisperContextPromptMode"] = inference.contextPromptMode.rawValue
            configuration["whisperInferenceMetadata"] =
                inference.boundaryStrategy == .contextualRetry
                    && inference.contextPromptMode == .timestampAligned
                ? WhisperInferenceMetadataLevel.tokenTimestamps.rawValue
                : (performanceSettings.hallucinationGuardConfiguration.isEnabled
                    ? WhisperInferenceMetadataLevel.segmentTimestamps.rawValue
                    : WhisperInferenceMetadataLevel.segments.rawValue)
        }
        return configuration.isEmpty ? nil : configuration
    }

    private var currentPerformanceConfigurationSignature: String {
        performanceTestMode == .modelBenchmark
            ? modelBenchmarkTargetSignature(for: performanceSettings)
            : completePerformanceConfigurationSignature(for: performanceSettings)
    }

    private func validationConfigurationSummary(
        for run: RecognitionValidationRun
    ) -> String? {
        guard let context = run.target.configuration?["reusePreviousChunkContext"] else {
            return nil
        }
        return context == "enabled"
            ? "Whisper context is reused between chunks."
            : "Each Whisper chunk is decoded without previous-chunk context."
    }

    private var currentValidationEnvironment: RecognitionValidationEnvironment {
        RecognitionValidationEnvironment(
            hardware: ValidationSystemInfo.hardware,
            operatingSystem: ValidationSystemInfo.operatingSystem,
            microphone: inputDeviceTitle(for: performanceSettings),
            environmentProfile: performanceSettings.microphoneEnvironmentProfile.title
        )
    }

    private var performanceConfigurationMatchesGeneral: Bool {
        completePerformanceConfigurationSignature(for: performanceSettings)
            == completePerformanceConfigurationSignature(for: settings)
    }

    private var modelBenchmarkTargetMatchesGeneral: Bool {
        modelBenchmarkTargetSignature(for: performanceSettings)
            == modelBenchmarkTargetSignature(for: settings)
    }

    private func modelBenchmarkTargetSignature(for configuration: AppSettings) -> String {
        let tuning = configuration.effectiveRecognitionConfiguration.tuning
        return [
            String(describing: configuration.recognitionBackend),
            modelTitle(for: configuration),
            computeTitle(for: configuration),
            languageTitle(for: configuration),
            String(configuration.whisperThreadCount),
            String(configuration.whisperFlashAttention),
            String(tuning.whisperCustomDecodingEnabled),
            String(describing: configuration.whisperDecodingStrategy),
            String(configuration.whisperGreedyBestOf),
            String(configuration.whisperBeamSize),
            String(describing: tuning.whisperBoundaryStrategy),
            String(describing: configuration.whisperFileTranscriptionMode),
            String(tuning.usesRecognitionContext),
            String(tuning.usesRecognitionVocabulary),
            String(configuration.gigaAMThreadCount),
            String(configuration.gigaAMMaximumChunkDuration),
            String(configuration.localONNXThreadCount),
            String(configuration.localONNXMaximumChunkDuration),
        ].joined(separator: "|")
    }

    private func completePerformanceConfigurationSignature(for configuration: AppSettings) -> String {
        let effectiveConfiguration = configuration.effectiveRecognitionConfiguration
        let tuning = effectiveConfiguration.tuning
        let vadConfiguration = effectiveConfiguration.voiceActivityConfiguration
        var components: [String] = [
            String(describing: configuration.recognitionBackend),
            String(describing: configuration.recognitionProfile),
            String(describing: configuration.customRecognitionBaseProfile),
            String(describing: configuration.microphoneEnvironmentProfile),
            String(configuration.selectedInputDeviceID),
            String(describing: configuration.whisperModelID),
            String(describing: configuration.gigaAMModelID),
            String(describing: configuration.qwen3ASRModelID),
            configuration.appleSpeechLanguageIdentifier,
            configuration.whisperLanguageCode,
            String(describing: configuration.whisperComputeMode),
            String(configuration.whisperThreadCount),
            String(configuration.whisperFlashAttention),
            String(tuning.whisperCustomDecodingEnabled),
            String(describing: configuration.whisperDecodingStrategy),
            String(configuration.whisperGreedyBestOf),
            String(configuration.whisperBeamSize),
            configuration.whisperInitialPrompt,
            String(describing: tuning.whisperBoundaryStrategy),
            String(describing: configuration.whisperFileTranscriptionMode),
            configuration.recognitionContext,
            configuration.recognitionVocabulary,
        ]
        components += [
            String(tuning.usesRecognitionContext),
            String(tuning.usesRecognitionVocabulary),
            String(describing: configuration.gigaAMExecutionProvider),
            String(configuration.gigaAMThreadCount),
            String(configuration.gigaAMMaximumChunkDuration),
            String(describing: configuration.localONNXExecutionProvider),
            String(configuration.localONNXThreadCount),
            String(configuration.localONNXMaximumChunkDuration),
            String(describing: tuning.voiceActivityDetectionMode),
            String(tuning.sileroThreshold),
            String(tuning.sileroMinimumSpeechDuration),
            String(tuning.endOfSpeechSilenceDuration),
            String(tuning.preRollDuration),
            String(tuning.postRollDuration),
            String(tuning.whisperChunkDuration),
            String(configuration.makeRecognitionSegmenterConfiguration().maximumChunkDuration),
            String(tuning.pauseBalancedChunkingEnabled),
            String(tuning.whisperOverlapDuration),
            String(tuning.hallucinationProtectionEnabled),
            String(tuning.finalTranscriptCleanupEnabled),
            String(tuning.gigaAMRussianCorrectionEnabled),
        ]
        components += [
            String(vadConfiguration.thresholdMarginDB),
            String(vadConfiguration.hysteresisDB),
            String(vadConfiguration.adaptiveThreshold),
            vadConfiguration.manualThresholdDB.map { String($0) } ?? "adaptive",
        ]
        return components.joined(separator: "|")
    }

    private var performanceConfigurationAccessibilitySummary: String {
        let tuning = performanceSettings.effectiveRecognitionConfiguration.tuning
        return [
            "engine=\(performanceSettings.recognitionBackend.rawValue)",
            "profile=\(performanceSettings.recognitionProfile.rawValue)",
            "base-profile=\(performanceSettings.recognitionProfileBase.rawValue)",
            "boundary=\(tuning.whisperBoundaryStrategy.rawValue)",
            "vad=\(tuning.voiceActivityDetectionMode.rawValue)",
        ].joined(separator: "; ")
    }

    private func beginPerformanceSampleRecording() {
        modelBenchmark.recordNewSample(
            settings: performanceSettings,
            environment: currentValidationEnvironment
        )
        selectedPerformanceRunID = nil
        restoredPerformanceRunID = nil
        validationExportMessage = nil
    }

    private func presentPerformanceAudioImporter() {
        let panel = NSOpenPanel()
        panel.title = "Import Benchmark Audio"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        WindowFocusCoordinator.shared.present(panel) { [weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            modelBenchmark.importSample(at: url)
            selectedPerformanceRunID = nil
            restoredPerformanceRunID = nil
            validationExportMessage = nil
        }

        if uiTestingEnabled,
            ProcessInfo.processInfo.environment[
                "VOICEPANEL_UI_TEST_AUTO_DISMISS_FILE_PANEL"
            ] == "1"
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak panel] in
                guard let panel, panel.isVisible else { return }
                panel.cancel(nil)
            }
        }
    }

    private func presentPerformanceAudioExporter() {
        guard modelBenchmark.hasRecordedSample else { return }
        let panel = NSSavePanel()
        panel.title = "Save Benchmark Audio"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "wav") ?? .audio]
        let sourceName = modelBenchmark.sampleDisplayName ?? "VoicePanel sample"
        panel.nameFieldStringValue =
            (sourceName as NSString).deletingPathExtension + ".wav"
        WindowFocusCoordinator.shared.present(panel) { [weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            do {
                try modelBenchmark.exportRecordedSample(to: url)
                validationExportFailed = false
                validationExportMessage = "Saved \(url.lastPathComponent)"
            } catch {
                validationExportFailed = true
                validationExportMessage = "Could not save audio: \(error.localizedDescription)"
            }
        }
    }

    private func runPerformanceTest() {
        guard modelBenchmark.hasRecordedSample else { return }
        selectedPerformanceRunID = nil
        restoredPerformanceRunID = nil
        modelBenchmark.runCurrentSample(
            settings: performanceSettings,
            target: currentValidationTarget,
            repetitions: validationRepetitions,
            mode: performanceTestMode,
            sileroVADModels: sileroVADModels,
            whisperRuntime: whisperRuntime,
            gigaAMRuntime: gigaAMRuntime,
            localONNXRuntime: localONNXRuntime,
            russianCorrectionRuntime: russianCorrectionRuntime
        )
    }

    private func runWhisperComparison() {
        guard modelBenchmark.hasRecordedSample else { return }
        selectedPerformanceRunID = nil
        restoredPerformanceRunID = nil
        modelBenchmark.runWhisperComparison(
            settings: performanceSettings,
            target: currentValidationTarget,
            edgePadding: whisperComparisonEdgePadding,
            maximumChunkDurationOffset: whisperComparisonMaximumChunkOffset,
            sileroVADModels: sileroVADModels,
            whisperRuntime: whisperRuntime
        )
    }

    private func performanceTestMode(for run: RecognitionValidationRun) -> PerformanceTestMode {
        if let rawValue = run.target.configuration?["performanceTestMode"],
            let storedMode = PerformanceTestMode(rawValue: rawValue)
        {
            return storedMode
        }
        return run.pipelineSummary == nil ? .modelBenchmark : .pipelineValidation
    }

    private func selectPerformanceRun(_ run: RecognitionValidationRun) {
        let selectedMode = performanceTestMode(for: run)

        restoredPerformanceRunID = nil
        isRestoringPerformanceRunConfiguration = true
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedPerformanceRunID = run.id
            performanceTestMode = selectedMode
        }
        validationRepetitions = max(1, min(5, run.repetitionCount))
        Task { @MainActor in
            await Task.yield()
            isRestoringPerformanceRunConfiguration = false
        }

        guard let snapshot = run.target.configuration?["performanceSetupSnapshot"] else {
            showPerformanceConfigurationMessage(
                "This older run can be viewed, but it does not contain a reusable setup."
            )
            return
        }
        guard performanceSettings.applyPerformanceConfigurationSnapshot(snapshot) else {
            showPerformanceConfigurationMessage("The selected run setup could not be restored.")
            return
        }
        restoredPerformanceRunID = run.id
        installPerformanceSileroVADIfNeeded()
    }

    private func savePerformanceSetup() {
        settings.replacePerformanceConfiguration(from: performanceSettings)
        updateVAD()
        installEffectiveSileroVADIfNeeded()
        validateSelectedLanguage()
        showPerformanceConfigurationMessage("Saved as the active setup in General.")
    }

    private func showPerformanceConfigurationMessage(_ message: String) {
        performanceConfigurationMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if performanceConfigurationMessage == message {
                performanceConfigurationMessage = nil
            }
        }
    }

    private func installPerformanceSileroVADIfNeeded() {
        guard performanceSettings.recognitionBackend != .appleSpeech,
            performanceSettings.effectiveVoiceActivityDetectionMode != .energy
        else { return }
        installSileroVADIfNeeded()
    }

    @ViewBuilder
    private var sileroStatusLabel: some View {
        switch sileroVADModels.state {
        case .notInstalled:
            Text("Silero VAD · required download")
                .foregroundStyle(.secondary)
        case .downloading:
            Text("Silero VAD · downloading")
                .foregroundStyle(.secondary)
        case .verifying:
            Text("Silero VAD · verifying")
                .foregroundStyle(.secondary)
        case .installed:
            Text("Silero VAD · ready")
                .foregroundStyle(.green)
        case .failed:
            Text("Silero VAD · unavailable")
                .foregroundStyle(.red)
        }
    }

    private func inferenceSummary(for run: RecognitionValidationRun) -> String {
        let passDescription =
            run.repetitionCount == 1
            ? "1 pass" : "\(run.repetitionCount) passes"
        if run.repetitionCount == 1 {
            return String(
                format: "%.2f s for %.1f s · RTF %.2f · %@",
                run.processingDuration,
                run.sampleDuration,
                run.realTimeFactor,
                passDescription
            )
        }
        return String(
            format: "median %.2f s · %.2f–%.2f s · RTF %.2f · %@",
            run.processingDuration,
            run.minimumProcessingDuration,
            run.maximumProcessingDuration,
            run.realTimeFactor,
            passDescription
        )
    }

    private func accuracy(for run: RecognitionValidationRun) -> RecognitionTranscriptAccuracy? {
        RecognitionTranscriptScorer.score(
            reference: validationReferenceTranscript,
            hypothesis: run.transcript
        )
    }

    private func accuracySummary(_ accuracy: RecognitionTranscriptAccuracy) -> String {
        String(
            format: "WER %.1f%% · CER %.1f%% · %d word edits",
            accuracy.wordErrorRate * 100,
            accuracy.characterErrorRate * 100,
            accuracy.wordEdits
        )
    }

    private func exportValidationReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "VoicePanel-validation-\(ValidationSystemInfo.fileTimestamp).json"

        WindowFocusCoordinator.shared.present(panel) { [weak panel] response in
            guard response == .OK, let url = panel?.url else { return }

            do {
                let report = modelBenchmark.makeReport(
                    fallbackEnvironment: currentValidationEnvironment,
                    referenceTranscript: validationReferenceTranscript,
                    notes: validationNotes
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(report).write(to: url, options: .atomic)
                validationExportFailed = false
                validationExportMessage = "Saved \(url.lastPathComponent)"
            } catch {
                validationExportFailed = true
                validationExportMessage = "Could not export report: \(error.localizedDescription)"
            }
        }
    }

    private var generalPipelineSummary: String {
        if settings.recognitionBackend == .appleSpeech {
            return
                "Apple Speech receives a continuous microphone stream and produces system-managed partial and final text. Local-model chunking, overlap, decoder presets, and hallucination-loop filtering are not used."
        }
        let tuning = settings.effectiveRecognitionConfiguration.tuning
        let pause = tuning.endOfSpeechSilenceDuration.formatted(
            .number.precision(.fractionLength(2))
        )
        let preRollMS = Int((tuning.preRollDuration * 1_000).rounded())
        let postRollMS = Int((tuning.postRollDuration * 1_000).rounded())
        let protection =
            tuning.hallucinationProtectionEnabled
            ? "Obvious repetition loops are discarded."
            : "Result protection is disabled."
        let cleanup =
            tuning.finalTranscriptCleanupEnabled
            ? "Final chunk boundaries are cleaned before the transcript is shown."
            : "Final chunk-boundary cleanup is disabled."
        let russianCorrection =
            settings.recognitionBackend == .gigaAM && tuning.gigaAMRussianCorrectionEnabled
            ? "The optional local SAGE model proposes Russian edits; VoicePanel accepts only punctuation, case, and dictionary-validated spelling changes."
            : ""
        return
            "VoicePanel uses \(tuning.voiceActivityDetectionMode.title) speech detection, ends a phrase after \(pause) seconds of pause, and keeps \(preRollMS) ms before and \(postRollMS) ms after detected speech. \(protection) \(cleanup) \(russianCorrection)"
    }

    @ViewBuilder
    private var generalLiveDraftControls: some View {
        Toggle(
            "Enable Live Draft for the \(settings.recognitionProfile.title) profile",
            isOn: liveDraftEnabledBinding
        )
        .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

        Text(
            "This preference follows the recognition profile, not an individual model. It remains consistent when you switch between local engines or model sizes."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if settings.liveDraftEnabledForCurrentProfile {
            switch settings.recognitionBackend {
            case .appleSpeech:
                EmptyView()
            case .whisper:
                whisperDraftControls
            case .gigaAM:
                gigaAMDraftControls
            case .qwen3ASR, .parakeet:
                localONNXDraftControls
            }
        } else {
            Label(
                "Live Draft is disabled for this profile. Final recognition still uses the selected local model.",
                systemImage: "text.bubble"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var whisperDraftControls: some View {
        Picker("Draft source", selection: whisperDraftSourceBinding) {
            ForEach(AppSettings.WhisperDraftSource.allCases.filter { $0 != .none }) { source in
                Text(source.title)
                    .tag(source)
                    .disabled(
                        source == .localWhisper
                            && settings.availableWhisperDraftModels.isEmpty
                    )
            }
        }
        .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
        .onChange(of: settings.whisperDraftSource) { _, _ in
            settings.reconcileDraftSelections()
            modelActionError = nil
        }
        Text(selectedWhisperDraftSource.detail)
            .font(.caption)
            .foregroundStyle(.secondary)

        switch selectedWhisperDraftSource {
        case .none:
            EmptyView()

        case .appleSpeech:
            Picker("Apple draft language", selection: $settings.appleSpeechLanguageIdentifier) {
                ForEach(appleSpeechLanguages) { option in
                    languageLabel(option).tag(option.id)
                }
            }
            Text(
                "Apple Speech is used only for immediate visual feedback. The selected Whisper model remains the final source of text."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        case .localWhisper:
            let choices = settings.availableWhisperDraftModels
            if choices.isEmpty {
                Label(
                    "No faster compatible Whisper model is available for this final model and language.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Picker("Draft model", selection: $settings.whisperDraftModelID) {
                    ForEach(choices) { model in
                        Text(model.title).tag(model)
                    }
                }
                .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

                let draftModel = settings.whisperDraftModelID
                Text(draftModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                whisperModelControls(
                    model: draftModel,
                    runtime: whisperDraftRuntime,
                    roleLabel: "Draft model"
                )
                durationControl(
                    title: "Draft chunk",
                    value: $settings.whisperDraftChunkDuration,
                    range: 2...10,
                    step: 0.5,
                    suffix: "s"
                )
                Text(
                    "The draft model must be faster than the selected final model. In this version both models share chunk boundaries so draft and final segments match exactly."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var gigaAMDraftControls: some View {
        Picker("Draft source", selection: gigaAMDraftSourceBinding) {
            ForEach(AppSettings.GigaAMDraftSource.allCases.filter { $0 != .none }) { source in
                Text(source.title)
                    .tag(source)
                    .disabled(
                        source == .localGigaAM
                            && settings.availableGigaAMDraftModels.isEmpty
                    )
            }
        }
        .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
        .onChange(of: settings.gigaAMDraftSource) { _, _ in
            settings.reconcileDraftSelections()
            modelActionError = nil
        }
        Text(selectedGigaAMDraftSource.detail)
            .font(.caption)
            .foregroundStyle(.secondary)

        switch selectedGigaAMDraftSource {
        case .none:
            EmptyView()

        case .appleSpeech:
            LabeledContent("Apple draft language") {
                Text("Russian")
                    .foregroundStyle(.secondary)
            }
            Text(
                "Apple Speech provides immediate Russian draft text. The selected GigaAM model remains the final source of text."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        case .localGigaAM:
            let choices = settings.availableGigaAMDraftModels
            if choices.isEmpty {
                Label(
                    "No faster plain-text GigaAM model is available for the selected final model.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Picker("Draft model", selection: $settings.gigaAMDraftModelID) {
                    ForEach(choices) { model in
                        Text("\(model.title) — \(model.capabilityLabel)").tag(model)
                    }
                }
                .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

                let draftModel = settings.gigaAMDraftModelID
                Text(draftModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                gigaAMModelControls(
                    model: draftModel,
                    runtime: gigaAMDraftRuntime,
                    roleLabel: "Draft model"
                )
                durationControl(
                    title: "Draft chunk",
                    value: $settings.gigaAMDraftChunkDuration,
                    range: 2...12,
                    step: 0.5,
                    suffix: "s"
                )
                Text(
                    "Only plain-text GigaAM v3 models are offered as local drafts. GigaAM remains Russian-only and is never used as a Whisper draft."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var localONNXDraftControls: some View {
        LabeledContent("Draft source") {
            Text("Apple Speech")
                .foregroundStyle(.secondary)
        }
        Text(AppSettings.LocalASRDraftSource.appleSpeech.detail)
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("Apple draft language", selection: $settings.appleSpeechLanguageIdentifier) {
            ForEach(appleSpeechLanguages) { option in
                languageLabel(option).tag(option.id)
            }
        }
        Text(
            "Apple Speech is used only for immediate feedback. The selected Qwen or Parakeet model remains authoritative for final text."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var recordingSection: some View {
        Section("Recording controls") {
            Picker("Global hot key", selection: $settings.hotKeyPreset) {
                ForEach(AppSettings.HotKeyPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .onChange(of: settings.hotKeyPreset) { _, _ in onHotKeyChanged() }

            Toggle(
                "Keep recording briefly after hot-key release",
                isOn: $settings.hotKeyReleaseTailEnabled
            )
            .accessibilityIdentifier("workflow.release-tail-toggle")
            if settings.hotKeyReleaseTailEnabled {
                HStack {
                    Text("Release tail")
                    Slider(
                        value: $settings.hotKeyReleaseTailDuration,
                        in: 0.2...HotKeyReleaseTailPolicy.maximumDuration,
                        step: 0.1
                    )
                    Text("\(Int((settings.hotKeyReleaseTailDuration * 1_000).rounded())) ms")
                        .monospacedDigit()
                        .frame(width: 68, alignment: .trailing)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workflow.release-tail-controls")
                Text(
                    "VoicePanel continues capturing after the key is released, including while the recognizer or VAD is still preparing, so the end of a word is not cut off. Pressing the hot key again during this interval cancels the scheduled stop."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Toggle(
                "Include audio captured while preparing",
                isOn: $settings.includeAudioCapturedWhilePreparing
            )
            .accessibilityIdentifier("workflow.preparation-audio-toggle")
            Text(
                "Microphone capture starts immediately. The first second is always included; when model or voice-detection preparation takes longer, this option decides whether the earlier buffered audio is sent to recognition."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                "The global hot key works as push-to-talk. Recording started from the menu continues until Stop Recording is selected."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var compactPanelSection: some View {
        Section("Compact transcription panel") {
            Picker("Panel size", selection: $settings.panelSizePreset) {
                ForEach(AppSettings.PanelSizePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Picker("Panel position", selection: $settings.panelPositionPreset) {
                ForEach(AppSettings.PanelPositionPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Toggle("Keep panel above other windows", isOn: $settings.panelAlwaysOnTop)
            Toggle("Open full transcript when recording starts", isOn: $settings.showFullTranscriptAutomatically)
            Text(
                "By default, other windows can cover the panel. Keep it above other windows only when you need persistent visibility."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Appearance") {
            Toggle("Transparent panel background", isOn: $settings.panelBackgroundIsTransparent)
                .accessibilityIdentifier("appearance.transparent-panel")
            Toggle("Blur content behind panel", isOn: $settings.panelBackgroundBlurEnabled)
                .accessibilityIdentifier("appearance.panel-blur")
                .disabled(
                    !settings.panelBackgroundIsTransparent
                        || !VisualEffectBackground.isSupported
                )
            Text(
                settings.panelBackgroundIsTransparent
                    ? "Transparency keeps the panel lightweight. Blur uses the macOS visual effect when it is available."
                    : "The panel uses a solid system background. Background blur is unavailable in this mode."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Picker("Window theme", selection: $settings.windowAppearanceMode) {
                ForEach(AppSettings.AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance.window-theme")

            Picker("Transcription panel theme", selection: $settings.panelAppearanceMode) {
                ForEach(AppSettings.AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance.panel-theme")

            Text(
                "Window theme applies to Settings, History, and the full transcript. The compact transcription panel can follow a different theme. System follows the current macOS appearance."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Live recognition feedback") {
            LabeledContent("Live draft") {
                Text(configuredLiveDraftTitle)
                    .foregroundStyle(.secondary)
            }
            Text(configuredLiveDraftDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.usesAppleSpeechForLiveDraft {
                LabeledContent("Pending feedback") {
                    Text(AppSettings.PendingFeedbackStyle.pulse.title)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Pending feedback", selection: $settings.pendingFeedbackStyle) {
                    ForEach(AppSettings.PendingFeedbackStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }

            LabeledContent("Preview") {
                PendingFeedbackPreview(style: settings.effectivePendingFeedbackStyle)
            }

            Text(
                settings.usesAppleSpeechForLiveDraft
                    ? "Apple Speech updates quickly, so Pulse is used automatically to avoid flickering placeholder words."
                    : settings.pendingFeedbackStyle.detail
                        + " Feedback appears only after 300 ms and remains visible for at least 600 ms."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var completionSection: some View {
        Section("After recording") {
            Picker("Hot-key recording", selection: $settings.hotKeyCompletionBehavior) {
                ForEach(AppSettings.HotKeyCompletionBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            Picker("Menu recording", selection: $settings.menuCompletionBehavior) {
                ForEach(AppSettings.MenuCompletionBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            Text(
                "Hot-key results are copied automatically after all queued chunks finish. Menu recordings can remain in the compact result or open directly in the editor."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        Section("Transcript history") {
            if settings.debugAudioRecordingEnabled {
                Label(
                    "Audio debug recording is enabled. New microphone sessions are saved as WAV files for later debugging.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("history.debug-audio-warning")
            }

            Picker(
                "Storage",
                selection: Binding(
                    get: { settings.historyStorageMode },
                    set: { mode in
                        if mode == .none, settings.historyStorageMode == .encrypted {
                            asksToDisableHistory = true
                        } else {
                            settings.historyStorageMode = mode
                        }
                    }
                )
            ) {
                ForEach(AppSettings.HistoryStorageMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("history.storage")

            if settings.historyStorageMode == .encrypted {
                Picker("Keep transcripts", selection: $settings.historyRetentionPreset) {
                    ForEach(AppSettings.HistoryRetentionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .accessibilityIdentifier("history.retention")
                Text(
                    settings.debugAudioRecordingEnabled
                        ? "Text and basic metadata are encrypted with AES-GCM. The key is stored in macOS Keychain; viewing history requires Touch ID or your Mac login password. Debug audio is stored separately and is not encrypted."
                        : "Text and basic metadata are encrypted with AES-GCM. The key is stored in macOS Keychain; viewing history requires Touch ID or your Mac login password. Audio is never saved."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Stored data") {
                    Label("Encrypted text", systemImage: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("history.stored-data.encrypted")
                }

                LabeledContent("History access") {
                    if history.isUnlocked {
                        Label("Unlocked", systemImage: "lock.open.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("history.access.unlocked")
                    } else {
                        Button {
                            Task { await history.unlock() }
                        } label: {
                            if history.isUnlocking {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Unlocking…")
                                }
                            } else {
                                Text("Unlock History")
                            }
                        }
                        .disabled(history.isUnlocking)
                        .accessibilityIdentifier("history.unlock")
                    }
                }

                if !history.isUnlocked, let error = history.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(
                    "Transcripts stay in memory only while the current result is open. Closing it removes the text from VoicePanel."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Stored data") {
                    Label("None", systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(.secondary)
                }
            }

            if settings.historyStorageMode == .encrypted {
                Label("Pinned transcripts are excluded from automatic cleanup.", systemImage: "pin")
                    .accessibilityIdentifier("history.encrypted-details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if presentationContext.showsDebugOptions {
            Section("Audio debugging") {
                Toggle(
                    "Save microphone recordings for debugging",
                    isOn: $settings.debugAudioRecordingEnabled
                )
                .disabled(state.phase.isRecordingRelated)
                .accessibilityIdentifier("history.debug-audio-recording")

                Text(
                    "Each recording session is stored locally as a continuous 16 kHz mono WAV file. Files include pauses, are not encrypted, and are not deleted with transcript history. Disable this after reproducing the issue."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Location") {
                    Button("Show Debug Recordings") {
                        let directory = DebugAudioRecordingStore.recordingsDirectoryURL
                        try? FileManager.default.createDirectory(
                            at: directory,
                            withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(directory)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recognitionTuningSection: some View {
        Section("Active Profile & Presets") {
            LabeledContent("Recognition profile") {
                Text(settings.recognitionProfile.title)
                    .foregroundStyle(.secondary)
            }
            Text(settings.recognitionProfile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.recognitionProfile == .custom {
                LabeledContent("Based on") {
                    Text(settings.customRecognitionBaseProfile.title)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Overrides") {
                    Text("\(settings.recognitionOverrideFields.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if sortedRecognitionOverrides.isEmpty {
                    Text("No values currently differ from the base profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedRecognitionOverrides) { field in
                        HStack {
                            Label(field.title, systemImage: "slider.horizontal.3")
                                .font(.callout)
                            Spacer()
                            Button("Reset") {
                                settings.resetRecognitionOverride(field)
                                updateVAD()
                                installEffectiveSileroVADIfNeeded()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                HStack {
                    Button("Reset to \(settings.customRecognitionBaseProfile.title)") {
                        settings.resetRecognitionOverridesToBase()
                        updateVAD()
                        installEffectiveSileroVADIfNeeded()
                    }
                    Button("Save as Preset…") {
                        showsSaveRecognitionPreset = true
                    }
                }
            } else {
                Button("Customize This Profile…") {
                    settings.beginCustomizingRecognitionProfile()
                    updateVAD()
                }
                .accessibilityIdentifier("advanced.customize-profile")
            }

            if !settings.savedRecognitionPresets.isEmpty {
                Menu("Apply Saved Preset") {
                    ForEach(settings.savedRecognitionPresets) { preset in
                        Button(preset.name) {
                            settings.applyRecognitionPreset(preset)
                            updateVAD()
                            installEffectiveSileroVADIfNeeded()
                        }
                    }
                }

                Menu("Delete Saved Preset") {
                    ForEach(settings.savedRecognitionPresets) { preset in
                        Button(preset.name, role: .destructive) {
                            settings.deleteRecognitionPreset(id: preset.id)
                        }
                    }
                }
            }
        }

        Section("Segmentation") {
            let tuning = settings.effectiveRecognitionConfiguration.tuning
            if settings.recognitionProfile == .custom {
                durationControl(
                    title: "Speech end pause",
                    value: $settings.voiceEndSilenceDuration,
                    range: 0.2...1.5,
                    step: 0.05,
                    suffix: "s"
                )
                durationControl(
                    title: "Audio before speech",
                    value: $settings.voicePreRollDuration,
                    range: 0...1,
                    step: 0.05,
                    suffix: "s"
                )
                durationControl(
                    title: "Audio after speech",
                    value: $settings.voicePostRollDuration,
                    range: 0...1,
                    step: 0.05,
                    suffix: "s"
                )
                if settings.recognitionBackend == .whisper {
                    durationControl(
                        title: "Maximum Whisper chunk",
                        value: $settings.whisperChunkDuration,
                        range: 2...30,
                        step: 0.5,
                        suffix: "s"
                    )
                    durationControl(
                        title: "Whisper chunk overlap",
                        value: $settings.whisperOverlapDuration,
                        range: 0...2,
                        step: 0.1,
                        suffix: "s"
                    )
                }
                Toggle(
                    "Pause-balanced chunking",
                    isOn: $settings.pauseBalancedChunkingEnabled
                )
            } else {
                LabeledContent("Speech end pause") {
                    Text(
                        tuning.endOfSpeechSilenceDuration.formatted(
                            .number.precision(.fractionLength(2))
                        ) + " s"
                    )
                    .foregroundStyle(.secondary)
                }
                LabeledContent("Audio margins") {
                    Text(
                        "\(tuning.preRollDuration.formatted(.number.precision(.fractionLength(2)))) / \(tuning.postRollDuration.formatted(.number.precision(.fractionLength(2)))) s"
                    )
                    .foregroundStyle(.secondary)
                }
                if settings.recognitionBackend == .whisper {
                    LabeledContent("Maximum Whisper chunk") {
                        Text(
                            tuning.whisperChunkDuration.formatted(
                                .number.precision(.fractionLength(1))
                            ) + " s"
                        )
                        .foregroundStyle(.secondary)
                    }
                    LabeledContent("Whisper overlap") {
                        Text(
                            tuning.whisperOverlapDuration.formatted(
                                .number.precision(.fractionLength(2))
                            ) + " s"
                        )
                        .foregroundStyle(.secondary)
                    }
                } else if settings.recognitionBackend == .gigaAM,
                    let duration = settings.recognitionProfile.defaultGigaAMChunkDuration
                {
                    LabeledContent("Maximum GigaAM chunk") {
                        Text(
                            duration.formatted(
                                .number.precision(.fractionLength(1))
                            ) + " s"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Pause-balanced chunking") {
                    Text(tuning.pauseBalancedChunkingEnabled ? "Enabled" : "Disabled")
                        .foregroundStyle(.secondary)
                }
                Text("Customize the active profile to override phrase boundaries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(
                "Pre-roll protects word beginnings. Post-roll protects endings without adding a full second of silence to every chunk. Pause-balanced chunking uses bounded lookahead while preserving each backend's input limit; Apple Speech continues to use continuous buffers."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if settings.recognitionBackend == .whisper {
            Section("Context & Vocabulary") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Context")
                        Text(contextSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Edit…") { showsContextEditor = true }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Vocabulary")
                        Text(vocabularySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Edit…") { showsVocabularyEditor = true }
                }

                if settings.recognitionProfile == .custom {
                    Toggle(
                        "Use context with supported engines",
                        isOn: $settings.recognitionContextEnabled
                    )
                    Toggle(
                        "Use vocabulary with supported engines",
                        isOn: $settings.recognitionVocabularyEnabled
                    )
                    Picker("Boundary repair", selection: $settings.whisperBoundaryStrategy) {
                        ForEach(WhisperBoundaryStrategy.allCases) { strategy in
                            Text(strategy.title).tag(strategy)
                        }
                    }
                    .accessibilityIdentifier("advanced.whisper-boundary-strategy")
                    Text(settings.whisperBoundaryStrategy.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let tuning = settings.effectiveRecognitionConfiguration.tuning
                    Text(
                        tuning.usesRecognitionContext || tuning.usesRecognitionVocabulary
                            ? "This profile applies configured context to Whisper. Shared vocabulary is used only by Apple Speech because Whisper has no safe vocabulary-bias API."
                            : "This profile ignores shared context and vocabulary to preserve its intended behavior."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

            }

            Section("Whisper Decoder") {
                if settings.recognitionProfile == .custom {
                    Toggle(
                        "Custom decoding strategy",
                        isOn: $settings.whisperCustomDecodingEnabled
                    )
                    .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)

                    Text(
                        settings.whisperCustomDecodingEnabled
                            ? "Overrides whisper.cpp sampling defaults. Use this only for deliberate comparisons."
                            : "Keeps whisper.cpp's stable default Greedy decoding without overriding candidate counts."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if settings.whisperCustomDecodingEnabled {
                        Picker("Decoding", selection: $settings.whisperDecodingStrategy) {
                            ForEach(WhisperDecodingStrategy.allCases) { strategy in
                                Text(strategy.title).tag(strategy)
                            }
                        }

                        if settings.whisperDecodingStrategy == .greedy {
                            Stepper(
                                "Candidates: \(settings.whisperGreedyBestOf)",
                                value: $settings.whisperGreedyBestOf,
                                in: 1...8
                            )
                        } else {
                            Stepper(
                                "Beam size: \(settings.whisperBeamSize)",
                                value: $settings.whisperBeamSize,
                                in: 1...10
                            )
                        }
                    }

                    Button("Restore Original Whisper Behavior") {
                        settings.restoreOriginalWhisperBehavior()
                        updateVAD()
                    }
                } else {
                    LabeledContent("Decoding") {
                        Text("whisper.cpp defaults")
                            .foregroundStyle(.secondary)
                    }
                    Text("Customize the profile to compare explicit decoding overrides.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section("Final Transcript Cleanup") {
            if settings.recognitionProfile == .custom {
                Toggle(
                    "Clean chunk boundaries in the final transcript",
                    isOn: $settings.finalTranscriptCleanupEnabled
                )
                .accessibilityIdentifier("advanced.final-transcript-cleanup")

                if settings.recognitionBackend == .gigaAM {
                    Toggle(
                        "Apply safe Russian SAGE corrections",
                        isOn: $settings.gigaAMRussianCorrectionEnabled
                    )
                    .accessibilityIdentifier("advanced.giga-russian-correction")
                }
            } else {
                LabeledContent("Chunk-boundary cleanup") {
                    Text(
                        settings.effectiveRecognitionConfiguration.tuning
                            .finalTranscriptCleanupEnabled
                            ? "Enabled by profile" : "Disabled by profile"
                    )
                    .foregroundStyle(.secondary)
                }
                if settings.recognitionBackend == .gigaAM {
                    LabeledContent("Safe Russian SAGE edits") {
                        Text(
                            settings.effectiveRecognitionConfiguration.tuning
                                .gigaAMRussianCorrectionEnabled
                                ? "Enabled by profile" : "Disabled by profile"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Text(
                "The universal pass removes overlap duplicates and repairs punctuation or capitalization introduced at chunk boundaries. It does not rewrite the meaning and works with every recognition engine. SAGE output is converted into explicit edits; word insertion, deletion, and unvalidated replacement are rejected."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if settings.recognitionBackend == .gigaAM,
                settings.effectiveRecognitionConfiguration.tuning.gigaAMRussianCorrectionEnabled
            {
                russianCorrectionModelControls
            }
        }

        Section("Safety & Diagnostics") {
            if settings.recognitionProfile == .custom {
                Toggle(
                    "Discard obvious hallucination loops",
                    isOn: $settings.hallucinationProtectionEnabled
                )
                .accessibilityIdentifier("advanced.hallucination-protection")
            } else {
                LabeledContent("Discard obvious hallucination loops") {
                    Text(
                        settings.effectiveRecognitionConfiguration.tuning
                            .hallucinationProtectionEnabled
                            ? "Enabled by profile" : "Disabled by profile"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Text(
                "Conservative protection rejects repeated-token loops and implausibly long text from a very short speech fragment."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let modelActionError {
            Section("Issue") {
                Text(modelActionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var sortedRecognitionOverrides: [RecognitionTuningField] {
        RecognitionTuningField.allCases.filter(settings.recognitionOverrideFields.contains)
    }

    private var contextSummary: String {
        let value = settings.recognitionContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Not configured" : value.replacingOccurrences(of: "\n", with: " ")
    }

    private var vocabularySummary: String {
        let count = settings.vocabularyTerms.count
        if count == 0 { return "Not configured" }
        return count == 1 ? "1 term" : "\(count) terms"
    }

    private var recognitionProfileSummary: String {
        let tuning = settings.effectiveRecognitionConfiguration.tuning
        let contextState =
            tuning.usesRecognitionContext || tuning.usesRecognitionVocabulary
            ? "context when configured" : "no shared prompt"
        return "\(tuning.voiceActivityDetectionMode.title) · \(contextState)"
    }

    private func installEffectiveSileroVADIfNeeded() {
        if settings.recognitionBackend != .appleSpeech,
            settings.effectiveVoiceActivityDetectionMode != .energy
        {
            installSileroVADIfNeeded()
        }
    }

    private func languageLabel(_ option: RecognitionLanguageOption) -> some View {
        HStack {
            Text(option.title)
            if let subtitle = option.subtitle {
                Spacer()
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }

    private func availableWhisperComputeModes(
        for model: WhisperModelID
    ) -> [WhisperComputeMode] {
        WhisperComputeMode.allCases.filter { mode in
            model.coreMLEncoder != nil || !mode.requestsCoreML
        }
    }

    @ViewBuilder
    private var russianCorrectionModelControls: some View {
        let model = RussianCorrectionModelID.sageFREDT5Int8
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.subheadline.weight(.medium))
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            switch russianCorrectionRuntime.state {
            case .downloading(let progress):
                modelProgress(title: "Downloading Russian correction model…", progress: progress)
            case .verifying(let progress):
                modelProgress(title: "Verifying model checksums…", progress: progress)
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading correction model…")
                        .foregroundStyle(.secondary)
                }
            case .ready:
                HStack {
                    Label("Installed and ready", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("Remove", role: .destructive) { removeRussianCorrectionModel() }
                }
            case .failed(let message):
                failureControls(message: message) { prepareRussianCorrectionModel() }
            case .notInstalled:
                HStack {
                    Label("Downloaded automatically on first use", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download Now") { prepareRussianCorrectionModel() }
                }
            case .inactive:
                if russianCorrectionModels.isInstalled(model) {
                    HStack {
                        Label("Installed · loads when needed", systemImage: "internaldrive")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Load Now") { prepareRussianCorrectionModel(installIfNeeded: false) }
                        Button("Remove", role: .destructive) { removeRussianCorrectionModel() }
                    }
                } else {
                    HStack {
                        Label("Downloaded automatically on first use", systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Download Now") { prepareRussianCorrectionModel() }
                    }
                }
            }
        }
        .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
    }

    @ViewBuilder
    private func whisperCoreMLControls(for model: WhisperModelID) -> some View {
        if let encoder = model.coreMLEncoder {
            switch whisperModels.coreMLState(for: encoder) {
            case .notInstalled:
                HStack {
                    Label(
                        "Core ML encoder not installed · \(encoder.sizeLabel)",
                        systemImage: "cpu"
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Install Encoder") {
                        installWhisperCoreMLEncoder(encoder, for: model)
                    }
                    .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
                }

            case .downloading(let progress):
                modelProgress(title: "Downloading Core ML encoder…", progress: progress)

            case .verifying:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifying and installing Core ML encoder…")
                        .foregroundStyle(.secondary)
                }

            case .installed:
                HStack {
                    Label("Core ML encoder installed", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("Remove Encoder", role: .destructive) {
                        removeWhisperCoreMLEncoder(encoder)
                    }
                    .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                    Button("Retry Encoder Download") {
                        installWhisperCoreMLEncoder(encoder, for: model)
                    }
                }
            }

            Text(
                "Core ML accelerates the Whisper encoder and may use the Apple Neural Engine. The decoder still follows the selected Metal or CPU mode."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text(
                "No verified Core ML encoder package is available for this specialized Whisper model. Metal and CPU remain available."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func installWhisperCoreMLEncoder(
        _ encoder: WhisperCoreMLEncoderID,
        for model: WhisperModelID
    ) {
        guard !modelBenchmark.isRunning else { return }
        modelActionError = nil
        Task {
            do {
                _ = try await whisperModels.installCoreMLEncoder(encoder)
                reloadWhisperRuntimes(using: encoder)
                if settings.recognitionBackend == .whisper,
                    settings.whisperModelID == model
                {
                    prepareWhisper(model, runtime: whisperRuntime)
                }
            } catch is CancellationError {
            } catch {
                modelActionError = error.localizedDescription
            }
        }
    }

    private func removeWhisperCoreMLEncoder(_ encoder: WhisperCoreMLEncoderID) {
        guard !modelBenchmark.isRunning else { return }
        modelActionError = nil
        do {
            reloadWhisperRuntimes(using: encoder)
            try whisperModels.removeCoreMLEncoder(encoder)
            if settings.whisperComputeMode.requestsCoreML,
                settings.whisperModelID.coreMLEncoder == encoder
            {
                settings.whisperComputeMode = .metal
            } else if settings.recognitionBackend == .whisper,
                settings.whisperModelID.coreMLEncoder == encoder
            {
                prepareWhisper(settings.whisperModelID, runtime: whisperRuntime)
            }
        } catch {
            modelActionError = error.localizedDescription
        }
    }

    private func reloadWhisperRuntimes(using encoder: WhisperCoreMLEncoderID) {
        if whisperRuntime.state.model?.coreMLEncoder == encoder {
            whisperRuntime.unload()
        }
        if whisperDraftRuntime.state.model?.coreMLEncoder == encoder {
            whisperDraftRuntime.unload()
        }
    }

    @ViewBuilder
    private func whisperModelControls(
        model: WhisperModelID,
        runtime: WhisperRuntimeManager,
        roleLabel: String
    ) -> some View {
        let runtimeState = runtime.state

        VStack(alignment: .leading, spacing: 6) {
            Text(roleLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if runtimeState.model == model {
                switch runtimeState {
                case .downloading(_, let progress):
                    modelProgress(title: "Downloading \(model.title)…", progress: progress)
                case .verifying:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Verifying checksum and installing…").foregroundStyle(.secondary)
                    }
                case .loading(_, let progress):
                    modelProgress(title: "Loading \(model.title) into memory…", progress: progress)
                case .ready:
                    HStack {
                        Label("Loaded and ready", systemImage: "checkmark.circle.fill")
                        Spacer()
                        Button("Remove", role: .destructive) { removeWhisper(model) }
                            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
                    }
                case .failed(_, let message):
                    failureControls(message: message) {
                        prepareWhisper(model, runtime: runtime)
                    }
                case .notInstalled, .inactive:
                    installedOrDownloadWhisperControls(model, runtime: runtime)
                }
            } else {
                installedOrDownloadWhisperControls(model, runtime: runtime)
            }
        }
        .disabled(modelBenchmark.isRunning)
    }

    @ViewBuilder
    private func installedOrDownloadWhisperControls(
        _ model: WhisperModelID,
        runtime: WhisperRuntimeManager
    ) -> some View {
        if whisperModels.isInstalled(model) {
            HStack {
                Label("Installed · waiting to load", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Load Now") {
                    prepareWhisper(model, runtime: runtime)
                }
                Button("Remove", role: .destructive) { removeWhisper(model) }
                    .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
            }
        } else {
            HStack {
                Label("Not installed", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download, Verify, and Load") {
                    prepareWhisper(model, runtime: runtime)
                }
            }
        }
    }

    @ViewBuilder
    private func gigaAMModelControls(
        model: GigaAMModelID,
        runtime: GigaAMRuntimeManager,
        roleLabel: String
    ) -> some View {
        let runtimeState = runtime.state

        VStack(alignment: .leading, spacing: 6) {
            Text(roleLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if runtimeState.model == model {
                switch runtimeState {
                case .downloading(_, let progress):
                    modelProgress(title: "Downloading \(model.title) package…", progress: progress)
                case .verifying(_, let progress):
                    modelProgress(title: "Verifying SHA-256 checksums…", progress: progress)
                case .loading(_, let progress):
                    modelProgress(title: "Loading \(model.title) into memory…", progress: progress)
                case .ready:
                    HStack {
                        Label("Loaded and ready", systemImage: "checkmark.circle.fill")
                        Spacer()
                        Button("Remove", role: .destructive) { removeGigaAM(model) }
                            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
                    }
                case .failed(_, let message):
                    failureControls(message: message) {
                        prepareGigaAM(model, runtime: runtime)
                    }
                case .notInstalled, .inactive:
                    installedOrDownloadGigaAMControls(model, runtime: runtime)
                }
            } else {
                installedOrDownloadGigaAMControls(model, runtime: runtime)
            }
        }
        .disabled(modelBenchmark.isRunning)
    }

    @ViewBuilder
    private func installedOrDownloadGigaAMControls(
        _ model: GigaAMModelID,
        runtime: GigaAMRuntimeManager
    ) -> some View {
        if gigaAMModels.isInstalled(model) {
            HStack {
                Label("Package installed · waiting to load", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Load Now") {
                    prepareGigaAM(model, runtime: runtime, installIfNeeded: false)
                }
                Button("Remove", role: .destructive) { removeGigaAM(model) }
                    .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
            }
        } else {
            HStack {
                Label("Not installed", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download, Verify, and Load") {
                    prepareGigaAM(model, runtime: runtime)
                }
            }
        }
    }

    @ViewBuilder
    private func localONNXModelControls(model: LocalONNXModelID) -> some View {
        let runtimeState = localONNXRuntime.state
        VStack(alignment: .leading, spacing: 6) {
            Text("Final model")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if runtimeState.model == model {
                switch runtimeState {
                case .downloading(_, let progress):
                    modelProgress(title: "Downloading \(model.title) package…", progress: progress)
                case .verifying(_, let progress):
                    modelProgress(title: "Verifying SHA-256 checksums…", progress: progress)
                case .loading(_, let progress):
                    modelProgress(title: "Loading \(model.title) into memory…", progress: progress)
                case .ready:
                    HStack {
                        Label("Loaded and ready", systemImage: "checkmark.circle.fill")
                        Spacer()
                        Button("Remove", role: .destructive) { removeLocalONNX(model) }
                            .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
                    }
                case .failed(_, let message):
                    failureControls(message: message) { prepareLocalONNX(model) }
                case .notInstalled, .inactive:
                    installedOrDownloadLocalONNXControls(model)
                }
            } else {
                installedOrDownloadLocalONNXControls(model)
            }
        }
        .disabled(modelBenchmark.isRunning)
    }

    @ViewBuilder
    private func installedOrDownloadLocalONNXControls(_ model: LocalONNXModelID) -> some View {
        if localONNXModels.isInstalled(model) {
            HStack {
                Label("Package installed · waiting to load", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Load Now") { prepareLocalONNX(model, installIfNeeded: false) }
                Button("Remove", role: .destructive) { removeLocalONNX(model) }
                    .disabled(state.phase.isRecordingRelated || modelBenchmark.isRunning)
            }
        } else {
            HStack {
                Label("Not installed", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download, Verify, and Load") { prepareLocalONNX(model) }
            }
        }
    }

    private func modelProgress(title: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress)
            Text("\(title) \(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func failureControls(message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
            Button("Retry Preparation", action: retry)
        }
    }

    private func durationControl(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text(String(format: "%.1f", value.wrappedValue) + " " + suffix)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func prepareWhisper(
        _ model: WhisperModelID,
        runtime: WhisperRuntimeManager,
        installIfNeeded: Bool = true
    ) {
        guard !modelBenchmark.isRunning else { return }
        modelActionError = nil
        Task {
            do {
                _ = try await runtime.prepare(
                    model,
                    runtimeConfiguration: settings.whisperRuntimeConfiguration,
                    installIfNeeded: installIfNeeded
                )
            } catch is CancellationError {
            } catch {
                modelActionError = error.localizedDescription
            }
        }
    }

    private func removeWhisper(_ model: WhisperModelID) {
        guard !modelBenchmark.isRunning else { return }
        do {
            if whisperRuntime.state.model == model { whisperRuntime.unload() }
            if whisperDraftRuntime.state.model == model { whisperDraftRuntime.unload() }
            try whisperModels.remove(model)
        } catch {
            modelActionError = error.localizedDescription
        }
    }

    private func prepareGigaAM(
        _ model: GigaAMModelID,
        runtime: GigaAMRuntimeManager,
        installIfNeeded: Bool = true
    ) {
        guard !modelBenchmark.isRunning else { return }
        modelActionError = nil
        Task {
            do {
                _ = try await runtime.prepare(
                    model,
                    installIfNeeded: installIfNeeded,
                    numberOfThreads: settings.gigaAMThreadCount,
                    provider: settings.gigaAMExecutionProvider.runtimeValue
                )
            } catch is CancellationError {
            } catch {
                modelActionError = error.localizedDescription
            }
        }
    }

    private func removeGigaAM(_ model: GigaAMModelID) {
        guard !modelBenchmark.isRunning else { return }
        do {
            if gigaAMRuntime.state.model == model { gigaAMRuntime.unload() }
            if gigaAMDraftRuntime.state.model == model { gigaAMDraftRuntime.unload() }
            try gigaAMModels.remove(model)
        } catch {
            modelActionError = error.localizedDescription
        }
    }

    private func prepareRussianCorrectionModel(installIfNeeded: Bool = true) {
        guard !modelBenchmark.isRunning else { return }
        modelActionError = nil
        Task {
            do {
                _ = try await russianCorrectionRuntime.prepare(
                    installIfNeeded: installIfNeeded,
                    numberOfThreads: max(1, min(4, settings.gigaAMThreadCount))
                )
            } catch is CancellationError {
            } catch {
                modelActionError = error.localizedDescription
            }
        }
    }

    private func removeRussianCorrectionModel() {
        guard !modelBenchmark.isRunning else { return }
        do {
            try russianCorrectionRuntime.removeModel()
        } catch {
            modelActionError = error.localizedDescription
        }
    }

    private func prepareLocalONNX(
        _ model: LocalONNXModelID,
        installIfNeeded: Bool = true
    ) {
        guard !modelBenchmark.isRunning else { return }
        modelActionError = nil
        Task {
            do {
                _ = try await localONNXRuntime.prepare(
                    model,
                    installIfNeeded: installIfNeeded,
                    numberOfThreads: settings.localONNXThreadCount,
                    provider: settings.localONNXExecutionProvider.runtimeValue
                )
            } catch is CancellationError {
            } catch {
                modelActionError = error.localizedDescription
            }
        }
    }

    private func removeLocalONNX(_ model: LocalONNXModelID) {
        guard !modelBenchmark.isRunning else { return }
        do {
            if localONNXRuntime.state.model == model { localONNXRuntime.unload() }
            try localONNXModels.remove(model)
        } catch {
            modelActionError = error.localizedDescription
        }
    }

    private var usesAppleSpeechDraft: Bool {
        switch settings.recognitionBackend {
        case .appleSpeech:
            return true
        case .whisper:
            return settings.effectiveWhisperDraftSource == .appleSpeech
        case .gigaAM:
            return settings.effectiveGigaAMDraftSource == .appleSpeech
        case .qwen3ASR, .parakeet:
            return settings.effectiveLocalONNXDraftSource == .appleSpeech
        }
    }

    private var liveDraftEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.liveDraftEnabledForCurrentProfile },
            set: { settings.liveDraftEnabledForCurrentProfile = $0 }
        )
    }

    private var selectedWhisperDraftSource: AppSettings.WhisperDraftSource {
        settings.whisperDraftSource == .none ? .appleSpeech : settings.whisperDraftSource
    }

    private var whisperDraftSourceBinding: Binding<AppSettings.WhisperDraftSource> {
        Binding(
            get: { selectedWhisperDraftSource },
            set: { settings.whisperDraftSource = $0 }
        )
    }

    private var selectedGigaAMDraftSource: AppSettings.GigaAMDraftSource {
        settings.gigaAMDraftSource == .none ? .appleSpeech : settings.gigaAMDraftSource
    }

    private var gigaAMDraftSourceBinding: Binding<AppSettings.GigaAMDraftSource> {
        Binding(
            get: { selectedGigaAMDraftSource },
            set: { settings.gigaAMDraftSource = $0 }
        )
    }

    private var configuredLiveDraftTitle: String {
        switch settings.recognitionBackend {
        case .appleSpeech:
            return "Apple Speech · always active"
        case .whisper:
            switch settings.effectiveWhisperDraftSource {
            case .none: return "Off"
            case .appleSpeech: return "Apple Speech"
            case .localWhisper: return settings.whisperDraftModelID.title
            }
        case .gigaAM:
            switch settings.effectiveGigaAMDraftSource {
            case .none: return "Off"
            case .appleSpeech: return "Apple Speech · Russian"
            case .localGigaAM: return settings.gigaAMDraftModelID.title
            }
        case .qwen3ASR, .parakeet:
            switch settings.effectiveLocalONNXDraftSource {
            case .none: return "Off"
            case .appleSpeech: return "Apple Speech"
            }
        }
    }

    private var configuredLiveDraftDescription: String {
        switch settings.recognitionBackend {
        case .appleSpeech:
            return "The selected engine already provides real partial transcript text."
        case .whisper:
            return settings.effectiveWhisperDraftSource.detail
        case .gigaAM:
            return settings.effectiveGigaAMDraftSource.detail
        case .qwen3ASR, .parakeet:
            return settings.effectiveLocalONNXDraftSource.detail
        }
    }

    private func installSileroVADIfNeeded() {
        guard !sileroVADModels.isInstalled else { return }
        modelActionError = nil
        Task {
            do { _ = try await sileroVADModels.ensureInstalled() } catch is CancellationError {
            } catch { modelActionError = error.localizedDescription }
        }
    }

    private func updateVAD() {
        coordinator.updateVADConfiguration()
    }

    private var speechAuthorizationLabel: String {
        switch speechAuthorizationStatus {
        case .authorized:
            return "Speech Recognition access is enabled"
        case .denied:
            return "Speech Recognition access is disabled"
        case .restricted:
            return "Speech Recognition access is restricted"
        case .notDetermined:
            return "Speech Recognition access will be requested on first use"
        @unknown default:
            return "Speech Recognition access status is unavailable"
        }
    }

    private var speechAuthorizationSymbol: String {
        switch speechAuthorizationStatus {
        case .authorized:
            return "checkmark.circle.fill"
        case .denied, .restricted:
            return "exclamationmark.triangle.fill"
        case .notDetermined:
            return "questionmark.circle"
        @unknown default:
            return "questionmark.circle"
        }
    }

    private var speechAuthorizationColor: Color {
        switch speechAuthorizationStatus {
        case .authorized:
            return .green
        case .denied, .restricted:
            return .orange
        case .notDetermined:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private func refreshSpeechAuthorizationStatus() {
        speechAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    }

    private func openSpeechPrivacySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func validateSelectedLanguage() {
        switch settings.recognitionBackend {
        case .appleSpeech:
            let ids = Set(appleSpeechLanguages.map(\.id))
            if !ids.isEmpty, !ids.contains(settings.appleSpeechLanguageIdentifier) {
                settings.appleSpeechLanguageIdentifier =
                    ids.contains("ru-RU")
                    ? "ru-RU"
                    : appleSpeechLanguages[0].id
            }
        case .whisper:
            if settings.whisperModelID.isEnglishOnly {
                if settings.whisperLanguageCode != "en" {
                    settings.whisperLanguageCode = "en"
                }
            } else {
                let ids = Set(whisperLanguages.map(\.id))
                if !ids.isEmpty, !ids.contains(settings.whisperLanguageCode) {
                    settings.whisperLanguageCode = "auto"
                }
            }
            settings.reconcileDraftSelections()
        case .gigaAM, .qwen3ASR, .parakeet:
            break
        }
    }
}

private struct PerformancePipelineComparisonItem {
    let run: RecognitionValidationRun
    let visualization: PerformancePipelineVisualization
    let summary: RecognitionPipelineValidationSummary
    let reusesPreviousChunkContext: Bool?
}

private struct PerformancePipelineComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss

    let left: PerformancePipelineComparisonItem
    let right: PerformancePipelineComparisonItem

    private var comparison: TranscriptComparison {
        TranscriptComparison.compare(left.run.transcript, right.run.transcript)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VAD A/B Comparison")
                        .font(.title2.weight(.semibold))
                    Text(
                        "The timelines use the same recorded sample and are shown on the same fitted time scale."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    transcriptComparisonSection

                    Divider()

                    timelineSection(
                        label: "A",
                        item: left,
                        tint: .blue,
                        accessibilityIdentifier: "performance.vad-comparison.timeline-a"
                    )

                    Divider()

                    timelineSection(
                        label: "B",
                        item: right,
                        tint: .purple,
                        accessibilityIdentifier: "performance.vad-comparison.timeline-b"
                    )
                }
                .padding(18)
            }
        }
        .frame(minWidth: 980, idealWidth: 1_180, minHeight: 720, idealHeight: 860)
        .accessibilityIdentifier("performance.vad-comparison")
    }

    private func timelineSection(
        label: String,
        item: PerformancePipelineComparisonItem,
        tint: Color,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.headline.monospaced())
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tint.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.run.target.profile)
                        .font(.headline)
                    Text(runSubtitle(item.run))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text("\(item.summary.chunks.count) chunks")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            PerformancePipelineVisualizationView(
                visualization: item.visualization,
                summary: item.summary,
                reusesPreviousChunkContext: item.reusesPreviousChunkContext,
                allowsZoom: false
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var transcriptComparisonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Transcript Diff")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(
                    "\(comparison.changedWordCount) changed · "
                        + "\(comparison.removedWordCount) removed · "
                        + "\(comparison.insertedWordCount) added"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            transcriptComparison
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("performance.vad-comparison.transcript-diff")
    }

    private var transcriptComparison: some View {
        HSplitView {
            transcriptColumn(
                title: "A · \(left.run.target.profile)",
                tokens: comparison.left,
                highlight: .red
            )
            transcriptColumn(
                title: "B · \(right.run.target.profile)",
                tokens: comparison.right,
                highlight: .green
            )
        }
        .frame(minHeight: 180, idealHeight: 220)
        .accessibilityIdentifier("performance.transcript-comparison")
    }

    private func transcriptColumn(
        title: String,
        tokens: [TranscriptComparison.Token],
        highlight: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(attributedTranscript(tokens, highlight: highlight))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.46))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 4)
    }

    private func attributedTranscript(
        _ tokens: [TranscriptComparison.Token],
        highlight: Color
    ) -> AttributedString {
        var result = AttributedString()
        for (index, token) in tokens.enumerated() {
            if index > 0 { result.append(AttributedString(" ")) }
            var word = AttributedString(token.text)
            if token.isChanged {
                word.backgroundColor = highlight.opacity(0.20)
                word.foregroundColor = highlight
            }
            result.append(word)
        }
        return result
    }

    private func runSubtitle(_ run: RecognitionValidationRun) -> String {
        return [
            run.target.engine,
            run.target.model,
            run.testedAt.formatted(date: .abbreviated, time: .shortened),
        ].joined(separator: " · ")
    }
}

private struct RecognitionPresetNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String) -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Recognition Preset")
                .font(.title2.weight(.semibold))
            Text(
                "The preset stores recognition tuning and its base profile. It does not change the selected engine, model, or Live Draft source."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 420)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
    }
}

private struct RecognitionTextEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let help: String
    let placeholder: String
    let onSave: (String) -> Void

    @State private var text: String

    init(
        title: String,
        help: String,
        placeholder: String,
        initialText: String,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.help = help
        self.placeholder = placeholder
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(help)
                .font(.callout)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .frame(minWidth: 640, minHeight: 340)

            HStack {
                Button("Clear") { text = "" }
                    .disabled(text.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
    }
}

private struct PerformancePipelineVisualizationView: View {
    let visualization: PerformancePipelineVisualization
    let summary: RecognitionPipelineValidationSummary
    let reusesPreviousChunkContext: Bool?
    var allowsZoom = true

    @State private var selectedChunkID: UUID?
    @State private var zoomScale = 1.0

    private let labelWidth: CGFloat = 58
    private let trackSpacing: CGFloat = 8
    private let timeScaleHeight: CGFloat = 18
    private let signalHeight: CGFloat = 92
    private let vadHeight: CGFloat = 24
    private let scrollbarGutter: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(assessmentTitle)
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("performance.pipeline-summary")
                    .foregroundStyle(assessmentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(assessmentColor.opacity(0.10))
                    )

                Spacer(minLength: 8)

                if allowsZoom {
                    HStack(spacing: 4) {
                        Button("Fit") {
                            withAnimation(.easeOut(duration: 0.15)) { zoomScale = 1 }
                        }
                        .disabled(zoomScale == 1)
                        .accessibilityLabel("Fit timeline")

                        Button("−") {
                            withAnimation(.easeOut(duration: 0.15)) {
                                zoomScale = max(1, zoomScale - 0.5)
                            }
                        }
                        .disabled(zoomScale <= 1)
                        .accessibilityLabel("Zoom out")

                        Button("+") {
                            withAnimation(.easeOut(duration: 0.15)) {
                                zoomScale = min(4, zoomScale + 0.5)
                            }
                        }
                        .disabled(zoomScale >= 4)
                        .accessibilityLabel("Zoom in")
                    }
                    .controlSize(.small)
                }
            }

            GeometryReader { geometry in
                let viewportWidth = max(1, geometry.size.width - labelWidth - trackSpacing)
                let timelineWidth = viewportWidth * zoomScale
                let showsHorizontalScroller = timelineWidth > viewportWidth + 1

                HStack(alignment: .top, spacing: trackSpacing) {
                    VStack(alignment: .trailing, spacing: trackSpacing) {
                        Color.clear
                            .frame(height: timeScaleHeight)
                        performancePipelineTrackLabel("Signal", height: signalHeight)
                        performancePipelineTrackLabel("VAD", height: vadHeight)
                        performancePipelineTrackLabel("Chunks", height: chunkHeight)
                    }
                    .frame(width: labelWidth)
                    .frame(height: timelineHeight, alignment: .top)

                    ScrollView(.horizontal) {
                        VStack(spacing: trackSpacing) {
                            PerformancePipelineTimeScale(duration: visualization.duration)
                                .frame(height: timeScaleHeight)
                            PerformancePipelineSignalTrack(
                                visualization: visualization,
                                selectedChunk: selectedChunk?.overlay
                            )
                            .frame(height: signalHeight)
                            PerformancePipelineStateTrack(
                                visualization: visualization,
                                selectedChunk: selectedChunk?.overlay
                            )
                            .frame(height: vadHeight)
                            PerformancePipelineChunkTrack(
                                chunks: visualization.chunkOverlays,
                                duration: visualization.duration,
                                selectedChunkID: $selectedChunkID
                            )
                            .frame(height: chunkHeight)
                        }
                        .frame(width: timelineWidth)
                    }
                    .scrollIndicators(showsHorizontalScroller ? .visible : .hidden)
                    .frame(height: timelineHeight + activeScrollbarGutter, alignment: .top)
                    .clipped()
                }
            }
            .frame(height: timelineHeight + activeScrollbarGutter)

            pipelineLegend

            if let selectedChunk {
                PerformancePipelineChunkInspector(
                    index: selectedChunk.index,
                    overlay: selectedChunk.overlay,
                    visualization: visualization,
                    reusesPreviousChunkContext: reusesPreviousChunkContext
                )
            } else if !visualization.chunkOverlays.isEmpty {
                Text("Select a chunk to inspect its timing, audio margins, and boundary reason.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("performance.pipeline-visualization")
        .onChange(of: visualization.chunkOverlays.map(\.id)) { _, chunkIDs in
            if let selectedChunkID, !chunkIDs.contains(selectedChunkID) {
                self.selectedChunkID = nil
            }
        }
    }

    private var pipelineLegend: some View {
        HStack(spacing: 14) {
            pipelineLegendItem("Speech", color: .green)
            pipelineLegendItem("Possible pause", color: .orange)
            pipelineLegendItem("Excluded silence", color: .secondary)
            pipelineLegendItem("Accepted chunk", color: .accentColor)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pipeline legend")
        .accessibilityIdentifier("performance.pipeline-legend")
    }

    private func pipelineLegendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.opacity(0.8))
                .frame(width: 10, height: 4)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timelineHeight: CGFloat {
        timeScaleHeight + signalHeight + vadHeight + chunkHeight + trackSpacing * 3
    }

    private var chunkHeight: CGFloat {
        PerformancePipelineChunkLayout.trackHeight(for: visualization.chunkOverlays)
    }

    private var activeScrollbarGutter: CGFloat {
        zoomScale > 1 ? scrollbarGutter : 0
    }

    private var selectedChunk: (index: Int, overlay: PerformancePipelineVisualization.ChunkOverlay)? {
        guard let selectedChunkID,
            let index = visualization.chunkOverlays.firstIndex(where: { $0.id == selectedChunkID })
        else {
            return nil
        }
        return (index, visualization.chunkOverlays[index])
    }

    private var finding: RecognitionPipelineVisualizationFinding {
        RecognitionPipelineVisualizationPolicy.finding(for: summary)
    }

    private var assessmentTitle: String {
        switch finding {
        case .recordingRejected:
            return "Recording was too short and was rejected"
        case .recognitionResultsRejected(let count):
            return "\(count) recognition result\(count == 1 ? " was" : "s were") rejected"
        case .segmentationBoundaries(
            let maximumDuration,
            let pauseBalanced,
            let longSilence
        ):
            var parts: [String] = []
            if maximumDuration > 0 {
                parts.append("\(maximumDuration) maximum-length")
            }
            if pauseBalanced > 0 {
                parts.append("\(pauseBalanced) pause-balanced")
            }
            if longSilence > 0 {
                parts.append("\(longSilence) long-silence compacted")
            }
            return parts.joined(separator: " · ")
        case .noObviousIssues:
            return "No obvious segmentation issues"
        }
    }

    private var assessmentColor: Color {
        switch finding {
        case .recordingRejected, .recognitionResultsRejected:
            return .red
        case .segmentationBoundaries(let maximumDuration, _, _):
            return maximumDuration > 0 ? .orange : .green
        case .noObviousIssues:
            return .green
        }
    }

    private func performancePipelineTrackLabel(_ text: String, height: CGFloat) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(height: height, alignment: .center)
    }
}

private struct PerformancePipelineTimeScale: View {
    let duration: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for time in tickTimes(for: geometry.size.width) {
                    let x = xPosition(time, duration: duration, width: size.width)
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height - 4))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(Color.secondary.opacity(0.35)), lineWidth: 1)

                    let label = context.resolve(
                        Text(timeTitle(time))
                            .font(.system(size: 9, weight: .regular).monospacedDigit())
                            .foregroundStyle(Color.secondary)
                    )
                    context.draw(
                        label,
                        at: CGPoint(x: min(max(14, x), size.width - 14), y: 6),
                        anchor: .center
                    )
                }
            }
        }
    }

    private func tickTimes(for width: CGFloat) -> [TimeInterval] {
        let safeDuration = max(duration, 0)
        guard safeDuration > 0 else { return [0] }

        let maximumTickCount = max(2, Int(width / 68))
        let rawStep = safeDuration / Double(maximumTickCount - 1)
        let magnitude = pow(10, floor(log10(max(rawStep, 0.001))))
        let normalizedStep = rawStep / magnitude
        let niceMultiplier: Double
        switch normalizedStep {
        case ...1:
            niceMultiplier = 1
        case ...2:
            niceMultiplier = 2
        case ...5:
            niceMultiplier = 5
        default:
            niceMultiplier = 10
        }
        let step = niceMultiplier * magnitude

        var values: [TimeInterval] = []
        var value: TimeInterval = 0
        while value <= safeDuration + 0.000_1 {
            values.append(value)
            value += step
        }
        if let last = values.last, safeDuration - last >= step * 0.5 {
            values.append(safeDuration)
        }
        return values
    }

    private func timeTitle(_ time: TimeInterval) -> String {
        if time < 1, time > 0 {
            return String(format: "%.1f s", time)
        }
        return String(format: "%.0f s", time)
    }
}

private struct PerformancePipelineSignalTrack: View {
    let visualization: PerformancePipelineVisualization
    let selectedChunk: PerformancePipelineVisualization.ChunkOverlay?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.58))

                Canvas { context, size in
                    let duration = max(visualization.duration, 0.001)

                    for span in visualization.speechSpans {
                        let startX = xPosition(span.startTime, duration: duration, width: size.width)
                        let endX = xPosition(span.endTime, duration: duration, width: size.width)
                        context.fill(
                            Path(
                                CGRect(
                                    x: startX,
                                    y: 0,
                                    width: max(1, endX - startX),
                                    height: size.height
                                )
                            ),
                            with: .color(spanBackgroundColor(for: span.kind))
                        )
                    }

                    if let selectedChunk {
                        let startX = xPosition(
                            selectedChunk.startTime,
                            duration: duration,
                            width: size.width
                        )
                        let endX = xPosition(
                            selectedChunk.endTime,
                            duration: duration,
                            width: size.width
                        )
                        let selectedRect = CGRect(
                            x: startX,
                            y: 1,
                            width: max(2, endX - startX),
                            height: size.height - 2
                        )
                        context.fill(
                            Path(roundedRect: selectedRect, cornerRadius: 6),
                            with: .color(Color.accentColor.opacity(0.07))
                        )
                        context.stroke(
                            Path(roundedRect: selectedRect, cornerRadius: 6),
                            with: .color(Color.accentColor.opacity(0.60)),
                            lineWidth: 1
                        )
                    }

                    var centerLine = Path()
                    centerLine.move(to: CGPoint(x: 0, y: size.height / 2))
                    centerLine.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(
                        centerLine,
                        with: .color(Color.secondary.opacity(0.18)),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                    )

                    let levels = visualization.waveformLevels
                    if !levels.isEmpty {
                        let spacing = size.width / CGFloat(levels.count)
                        let barWidth = max(1, spacing * 0.68)
                        let centerY = size.height / 2
                        for (index, level) in levels.enumerated() {
                            let x = CGFloat(index) * spacing + spacing / 2
                            let activeHeight = max(3, size.height * CGFloat(level) * 0.76)
                            let rect = CGRect(
                                x: x - barWidth / 2,
                                y: centerY - activeHeight / 2,
                                width: barWidth,
                                height: activeHeight
                            )
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                with: .color(Color.primary.opacity(0.46))
                            )
                        }
                    }

                    for marker in visualization.vadMarkers {
                        let x = xPosition(marker.time, duration: duration, width: size.width)
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        let color: Color = marker.kind == .speechStarted ? .green : .orange
                        context.stroke(
                            path,
                            with: .color(color.opacity(0.45)),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                    }

                    if !visualization.acceptedByRecordingPolicy {
                        context.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .color(Color.gray.opacity(0.20))
                        )
                        let rejected = context.resolve(
                            Text("Recording rejected by minimum-duration policy")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.secondary)
                        )
                        context.draw(
                            rejected,
                            at: CGPoint(x: size.width / 2, y: size.height / 2),
                            anchor: .center
                        )
                    }
                }

                ForEach(visualization.vadMarkers) { marker in
                    let x = xPosition(
                        marker.time,
                        duration: max(visualization.duration, 0.001),
                        width: geometry.size.width
                    )
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: 12, height: geometry.size.height)
                        .position(x: x, y: geometry.size.height / 2)
                        .help(marker.helpTitle)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }
}

private struct PerformancePipelineStateTrack: View {
    let visualization: PerformancePipelineVisualization
    let selectedChunk: PerformancePipelineVisualization.ChunkOverlay?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.46))

                Canvas { context, size in
                    let duration = max(visualization.duration, 0.001)
                    for span in visualization.speechSpans {
                        let startX = xPosition(span.startTime, duration: duration, width: size.width)
                        let endX = xPosition(span.endTime, duration: duration, width: size.width)
                        let rect = CGRect(
                            x: startX,
                            y: 2,
                            width: max(1, endX - startX - 1),
                            height: size.height - 4
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 4),
                            with: .color(activityColor(for: span.kind))
                        )
                    }

                    if let selectedChunk {
                        let startX = xPosition(
                            selectedChunk.startTime,
                            duration: duration,
                            width: size.width
                        )
                        let endX = xPosition(
                            selectedChunk.endTime,
                            duration: duration,
                            width: size.width
                        )
                        let selectedRect = CGRect(
                            x: startX,
                            y: 1,
                            width: max(2, endX - startX),
                            height: size.height - 2
                        )
                        context.stroke(
                            Path(roundedRect: selectedRect, cornerRadius: 5),
                            with: .color(Color.accentColor.opacity(0.75)),
                            lineWidth: 1
                        )
                    }
                }

                ForEach(visualization.speechSpans) { span in
                    let duration = max(visualization.duration, 0.001)
                    let startX = xPosition(span.startTime, duration: duration, width: geometry.size.width)
                    let endX = xPosition(span.endTime, duration: duration, width: geometry.size.width)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: max(1, endX - startX), height: geometry.size.height)
                        .position(x: startX + max(1, endX - startX) / 2, y: geometry.size.height / 2)
                        .help(span.helpTitle)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }
}

private struct PerformancePipelineChunkTrack: View {
    let chunks: [PerformancePipelineVisualization.ChunkOverlay]
    let duration: TimeInterval
    @Binding var selectedChunkID: UUID?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.46))

                if chunks.isEmpty {
                    Text("No audio was sent to recognition")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(placements) { placement in
                    let chunk = placement.chunk
                    let startX = xPosition(
                        chunk.startTime,
                        duration: max(duration, 0.001),
                        width: geometry.size.width
                    )
                    let endX = xPosition(
                        chunk.endTime,
                        duration: max(duration, 0.001),
                        width: geometry.size.width
                    )
                    let width = max(1, endX - startX)
                    let isSelected = selectedChunkID == chunk.id

                    Button {
                        selectedChunkID = isSelected ? nil : chunk.id
                    } label: {
                        ZStack(alignment: .trailing) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.accentColor.opacity(isSelected ? 0.42 : 0.22))
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(
                                    Color.accentColor.opacity(isSelected ? 0.95 : 0.62),
                                    lineWidth: isSelected ? 1.5 : 1
                                )

                            HStack(spacing: 4) {
                                Text("\(placement.offset + 1)")
                                    .fontWeight(.semibold)
                                if width >= 72 {
                                    Text(chunk.boundaryReason.timelineShortTitle)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .padding(.horizontal, min(7, max(2, width / 8)))
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Rectangle()
                                .fill(chunk.boundaryReason.timelineColor)
                                .frame(width: 2)
                                .padding(.vertical, 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("performance.pipeline.chunk.\(placement.offset + 1)")
                    .frame(width: width, height: PerformancePipelineChunkLayout.laneHeight)
                    .position(
                        x: startX + width / 2,
                        y: PerformancePipelineChunkLayout.centerY(for: placement.lane)
                    )
                    .help(
                        "Chunk \(placement.offset + 1) · \(durationTitle(chunk.endTime - chunk.startTime)) · ended by \(chunk.boundaryReason.timelineDetailTitle.lowercased())"
                    )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private var placements: [PerformancePipelineChunkPlacement] {
        PerformancePipelineChunkLayout.placements(for: chunks)
    }
}

private struct PerformancePipelineChunkPlacement: Identifiable {
    let offset: Int
    let chunk: PerformancePipelineVisualization.ChunkOverlay
    let lane: Int

    var id: UUID { chunk.id }
}

private enum PerformancePipelineChunkLayout {
    static let laneHeight: CGFloat = 28
    private static let laneSpacing: CGFloat = 4
    private static let verticalPadding: CGFloat = 4

    static func placements(
        for chunks: [PerformancePipelineVisualization.ChunkOverlay]
    ) -> [PerformancePipelineChunkPlacement] {
        var laneEndTimes: [TimeInterval] = []
        var result: [PerformancePipelineChunkPlacement] = []

        for item in chunks.enumerated().sorted(by: chunkOrder) {
            let lane: Int
            if let availableLane = laneEndTimes.firstIndex(where: {
                item.element.startTime >= $0 - 0.000_1
            }) {
                lane = availableLane
                laneEndTimes[availableLane] = item.element.endTime
            } else {
                lane = laneEndTimes.count
                laneEndTimes.append(item.element.endTime)
            }
            result.append(
                PerformancePipelineChunkPlacement(
                    offset: item.offset,
                    chunk: item.element,
                    lane: lane
                )
            )
        }
        return result
    }

    static func trackHeight(
        for chunks: [PerformancePipelineVisualization.ChunkOverlay]
    ) -> CGFloat {
        let laneCount = max(1, (placements(for: chunks).map(\.lane).max() ?? 0) + 1)
        return verticalPadding * 2
            + CGFloat(laneCount) * laneHeight
            + CGFloat(max(0, laneCount - 1)) * laneSpacing
    }

    static func centerY(for lane: Int) -> CGFloat {
        verticalPadding + laneHeight / 2 + CGFloat(lane) * (laneHeight + laneSpacing)
    }

    private static func chunkOrder(
        _ lhs: EnumeratedSequence<[PerformancePipelineVisualization.ChunkOverlay]>.Element,
        _ rhs: EnumeratedSequence<[PerformancePipelineVisualization.ChunkOverlay]>.Element
    ) -> Bool {
        if lhs.element.startTime == rhs.element.startTime {
            return lhs.offset < rhs.offset
        }
        return lhs.element.startTime < rhs.element.startTime
    }
}

private struct PerformancePipelineChunkInspector: View {
    let index: Int
    let overlay: PerformancePipelineVisualization.ChunkOverlay
    let visualization: PerformancePipelineVisualization
    let reusesPreviousChunkContext: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(
                    "Chunk \(index + 1) · \(timeTitle(overlay.startTime))–\(timeTitle(overlay.endTime))"
                )
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("performance.pipeline.chunk-heading")

                Text(overlay.boundaryReason.timelineDetailTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(overlay.boundaryReason.timelineColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(overlay.boundaryReason.timelineColor.opacity(0.10))
                    )
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 5) {
                GridRow {
                    inspectorLabel("Duration")
                    inspectorValue(durationTitle(overlay.endTime - overlay.startTime))
                    inspectorLabel("Speech")
                    inspectorValue(durationTitle(speechDuration))
                }
                GridRow {
                    inspectorLabel("Started")
                    inspectorValue(startDescription)
                    inspectorLabel("Ended")
                    inspectorValue(endDescription)
                }
                GridRow {
                    inspectorLabel("Audio margins")
                    inspectorValue(
                        "\(durationTitle(actualPreRoll)) before · \(durationTitle(actualPostRoll)) after"
                    )
                    if let contextDescription {
                        inspectorLabel("Whisper context")
                        inspectorValue(contextDescription)
                    } else {
                        Color.clear
                        Color.clear
                    }
                }
                GridRow {
                    inspectorLabel("Trailing overlap")
                    inspectorValue(durationTitle(overlay.trailingOverlapDuration))
                    Color.clear
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Recognized text")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)

                chunkRecognitionResult
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("performance.pipeline.chunk-inspector")
    }

    private var chunkRecognitionResult: some View {
        Group {
            switch overlay.recognitionState {
            case .pending:
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for this chunk to be transcribed…")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

            case .accepted(let text):
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

            case .empty:
                Text("The model returned no text for this chunk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .rejected(let text, let reason):
                VStack(alignment: .leading, spacing: 5) {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Rejected by result protection: \(reason).")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("performance.pipeline.chunk-text")
        .accessibilityLabel(chunkRecognitionAccessibilityText)
        .accessibilityValue(chunkRecognitionAccessibilityText)
    }

    private var chunkRecognitionAccessibilityText: String {
        switch overlay.recognitionState {
        case .pending:
            return "Waiting for this chunk to be transcribed"
        case .accepted(let text):
            return text
        case .empty:
            return "The model returned no text for this chunk"
        case .rejected(let text, let reason):
            return "\(text). Rejected by result protection: \(reason)"
        }
    }

    private var speechDuration: TimeInterval {
        guard let start = overlay.speechStartTime, let end = overlay.speechEndTime else {
            return max(0, overlay.endTime - overlay.startTime)
        }
        return max(0, end - start)
    }

    private var actualPreRoll: TimeInterval {
        guard let speechStartTime = overlay.speechStartTime else { return 0 }
        return max(0, speechStartTime - overlay.startTime)
    }

    private var actualPostRoll: TimeInterval {
        guard let speechEndTime = overlay.speechEndTime else { return 0 }
        return max(0, overlay.endTime - speechEndTime)
    }

    private var startDescription: String {
        guard let speechStartTime = overlay.speechStartTime else {
            return "Audio window start"
        }
        return "Speech at \(timeTitle(speechStartTime))"
    }

    private var endDescription: String {
        switch overlay.boundaryReason {
        case .silence:
            return "\(durationTitle(overlay.boundarySilenceDuration ?? visualization.phraseBoundaryDuration)) pause"
        case .longSilence:
            return "Long silence compacted"
        case .maximumDuration:
            return "Maximum \(durationTitle(visualization.maximumChunkDuration))"
        case .balancedPause:
            return "Pause-balanced cut"
        case .stopped:
            return "Recording stopped"
        case .inputChanged:
            return "Input changed"
        }
    }

    private var contextDescription: String? {
        guard let reusesPreviousChunkContext else { return nil }
        if index == 0 {
            return "Reset for first chunk"
        }
        return reusesPreviousChunkContext ? "Previous chunk reused" : "Not reused"
    }

    private var explanation: String {
        switch overlay.boundaryReason {
        case .silence:
            let detectedSilence =
                overlay.boundarySilenceDuration ?? visualization.phraseBoundaryDuration
            return
                "Expected boundary. The detected pause lasted \(durationTitle(detectedSilence)); the configured phrase boundary is \(durationTitle(visualization.phraseBoundaryDuration))."
        case .longSilence:
            return
                "A long Silero-confirmed gap was compacted to the configured audio margins before recognition."
        case .maximumDuration:
            return
                "Review this boundary. The chunk reached the configured maximum while the phrase could still be active. Increase maximum chunk duration when words are split here."
        case .balancedPause:
            return
                "The segmenter found a real pause, cut at its midpoint, and placed no audio samples in both chunks."
        case .stopped:
            return
                "The recording ended here, so the remaining buffered audio was flushed as the final chunk."
        case .inputChanged:
            return
                "The audio input changed here. The current buffer was closed before capture continued on the new device."
        }
    }

    private func inspectorLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func inspectorValue(_ value: String) -> some View {
        Text(value)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private func xPosition(_ time: TimeInterval, duration: TimeInterval, width: CGFloat) -> CGFloat {
    CGFloat(min(max(time / max(duration, 0.001), 0), 1)) * width
}

private func spanBackgroundColor(
    for kind: PerformancePipelineVisualization.VoiceActivitySpan.Kind
) -> Color {
    switch kind {
    case .speech: return Color.green.opacity(0.07)
    case .possiblePause: return Color.orange.opacity(0.07)
    case .silence: return Color.gray.opacity(0.07)
    }
}

private func activityColor(
    for kind: PerformancePipelineVisualization.VoiceActivitySpan.Kind
) -> Color {
    switch kind {
    case .speech: return Color.green.opacity(0.78)
    case .possiblePause: return Color.orange.opacity(0.72)
    case .silence: return Color.gray.opacity(0.48)
    }
}

private func timeTitle(_ time: TimeInterval) -> String {
    if time < 10 {
        return String(format: "%.2f s", time)
    }
    return String(format: "%.1f s", time)
}

private func durationTitle(_ duration: TimeInterval) -> String {
    if duration < 1 {
        return String(format: "%.0f ms", duration * 1_000)
    }
    return String(format: "%.2f s", duration)
}

extension PerformancePipelineVisualization.VADMarker {
    fileprivate var helpTitle: String {
        switch kind {
        case .speechStarted:
            return "VAD → speech · \(timeTitle(time))"
        case .speechEnded:
            return "VAD → silence · \(timeTitle(time))"
        }
    }
}

extension PerformancePipelineVisualization.VoiceActivitySpan {
    fileprivate var helpTitle: String {
        let title: String
        switch kind {
        case .speech:
            title = "Speech"
        case .possiblePause:
            title = "Possible pause"
        case .silence:
            title = "Excluded silence"
        }
        return "\(title) · \(timeTitle(startTime))–\(timeTitle(endTime))"
    }
}

extension AudioChunkBoundaryReason {
    fileprivate var timelineShortTitle: String {
        switch self {
        case .silence: return "Pause"
        case .longSilence: return "Gap"
        case .maximumDuration: return "Max"
        case .balancedPause: return "Pause"
        case .stopped: return "Stop"
        case .inputChanged: return "Input"
        }
    }

    fileprivate var timelineDetailTitle: String {
        switch self {
        case .silence: return "Phrase pause"
        case .longSilence: return "Long silence"
        case .maximumDuration: return "Maximum length"
        case .balancedPause: return "Pause-balanced"
        case .stopped: return "Recording stop"
        case .inputChanged: return "Input change"
        }
    }

    fileprivate var timelineColor: Color {
        switch self {
        case .silence:
            return .accentColor
        case .longSilence:
            return .mint
        case .balancedPause:
            return .green
        case .maximumDuration:
            return .orange
        case .stopped, .inputChanged:
            return .secondary
        }
    }
}

private struct SettingsDisclosureGroup<Content: View>: View {
    let title: String
    let systemImage: String?
    let trailingText: String?
    let accessibilityIdentifier: String?
    @Binding var isExpanded: Bool
    private let content: Content

    init(
        title: String,
        systemImage: String? = nil,
        trailingText: String? = nil,
        accessibilityIdentifier: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailingText = trailingText
        self.accessibilityIdentifier = accessibilityIdentifier
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    if let systemImage {
                        Image(systemName: systemImage)
                    }
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 12)
                    if let trailingText {
                        Text(trailingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityIdentifier ?? "disclosure.\(title)")
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension VoiceActivityDetectionMode {
    fileprivate var title: String {
        switch self {
        case .energy: return "Energy"
        case .silero: return "Silero"
        case .hybrid: return "Hybrid"
        }
    }

    fileprivate var detail: String {
        switch self {
        case .energy:
            return "The existing adaptive RMS detector. Lowest overhead and the safest compatibility option."
        case .silero:
            return
                "A local neural detector distinguishes speech from music, keyboard noise, and other non-speech sound."
        case .hybrid:
            return
                "Balanced mode: Silero starts speech, while the energy detector helps preserve quiet word endings."
        }
    }
}

private enum ValidationSystemInfo {
    static let hardware: String = {
        let model = sysctlString("hw.model") ?? "Mac"
        return "\(model) · \(architecture) · \(ProcessInfo.processInfo.processorCount) logical cores"
    }()

    static let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString

    static var fileTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown architecture"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            sysctlbyname(name, pointer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }
}

extension AudioChunkBoundaryReason {
    fileprivate var title: String {
        switch self {
        case .silence: return "silence"
        case .longSilence: return "long silence"
        case .maximumDuration: return "maximum duration"
        case .balancedPause: return "pause-balanced"
        case .stopped: return "recording stopped"
        case .inputChanged: return "input changed"
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general
    case performance
    case workflow
    case history
    case advanced

    static var uiTestingInitialPage: SettingsPage {
        guard ProcessInfo.processInfo.environment["VOICEPANEL_UI_TESTING"] == "1",
            let rawValue = ProcessInfo.processInfo.environment["VOICEPANEL_UI_TEST_INITIAL_PAGE"],
            let page = SettingsPage(rawValue: rawValue)
        else {
            return .general
        }
        return page
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .performance: return "Performance Testing"
        case .workflow: return "Workflow"
        case .history: return "History"
        case .advanced: return "Advanced"
        }
    }

    var navigationTitle: String { title }

    var subtitle: String {
        switch self {
        case .general: return "Choose the microphone, environment, engine, model, profile, language, and compute mode."
        case .performance:
            return "Choose a final model first, then validate VAD and phrase segmentation on the same sample."
        case .workflow: return "Configure recording, completion behavior, the panel, and live feedback."
        case .history: return "Control how long completed transcripts remain on this Mac."
        case .advanced:
            return "Customize microphone activation, speech detection, boundaries, prompts, and engine details."
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .workflow: return "rectangle.and.hand.point.up.left"
        case .history: return "clock.arrow.circlepath"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

#if DEBUG
    private enum PerformancePipelineComparisonPreviewData {
        static let target = RecognitionValidationTarget(
            engine: "Whisper",
            model: "Large V3 Turbo",
            modelSize: "Q5",
            compute: "CPU",
            profile: "Balanced",
            language: "Russian"
        )
        static let left = RecognitionValidationRun(
            target: target,
            sampleDuration: 12,
            processingDurations: [1.2],
            transcript: "Мы проверили старую версию текста и увидели повтор на границе.",
            pipelineSummary: .init(
                capturedDuration: 12,
                minimumAcceptedDuration: 1,
                acceptedByRecordingPolicy: true,
                chunks: []
            )
        )
        static let right = RecognitionValidationRun(
            target: RecognitionValidationTarget(
                engine: "Whisper",
                model: "Large V3 Turbo",
                modelSize: "Q5",
                compute: "CPU",
                profile: "Quality",
                language: "Russian"
            ),
            sampleDuration: 12,
            processingDurations: [1.4],
            transcript: "Мы проверили новую версию текста и устранили повтор на границе.",
            pipelineSummary: .init(
                capturedDuration: 12,
                minimumAcceptedDuration: 1,
                acceptedByRecordingPolicy: true,
                chunks: []
            )
        )
    }

    @MainActor
    private struct SettingsViewPreviewHost: View {
        private let environment: VoicePanelPreviewEnvironment
        private let benchmark: ModelBenchmarkRunner
        private let page: SettingsPage

        init(page: SettingsPage) {
            let environment = VoicePanelPreviewEnvironment()
            let benchmark = ModelBenchmarkRunner(monitorsAudioInputDevices: false)
            if page == .performance {
                benchmark.configurePreview(
                    visualization: VoicePanelPreviewData.pipelineVisualization,
                    summary: VoicePanelPreviewData.pipelineSummary,
                    baseSettings: environment.settings
                )
            }
            self.environment = environment
            self.benchmark = benchmark
            self.page = page
        }

        var body: some View {
            SettingsView(
                settings: environment.settings,
                state: environment.state,
                whisperModels: environment.whisperModels,
                whisperRuntime: environment.whisperRuntime,
                whisperDraftRuntime: environment.whisperDraftRuntime,
                gigaAMModels: environment.gigaAMModels,
                gigaAMRuntime: environment.gigaAMRuntime,
                gigaAMDraftRuntime: environment.gigaAMDraftRuntime,
                localONNXModels: environment.localONNXModels,
                localONNXRuntime: environment.localONNXRuntime,
                sileroVADModels: environment.sileroVADModels,
                russianCorrectionModels: environment.russianCorrectionModels,
                russianCorrectionRuntime: environment.russianCorrectionRuntime,
                history: environment.history,
                coordinator: environment.coordinator,
                presentationContext: SettingsPresentationContext(),
                initialPage: page,
                modelBenchmark: benchmark,
                onHotKeyChanged: {}
            )
            .frame(width: 1180, height: 780)
        }
    }

    private struct PerformancePipelineChunkTrackPreviewHost: View {
        @State private var selectedChunkID: UUID? = VoicePanelPreviewData.pipelineVisualization
            .chunkOverlays.first?.id

        var body: some View {
            PerformancePipelineChunkTrack(
                chunks: VoicePanelPreviewData.pipelineVisualization.chunkOverlays,
                duration: VoicePanelPreviewData.pipelineVisualization.duration,
                selectedChunkID: $selectedChunkID
            )
            .frame(width: 760, height: 36)
            .padding()
        }
    }

    private struct SettingsDisclosureGroupPreviewHost: View {
        @State private var isExpanded = true

        var body: some View {
            SettingsDisclosureGroup(
                title: "Model-specific inference",
                systemImage: "cpu",
                trailingText: "Whisper",
                isExpanded: $isExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use previous text after forced splits", isOn: .constant(true))
                    Text("Preview content stays interactive in the Xcode canvas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 620)
            .padding()
        }
    }

    #Preview("Settings · General") {
        SettingsViewPreviewHost(page: .general)
    }

    #Preview("Settings · Performance Testing") {
        SettingsViewPreviewHost(page: .performance)
    }

    #Preview("Performance VAD A/B Comparison") {
        PerformancePipelineComparisonSheet(
            left: PerformancePipelineComparisonItem(
                run: PerformancePipelineComparisonPreviewData.left,
                visualization: VoicePanelPreviewData.pipelineVisualization,
                summary: VoicePanelPreviewData.pipelineSummary,
                reusesPreviousChunkContext: false
            ),
            right: PerformancePipelineComparisonItem(
                run: PerformancePipelineComparisonPreviewData.right,
                visualization: VoicePanelPreviewData.pipelineVisualization,
                summary: VoicePanelPreviewData.pipelineSummary,
                reusesPreviousChunkContext: true
            )
        )
    }

    #Preview("Settings · Workflow") {
        SettingsViewPreviewHost(page: .workflow)
    }

    #Preview("Settings · History") {
        SettingsViewPreviewHost(page: .history)
    }

    #Preview("Settings · Advanced") {
        SettingsViewPreviewHost(page: .advanced)
    }

    #Preview("Recognition Preset Sheet") {
        RecognitionPresetNameSheet(onSave: { _ in })
    }

    #Preview("Recognition Text Editor") {
        RecognitionTextEditorSheet(
            title: "Recognition Context",
            help: "Describe the subject, style, and punctuation expected from the final transcript.",
            placeholder: "Technical discussion about macOS development…",
            initialText: "Technical discussion about SwiftUI, Core Audio, and local speech recognition.",
            onSave: { _ in }
        )
    }

    #Preview("Pipeline Visualization") {
        PerformancePipelineVisualizationView(
            visualization: VoicePanelPreviewData.pipelineVisualization,
            summary: VoicePanelPreviewData.pipelineSummary,
            reusesPreviousChunkContext: true
        )
        .frame(width: 860)
        .padding()
    }

    #Preview("Pipeline Time Scale") {
        PerformancePipelineTimeScale(duration: VoicePanelPreviewData.pipelineVisualization.duration)
            .frame(width: 760, height: 18)
            .padding()
    }

    #Preview("Pipeline Signal Track") {
        PerformancePipelineSignalTrack(
            visualization: VoicePanelPreviewData.pipelineVisualization,
            selectedChunk: VoicePanelPreviewData.pipelineVisualization.chunkOverlays.first
        )
        .frame(width: 760, height: 92)
        .padding()
    }

    #Preview("Pipeline VAD Track") {
        PerformancePipelineStateTrack(
            visualization: VoicePanelPreviewData.pipelineVisualization,
            selectedChunk: VoicePanelPreviewData.pipelineVisualization.chunkOverlays.first
        )
        .frame(width: 760, height: 24)
        .padding()
    }

    #Preview("Pipeline Chunk Track") {
        PerformancePipelineChunkTrackPreviewHost()
    }

    #Preview("Pipeline Chunk Inspector") {
        PerformancePipelineChunkInspector(
            index: 0,
            overlay: VoicePanelPreviewData.pipelineVisualization.chunkOverlays[0],
            visualization: VoicePanelPreviewData.pipelineVisualization,
            reusesPreviousChunkContext: true
        )
        .frame(width: 760)
        .padding()
    }

    #Preview("Settings Disclosure Group") {
        SettingsDisclosureGroupPreviewHost()
    }
#endif
