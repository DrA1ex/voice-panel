import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoicePanelCore

struct FullTranscriptView: View {
    @ObservedObject var state: AppState

    let onImportAudioFile: @MainActor (URL) -> Void
    let onCancel: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var isAudioDropTargeted = false
    @StateObject private var transcriptScroll = TranscriptScrollCoordinator()

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                transcriptBody
                Divider()
                footer
            }
            .frame(minWidth: 560, minHeight: 360)
            .background(Color(nsColor: .windowBackgroundColor))

            if isAudioDropTargeted && state.canStartRecording {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.badge.plus")
                                .font(.system(size: 38, weight: .semibold))
                            Text("Drop audio to transcribe")
                                .font(.headline)
                            Text("VoicePanel will convert, split, and process it with the active setup.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9, 6]))
                            .foregroundStyle(.tint)
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isAudioDropTargeted
        ) { providers in
            guard state.canStartRecording else { return false }
            return AudioFileDropHandler.accept(
                providers: providers,
                onURL: onImportAudioFile
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript-window.root")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: headerSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(headerColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.headline)
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()

                if state.isImportingAudioFile && state.phase.isRecordingRelated {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                }

                HStack(spacing: 7) {
                    if state.phase == .finalizing || state.phase == .stopping {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Circle()
                            .fill(headerColor)
                            .frame(width: 7, height: 7)
                    }
                    Text(statusTitle)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(headerColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(headerColor.opacity(0.12)))
            }

            if state.isImportingAudioFile, let progress = state.audioImportProgress {
                VStack(alignment: .leading, spacing: 5) {
                    if let fraction = importProgressFraction(progress) {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    HStack {
                        Text(importProgressLabel(progress))
                        Spacer()
                        if let remaining = progress.estimatedRemainingDuration {
                            Text("About \(formatDuration(remaining)) remaining")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if let fallbackDescription = progress.fallbackDescription {
                        Text(fallbackDescription)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if state.phase == .result {
            TextEditor(text: $state.editableText)
                .accessibilityIdentifier("transcript-window.editor")
                .font(.system(size: 15, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(16)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if state.combinedTranscript.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(.tertiary)
                                Text(emptyMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if state.phase == .listening {
                                    Text("The recording session remains active while you pause.")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                        } else {
                            transcriptText
                                .font(.system(size: 15, design: .rounded))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom")
                    }
                    .padding(18)
                }
                .onChange(of: state.transcriptPresentation.combinedText, initial: true) { _, _ in
                    transcriptScroll.schedule {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onDisappear {
                    transcriptScroll.cancel()
                }
            }
        }
    }

    private var transcriptText: Text {
        state.transcriptPresentation.runs.reduce(Text("")) { text, run in
            let next = Text(run.text)
            return text + (run.shouldDim ? next.foregroundColor(.secondary) : next)
        }
    }

    private var footer: some View {
        HStack {
            Text("Chunks: \(state.emittedChunkCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Button(state.phase == .result ? "Copy & Close" : "Copy", action: onCopy)
                .buttonStyle(.borderedProminent)
                .disabled(
                    (state.phase != .result && state.phase != .failed)
                        || (state.phase == .result ? state.editableText : state.combinedTranscript)
                            .isEmpty
                )
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func importProgressFraction(_ progress: AudioImportProgress) -> Double? {
        if progress.stage == .converting {
            return state.preparationProgress
        }
        return progress.fractionCompleted
    }

    private func importProgressLabel(_ progress: AudioImportProgress) -> String {
        switch progress.stage {
        case .preparing: return "Preparing recognizer"
        case .converting: return "Converting audio"
        case .analyzing: return "Detecting speech and building chunks"
        case .transcribing:
            guard progress.totalChunks > 0 else { return "Transcribing audio" }
            let current = min(max(progress.currentChunk, 1), progress.totalChunks)
            return "Chunk \(current) of \(progress.totalChunks) · \(progress.completedChunks) completed"
        case .finalizing: return "Assembling final transcript"
        case .cancelling: return "Cancelling import"
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 { return "\(max(1, seconds)) sec" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private var headerSubtitle: String {
        switch state.phase {
        case .result:
            return "Editable result"
        case .preparing:
            return state.statusMessage
        case .listening:
            return "Read-only while recording"
        case .finalizing, .stopping:
            return state.isImportingAudioFile
                ? state.statusMessage
                : "Completing the last recognition result"
        case .failed:
            return state.lastError ?? "Recognition failed"
        default:
            return state.statusMessage
        }
    }

    private var headerTitle: String {
        switch state.phase {
        case .result: return "Transcript Result"
        case .failed: return "Transcript Error"
        case .preparing where state.isImportingAudioFile: return "Importing Audio"
        case .preparing: return "Waiting for Model"
        case .finalizing where state.isImportingAudioFile: return "Transcribing Audio"
        default: return "Live Transcript"
        }
    }

    private var statusTitle: String {
        switch state.phase {
        case .preparing: return state.isImportingAudioFile ? "Importing" : "Waiting"
        case .listening: return "Recording"
        case .stopping, .finalizing: return "Processing"
        case .result: return "Ready"
        case .failed: return "Error"
        default: return state.statusMessage
        }
    }

    private var headerSymbol: String {
        switch state.phase {
        case .result: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopping, .finalizing: return "sparkles"
        case .preparing where state.isImportingAudioFile: return "waveform.badge.plus"
        case .preparing: return "hourglass"
        default: return "waveform"
        }
    }

    private var headerColor: Color {
        switch state.phase {
        case .listening, .failed: return .red
        case .stopping, .finalizing, .preparing: return .orange
        case .result: return .green
        default: return .secondary
        }
    }

    private var emptyMessage: String {
        switch state.phase {
        case .preparing:
            return state.statusMessage
        case .listening:
            return "Start speaking — recognized text will appear here."
        case .stopping, .finalizing:
            return "Completing the transcript…"
        case .failed:
            return state.lastError ?? "Recognition failed"
        default:
            return "No transcript yet."
        }
    }
}

#if DEBUG
    @MainActor
    private struct FullTranscriptPreviewHost: View {
        private let environment: VoicePanelPreviewEnvironment

        init(scenario: VoicePanelPreviewScenario) {
            environment = VoicePanelPreviewEnvironment(scenario: scenario)
        }

        var body: some View {
            FullTranscriptView(
                state: environment.state,
                onImportAudioFile: { _ in },
                onCancel: {},
                onCopy: {},
                onClose: {}
            )
            .frame(width: 720, height: 480)
        }
    }

    #Preview("Full Transcript · Listening") {
        FullTranscriptPreviewHost(scenario: .listening)
    }

    #Preview("Full Transcript · Result") {
        FullTranscriptPreviewHost(scenario: .result)
    }

    #Preview("Full Transcript · Error") {
        FullTranscriptPreviewHost(scenario: .failed)
    }
#endif
