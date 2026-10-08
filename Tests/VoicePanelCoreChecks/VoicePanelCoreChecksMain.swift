import Foundation

@main
struct VoicePanelCoreChecksMain {
    static func main() {
        var checks: [CheckCase] = []
        checks.append(contentsOf: applicationArchitectureWarningPolicyChecks)
        checks.append(contentsOf: audioSegmenterChecks)
        checks.append(contentsOf: captureTimelineChecks)
        checks.append(contentsOf: audioImportProgressChecks)
        checks.append(contentsOf: audioInputRecoveryPolicyChecks)
        checks.append(contentsOf: audioCaptureLivenessChecks)
        checks.append(contentsOf: draftFinalSegmentAlignmentChecks)
        checks.append(contentsOf: finalizationFeedbackPolicyChecks)
        checks.append(contentsOf: forcedChunkAccumulatorChecks)
        checks.append(contentsOf: gigaAMChunkPolicyChecks)
        checks.append(contentsOf: hotKeyReleaseTailPolicyChecks)
        checks.append(contentsOf: recognitionInferenceChunkPolicyChecks)
        checks.append(contentsOf: linearAudioResamplerChecks)
        checks.append(contentsOf: modelBenchmarkProgressChecks)
        checks.append(contentsOf: pendingFeedbackPolicyChecks)
        checks.append(contentsOf: recordingControlPolicyChecks)
        checks.append(contentsOf: recordingPreparationAudioPolicyChecks)
        checks.append(contentsOf: recordingStopPolicyChecks)
        checks.append(contentsOf: statusMenuAdvancedItemsPolicyChecks)
        checks.append(contentsOf: recognitionProfilesChecks)
        checks.append(contentsOf: recognitionAudioChunkPipelineChecks)
        checks.append(contentsOf: recognitionDeferredChunkHandoffChecks)
        checks.append(contentsOf: recognitionAudioTransmissionPolicyChecks)
        checks.append(contentsOf: recognitionFinalizationPolicyChecks)
        checks.append(contentsOf: recognitionHallucinationGuardChecks)
        checks.append(contentsOf: recognitionPendingWorkChecks)
        checks.append(contentsOf: recognitionPipelineValidatorChecks)
        checks.append(contentsOf: recognitionPipelineVisualizationPolicyChecks)
        checks.append(contentsOf: recognitionQueuedResultPolicyChecks)
        checks.append(contentsOf: recognitionValidationChecks)
        checks.append(contentsOf: transcriptHistoryRepositoryChecks)
        checks.append(contentsOf: transcriptCandidateEditFilterChecks)
        checks.append(contentsOf: transcriptComparisonChecks)
        checks.append(contentsOf: transcriptPostProcessorChecks)
        checks.append(contentsOf: transcriptPostProcessingAccumulatorChecks)
        checks.append(contentsOf: transcriptBoundaryMetadataChecks)
        checks.append(contentsOf: transcriptSessionChecks)
        checks.append(contentsOf: transcriptStabilizerChecks)
        checks.append(contentsOf: transcriptTextNormalizerChecks)
        checks.append(contentsOf: voiceActivityDetectorChecks)
        checks.append(contentsOf: voiceActivityFusionChecks)
        checks.append(contentsOf: whisperAudioPreparationChecks)
        checks.append(contentsOf: whisperBoundaryBridgeChecks)
        checks.append(contentsOf: whisperBoundaryDiagnosticsChecks)
        checks.append(contentsOf: whisperBoundaryModesChecks)
        checks.append(contentsOf: whisperBoundaryPromptBuilderChecks)
        checks.append(contentsOf: whisperBoundaryRepairPolicyChecks)
        checks.append(contentsOf: whisperBoundarySessionStateChecks)
        checks.append(contentsOf: whisperBenchmarkMatrixChecks)
        checks.append(contentsOf: whisperEngineQueueStateChecks)
        checks.append(contentsOf: whisperFileImportPolicyChecks)
        checks.append(contentsOf: whisperTranscriptionResultChecks)

        var failures: [(String, Error)] = []
        for check in checks {
            do {
                try check.body()
                print("PASS  \(check.name)")
            } catch {
                failures.append((check.name, error))
                print("FAIL  \(check.name): \(error)")
            }
        }

        if failures.isEmpty {
            print("\nAll \(checks.count) core checks passed.")
            return
        }

        FileHandle.standardError.write(
            Data("\n\(failures.count) of \(checks.count) core checks failed.\n".utf8)
        )
        exit(1)
    }
}
