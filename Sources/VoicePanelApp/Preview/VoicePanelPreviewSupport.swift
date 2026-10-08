#if DEBUG
    import Foundation
    import SwiftUI
    import VoicePanelCore

    enum VoicePanelPreviewScenario {
        case idle
        case listening
        case finalizing
        case result
        case failed
    }

    @MainActor
    final class VoicePanelPreviewEnvironment {
        let settings: AppSettings
        let state: AppState
        let history: HistoryModel
        let whisperModels: WhisperModelManager
        let whisperRuntime: WhisperRuntimeManager
        let whisperDraftRuntime: WhisperRuntimeManager
        let gigaAMModels: GigaAMModelManager
        let gigaAMRuntime: GigaAMRuntimeManager
        let gigaAMDraftRuntime: GigaAMRuntimeManager
        let localONNXModels: LocalONNXModelManager
        let localONNXRuntime: LocalONNXRuntimeManager
        let sileroVADModels: SileroVADModelManager
        let russianCorrectionModels: RussianCorrectionModelManager
        let russianCorrectionRuntime: RussianTextCorrectionRuntimeManager
        let coordinator: TranscriptionCoordinator

        init(
            scenario: VoicePanelPreviewScenario = .idle,
            historyRecords: [TranscriptHistoryRecord] = VoicePanelPreviewData.historyRecords,
            historyUnlocked: Bool = true
        ) {
            let suiteName = "io.github.dra1ex.VoicePanel.preview.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)

            let settings = AppSettings(defaults: defaults)
            settings.windowAppearanceMode = .light
            settings.panelAppearanceMode = .dark
            settings.panelSizePreset = .medium
            settings.pendingFeedbackStyle = .gradientBars
            settings.historyStorageMode = .encrypted
            settings.historyRetentionPreset = .thirtyDays
            settings.recognitionBackend = .whisper
            settings.recognitionProfile = .recommended
            settings.whisperBoundaryStrategy = .standard
            settings.whisperFileTranscriptionMode = .profileVAD
            self.settings = settings

            let state = AppState()
            VoicePanelPreviewData.configure(state: state, scenario: scenario)
            self.state = state

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoicePanel-Preview-\(UUID().uuidString)", isDirectory: true)
            let modelsRoot = root.appendingPathComponent("Models", isDirectory: true)

            let whisperModels = WhisperModelManager(
                modelsDirectory: modelsRoot.appendingPathComponent("Whisper", isDirectory: true)
            )
            self.whisperModels = whisperModels
            whisperRuntime = WhisperRuntimeManager(models: whisperModels)
            whisperDraftRuntime = WhisperRuntimeManager(models: whisperModels)

            let gigaAMModels = GigaAMModelManager(
                modelsDirectory: modelsRoot.appendingPathComponent("GigaAM", isDirectory: true)
            )
            self.gigaAMModels = gigaAMModels
            gigaAMRuntime = GigaAMRuntimeManager(models: gigaAMModels)
            gigaAMDraftRuntime = GigaAMRuntimeManager(models: gigaAMModels)

            let localONNXModels = LocalONNXModelManager(
                modelsDirectory: modelsRoot.appendingPathComponent("LocalONNX", isDirectory: true)
            )
            self.localONNXModels = localONNXModels
            localONNXRuntime = LocalONNXRuntimeManager(models: localONNXModels)

            sileroVADModels = SileroVADModelManager(
                modelsDirectory: modelsRoot.appendingPathComponent("VAD", isDirectory: true)
            )

            let russianCorrectionModels = RussianCorrectionModelManager(
                modelsDirectory: modelsRoot.appendingPathComponent("TextCorrection", isDirectory: true)
            )
            self.russianCorrectionModels = russianCorrectionModels
            russianCorrectionRuntime = RussianTextCorrectionRuntimeManager(models: russianCorrectionModels)

            let history = HistoryModel(
                previewSettings: settings,
                records: historyRecords,
                isUnlocked: historyUnlocked
            )
            self.history = history

            coordinator = TranscriptionCoordinator(
                state: state,
                settings: settings,
                history: history,
                whisperModels: whisperModels,
                whisperRuntime: whisperRuntime,
                whisperDraftRuntime: whisperDraftRuntime,
                gigaAMModels: gigaAMModels,
                gigaAMRuntime: gigaAMRuntime,
                gigaAMDraftRuntime: gigaAMDraftRuntime,
                localONNXModels: localONNXModels,
                localONNXRuntime: localONNXRuntime,
                sileroVADModels: sileroVADModels,
                russianCorrectionModels: russianCorrectionModels,
                russianCorrectionRuntime: russianCorrectionRuntime,
                monitorsAudioInputDevices: false
            )
        }
    }

    enum VoicePanelPreviewData {
        static let transcript =
            "VoicePanel keeps the microphone path responsive while the final model processes each completed phrase."

        static let historyRecords: [TranscriptHistoryRecord] = [
            TranscriptHistoryRecord(
                createdAt: Date().addingTimeInterval(-420),
                updatedAt: Date().addingTimeInterval(-420),
                text: "The benchmark now shows the exact text recognized for every generated chunk.",
                duration: 8.4,
                languageIdentifier: "en-US",
                engineName: "Whisper · Base Q5",
                isPinned: true
            ),
            TranscriptHistoryRecord(
                createdAt: Date().addingTimeInterval(-3_600),
                updatedAt: Date().addingTimeInterval(-3_600),
                text: "A short pause should end the phrase without cutting the last spoken word.",
                duration: 6.7,
                languageIdentifier: "en-US",
                engineName: "Apple Speech"
            ),
            TranscriptHistoryRecord(
                createdAt: Date().addingTimeInterval(-86_400),
                updatedAt: Date().addingTimeInterval(-86_400),
                text: "Проверяем отображение длинной расшифровки, перенос текста и работу истории.",
                duration: 11.2,
                languageIdentifier: "ru-RU",
                engineName: "GigaAM v3"
            ),
        ]

        static var pipelineVisualization: PerformancePipelineVisualization {
            let chunks = [
                PerformancePipelineVisualization.ChunkOverlay(
                    startTime: 0.62,
                    endTime: 3.36,
                    speechStartTime: 0.86,
                    speechEndTime: 2.71,
                    boundaryReason: .silence,
                    boundarySilenceDuration: 0.65,
                    recognitionState: .accepted("The benchmark now shows the exact text")
                ),
                PerformancePipelineVisualization.ChunkOverlay(
                    startTime: 3.08,
                    endTime: 6.92,
                    speechStartTime: 3.38,
                    speechEndTime: 6.58,
                    boundaryReason: .maximumDuration,
                    boundarySilenceDuration: nil,
                    recognitionState: .accepted("recognized for every generated chunk")
                ),
                PerformancePipelineVisualization.ChunkOverlay(
                    startTime: 6.68,
                    endTime: 10.74,
                    speechStartTime: 6.96,
                    speechEndTime: 10.18,
                    boundaryReason: .stopped,
                    boundarySilenceDuration: nil,
                    recognitionState: .pending
                ),
            ]

            return PerformancePipelineVisualization(
                duration: 11.2,
                waveformLevels: waveformLevels(count: 224),
                speechSpans: [
                    .init(startTime: 0, endTime: 0.86, kind: .silence),
                    .init(startTime: 0.86, endTime: 2.71, kind: .speech),
                    .init(startTime: 2.71, endTime: 3.38, kind: .possiblePause),
                    .init(startTime: 3.38, endTime: 6.58, kind: .speech),
                    .init(startTime: 6.58, endTime: 6.96, kind: .possiblePause),
                    .init(startTime: 6.96, endTime: 10.18, kind: .speech),
                    .init(startTime: 10.18, endTime: 11.2, kind: .silence),
                ],
                chunkOverlays: chunks,
                vadMarkers: [
                    .init(time: 0.86, kind: .speechStarted),
                    .init(time: 2.71, kind: .speechEnded),
                    .init(time: 3.38, kind: .speechStarted),
                    .init(time: 6.58, kind: .speechEnded),
                    .init(time: 6.96, kind: .speechStarted),
                    .init(time: 10.18, kind: .speechEnded),
                ],
                acceptedByRecordingPolicy: true,
                phraseBoundaryDuration: 0.65,
                maximumChunkDuration: 4,
                analysisDuration: 0.038
            )
        }

        static var pipelineSummary: RecognitionPipelineValidationSummary {
            RecognitionPipelineValidationSummary(
                capturedDuration: 11.2,
                minimumAcceptedDuration: 0.5,
                acceptedByRecordingPolicy: true,
                chunks: [
                    .init(boundaryReason: .silence, duration: 2.74, speechDuration: 1.85),
                    .init(boundaryReason: .maximumDuration, duration: 3.84, speechDuration: 3.20),
                    .init(boundaryReason: .stopped, duration: 4.06, speechDuration: 3.22),
                ]
            )
        }

        @MainActor
        static func configure(state: AppState, scenario: VoicePanelPreviewScenario) {
            switch scenario {
            case .idle:
                state.configurePreview(
                    phase: .idle,
                    statusMessage: "Ready",
                    currentLevelDB: -63,
                    currentNormalizedLevel: 0.12
                )
            case .listening:
                state.configurePreview(
                    phase: .listening,
                    stableText: "VoicePanel keeps the microphone path responsive",
                    partialText: "while the final model processes each completed phrase",
                    statusMessage: "Recording · Whisper",
                    voiceActivityState: .speech,
                    currentLevelDB: -27,
                    currentNormalizedLevel: 0.74,
                    emittedChunkCount: 2,
                    recordingDuration: 7.8,
                    pendingFeedbackItemCount: 3,
                    pendingFeedbackExtent: 3.4
                )
            case .finalizing:
                state.configurePreview(
                    phase: .finalizing,
                    stableText: transcript,
                    statusMessage: "Completing the last recognition result",
                    completionPresentation: .none,
                    preparationProgress: 0.82,
                    isWaitingForRecognizer: true,
                    emittedChunkCount: 3,
                    recordingDuration: 11.2,
                    pendingFeedbackItemCount: 2,
                    pendingFeedbackExtent: 2.2
                )
            case .result:
                state.configurePreview(
                    phase: .result,
                    editableText: transcript + " The result remains editable before it is copied.",
                    statusMessage: "Transcript ready",
                    completionPresentation: .success,
                    emittedChunkCount: 3,
                    recordingDuration: 11.2
                )
            case .failed:
                state.configurePreview(
                    phase: .failed,
                    stableText: "The captured text remains available even when the input device disappears.",
                    statusMessage: "Input device disconnected",
                    error: "The selected microphone is no longer available. VoicePanel switched to the system input."
                )
            }
        }

        private static func waveformLevels(count: Int) -> [Float] {
            (0..<count).map { index in
                let primary = (sin(Double(index) * 0.31) + 1) * 0.34
                let secondary = (sin(Double(index) * 0.083 + 1.7) + 1) * 0.15
                return Float(min(0.95, 0.08 + primary + secondary))
            }
        }
    }
#endif
