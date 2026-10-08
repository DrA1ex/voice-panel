import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoicePanelCore

struct CompactPanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings

    let onLatchHotKey: () -> Void
    let onStop: () -> Void
    let onCancel: () -> Void
    let onOpenTranscript: () -> Void
    let onImportAudioFile: @MainActor (URL) -> Void
    let onCopy: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    @State private var terminalWashExpanded = false
    @State private var terminalContentVisible = false
    @State private var terminalAnimationScheduled = false
    @State private var pendingFeedbackIsVisible = false
    @State private var displayedPendingFeedbackItemCount = 0
    @State private var displayedPendingFeedbackItemExtent: Double = 0
    @State private var pendingFeedbackShownAt: Date?
    @State private var isAudioDropTargeted = false
    @StateObject private var windowDrag = PanelWindowDragCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            ambientGlow
            panel
            if isAudioDropTargeted && state.canStartRecording {
                audioDropOverlay
            }
        }
        .frame(
            width: settings.panelSizePreset.windowWidth,
            height: panelWindowHeight
        )
        .preferredColorScheme(AppAppearance.colorScheme(for: settings.panelAppearanceMode))
        .background(PanelWindowReader(coordinator: windowDrag))
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in windowDrag.update() }
                .onEnded { _ in windowDrag.end() }
        )
        .animation(.linear(duration: 0.07), value: voiceGlowStrength)
        .onAppear(perform: updateTerminalAnimation)
        .onChange(of: state.phase) { _, _ in
            updateTerminalAnimation()
        }
        .onChange(of: state.completionPresentation) { _, _ in
            updateTerminalAnimation()
        }
        .onChange(of: pendingFeedbackPresentation.itemCount) { _, itemCount in
            if pendingFeedbackIsVisible, itemCount > 0 {
                displayedPendingFeedbackItemCount = itemCount
            }
        }
        .onChange(of: state.pendingFeedbackItemExtent) { _, itemExtent in
            if pendingFeedbackIsVisible, itemExtent > 0 {
                displayedPendingFeedbackItemExtent = itemExtent
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
        .accessibilityIdentifier("transcription-panel.root")
        .task(id: pendingFeedbackPresentation.hasVisibleItems) {
            await reconcilePendingFeedbackVisibility(
                hasUnresolvedWork: pendingFeedbackPresentation.hasVisibleItems
            )
        }
    }

    private var audioDropOverlay: some View {
        panelShape
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 7) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Drop audio to transcribe")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                panelShape
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .foregroundStyle(.tint)
            }
            .frame(width: settings.panelSizePreset.width, height: panelHeight)
            .shadow(radius: 12)
            .allowsHitTesting(false)
    }

    private var panel: some View {
        ZStack {
            panelBackground

            if showsTerminalWash {
                terminalWash
            }

            Group {
                switch compactAudioImportPresentation.content {
                case .processing:
                    processingContent
                case .result:
                    resultContent
                case .failure:
                    failureContent
                case .recording:
                    recordingContent
                }
            }
            .frame(
                width: settings.panelSizePreset.width - horizontalPadding * 2,
                height: panelHeight - verticalPadding * 2
            )
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
        .frame(
            width: settings.panelSizePreset.width,
            height: panelHeight
        )
        .clipShape(panelShape)
        .overlay {
            panelShape
                .strokeBorder(
                    LinearGradient(
                        colors: borderColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: isTerminalState ? 1.45 : 1
                )
        }
        .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if !settings.panelBackgroundIsTransparent {
            Color(nsColor: .windowBackgroundColor)
        } else if settings.panelBackgroundBlurEnabled && VisualEffectBackground.isSupported {
            VisualEffectBackground(material: .hudWindow)
            Color.black.opacity(0.16)
        } else {
            Color(nsColor: .windowBackgroundColor).opacity(0.76)
            Color.black.opacity(0.08)
        }
    }

    @ViewBuilder
    private var ambientGlow: some View {
        switch state.phase {
        case .preparing:
            processingAmbientGlow
        case .listening:
            voiceReactiveGlow
        case .stopping, .finalizing:
            processingAmbientGlow
        case .result:
            terminalAmbientGlow(color: resultTone)
        case .failed:
            terminalAmbientGlow(color: .red)
        default:
            EmptyView()
        }
    }

    private var voiceReactiveGlow: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { context in
            let pulse = reduceMotion ? 0.48 : recordingPulse(at: context.date)
            ZStack {
                panelShape
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.48),
                                Color.indigo.opacity(0.44),
                                Color.pink.opacity(0.43),
                                Color.orange.opacity(0.52),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .blur(radius: 13 + pulse * 7 + voiceGlowStrength * 9)
                    .scaleEffect(1.018 + pulse * 0.014 + voiceGlowStrength * 0.020)
                    .opacity(0.34 + pulse * 0.16 + voiceGlowStrength * 0.32)

                panelShape
                    .stroke(
                        LinearGradient(
                            colors: [.cyan, .indigo, .pink, .orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.8 + pulse * 1.3 + voiceGlowStrength * 2.6
                    )
                    .blur(radius: 3 + pulse * 3 + voiceGlowStrength * 5)
                    .scaleEffect(1.008 + pulse * 0.010 + voiceGlowStrength * 0.014)
                    .opacity(0.46 + pulse * 0.18 + voiceGlowStrength * 0.26)
            }
        }
        .frame(
            width: settings.panelSizePreset.width,
            height: panelHeight
        )
        .allowsHitTesting(false)
    }

    private var processingAmbientGlow: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let pulse = processingPulse(at: context.date)
            ZStack {
                panelShape
                    .fill(Color.orange.opacity(0.07 + pulse * 0.10))
                    .blur(radius: 12 + pulse * 8)
                    .scaleEffect(1.010 + pulse * 0.025)

                panelShape
                    .stroke(Color.yellow.opacity(0.20 + pulse * 0.28), lineWidth: 1.4 + pulse * 1.5)
                    .blur(radius: 3 + pulse * 4)
                    .scaleEffect(1.006 + pulse * 0.012)
            }
        }
        .frame(
            width: settings.panelSizePreset.width,
            height: panelHeight
        )
        .allowsHitTesting(false)
    }

    private func terminalAmbientGlow(color: Color) -> some View {
        panelShape
            .fill(color.opacity(terminalWashExpanded ? 0.14 : 0.035))
            .frame(
                width: settings.panelSizePreset.width,
                height: panelHeight
            )
            .blur(radius: terminalWashExpanded ? 15 : 8)
            .scaleEffect(terminalWashExpanded ? 1.020 : 1.004)
            .opacity(terminalWashExpanded ? 0.56 : 0.15)
            .allowsHitTesting(false)
    }

    private var terminalWash: some View {
        ZStack {
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            terminalColor.opacity(0.28),
                            terminalColor.opacity(0.11),
                            terminalColor.opacity(0.025),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: settings.panelSizePreset.width * 0.68
                    )
                )
                .frame(
                    width: settings.panelSizePreset.width * 1.12,
                    height: max(settings.panelSizePreset.width * 0.48, panelHeight * 1.4)
                )
                .scaleEffect(terminalWashExpanded ? 1 : 0.012)

            terminalColor.opacity(terminalWashExpanded ? 0.025 : 0)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var recordingContent: some View {
        switch settings.panelSizePreset {
        case .compact:
            compactRecordingContent
        case .medium:
            mediumRecordingContent
        case .large:
            largeRecordingContent
        }
    }

    @ViewBuilder
    private var compactRecordingContent: some View {
        switch compactAudioImportPresentation.recordingLayout {
        case .standardRecording:
            VStack(spacing: compactImportLayout.recordingSpacing) {
                header
                    .frame(height: headerHeight)

                waveform

                HStack(spacing: 9) {
                    transcriptViewport
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if usesManualRecordingControls {
                        recordingControls
                    }
                }
                .frame(height: transcriptRowHeight)
            }
        case .dedicatedImportProgress:
            VStack(alignment: .leading, spacing: compactImportLayout.recordingSpacing) {
                header
                    .frame(height: headerHeight)

                compactAudioImportProgressBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: compactImportLayout.dedicatedProgressHeight, alignment: .top)
            }
        }
    }

    private var mediumRecordingContent: some View {
        VStack(spacing: 10) {
            header
                .frame(height: headerHeight)

            waveform

            panelDivider

            HStack(spacing: 16) {
                transcriptViewport
                    .frame(maxWidth: .infinity, alignment: .leading)

                if usesManualRecordingControls {
                    recordingControls
                }
            }
            .frame(height: transcriptRowHeight)
        }
    }

    private var largeRecordingContent: some View {
        VStack(spacing: 11) {
            header
                .frame(height: headerHeight)

            waveform

            panelDivider

            VStack(alignment: .leading, spacing: 12) {
                largeTranscriptViewport
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if usesManualRecordingControls {
                    HStack {
                        Spacer()
                        recordingControls
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var waveform: some View {
        if !compactAudioImportPresentation.elements.isEmpty {
            compactAudioImportProgressBlock
        } else if state.phase == .preparing {
            Group {
                if let progress = state.preparationProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: waveformHeight)
        } else {
            WaveformView(
                levels: state.audioLevels,
                visibleLevelCount: state.audioLevelCount,
                active: state.phase == .listening
            )
            .frame(height: waveformHeight)
        }
    }

    private var panelDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.07))
    }

    @ViewBuilder
    private var largeTranscriptViewport: some View {
        if state.combinedTranscript.isEmpty && !hasPendingFeedback {
            HStack(spacing: 9) {
                Image(systemName: placeholderSymbol)
                    .foregroundStyle(.secondary)
                Text(placeholder)
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: transcriptFontSize, weight: .regular, design: .rounded))
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if !state.combinedTranscript.isEmpty {
                    TranscriptTextViewport(
                        text: multilineTranscriptText,
                        fontSize: transcriptFontSize,
                        maximumLines: 3
                    )
                    .frame(height: transcriptFontSize * 1.5 * 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if hasPendingFeedback {
                    SlidingTranscriptView(
                        text: "",
                        pendingFeedbackStyle: settings.effectivePendingFeedbackStyle,
                        pendingItemCount: pendingFeedbackItemCount,
                        pendingItemExtent: pendingFeedbackItemExtent,
                        pendingFeedbackIsActive: pendingFeedbackIsVisible
                    )
                    .frame(height: 22)
                }
            }
        }
    }

    @ViewBuilder
    private var processingContent: some View {
        switch settings.panelSizePreset {
        case .compact, .medium:
            VStack(spacing: settings.panelSizePreset == .compact ? 8 : 10) {
                header.frame(height: headerHeight)
                HStack(spacing: settings.panelSizePreset == .compact ? 12 : 14) {
                    processingLoader
                    processingStatusContent
                    Spacer(minLength: 8)
                    if state.isImportingAudioFile {
                        panelIconButton(
                            systemName: "xmark",
                            help: "Cancel audio transcription",
                            action: onCancel
                        )
                    }
                }
                .frame(maxHeight: .infinity)
            }
        case .large:
            VStack(spacing: 14) {
                header.frame(height: headerHeight)
                Spacer(minLength: 0)
                processingLoader
                processingStatusContent
                    .frame(maxWidth: 430)
                if state.isImportingAudioFile {
                    Button("Cancel Audio Transcription", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var processingStatusContent: some View {
        VStack(alignment: settings.panelSizePreset == .large ? .center : .leading, spacing: 4) {
            processingTitle
            processingDetail
            compactAudioImportProgressBlock
        }
    }

    @ViewBuilder
    private var compactAudioImportProgressBlock: some View {
        VStack(
            alignment: settings.panelSizePreset == .large ? .center : .leading,
            spacing: settings.panelSizePreset == .compact ? compactImportLayout.progressSpacing : 4
        ) {
            ForEach(Array(compactAudioImportPresentation.elements.enumerated()), id: \.offset) {
                _, element in
                switch element {
                case .indeterminateIndicator:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: compactImportProgressMaxWidth)
                        .frame(height: compactImportProgressIndicatorHeight)
                case .determinateIndicator(let fraction):
                    ProgressView(value: fraction)
                        .frame(maxWidth: compactImportProgressMaxWidth)
                        .frame(height: compactImportProgressIndicatorHeight)
                case .fallbackDescription(let fallbackDescription):
                    Text(fallbackDescription)
                        .font(compactImportFallbackFont)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(
                            settings.panelSizePreset == .large ? .center : .leading
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var processingLoader: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { context in
            let pulse = reduceMotion ? 0.5 : processingPulse(at: context.date)
            let rotation =
                reduceMotion
                ? -35.0
                : context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.15) / 1.15 * 360
            let lineWidth = max(2.4, processingIconSize * 0.12)

            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.14), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0.08, to: 0.76)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color.yellow.opacity(0.18),
                                Color.orange.opacity(0.72),
                                Color.orange,
                                Color.yellow,
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotation))
                    .shadow(
                        color: Color.orange.opacity(0.30 + pulse * 0.20),
                        radius: 3 + pulse * 3
                    )
            }
            .frame(width: processingIconSize + 10, height: processingIconSize + 10)
        }
        .frame(width: processingIconSize + 18, height: processingIconSize + 18)
    }

    private var processingTitle: some View {
        Text(state.isImportingAudioFile ? "Transcribing audio" : "Processing recording")
            .font(.system(size: transcriptFontSize, weight: .semibold, design: .rounded))
    }

    private var processingDetail: some View {
        Text(finalizationDetail)
            .font(settings.panelSizePreset == .compact ? .caption2 : .caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var resultContent: some View {
        terminalContent(
            symbol: resultSymbol,
            tone: resultTone,
            title: resultTitle,
            detail: resultDetail,
            showsResultActions: showsManualResultControls
        )
    }

    private var failureContent: some View {
        terminalContent(
            symbol: "exclamationmark.triangle.fill",
            tone: .red,
            title: "Something went wrong",
            detail: state.lastError ?? "The recording could not be completed",
            showsResultActions: false
        )
    }

    @ViewBuilder
    private func terminalContent(
        symbol: String,
        tone: Color,
        title: String,
        detail: String,
        showsResultActions: Bool
    ) -> some View {
        switch settings.panelSizePreset {
        case .compact:
            VStack(spacing: 8) {
                header.frame(height: headerHeight)
                HStack(spacing: 10) {
                    terminalSummary(
                        symbol: symbol,
                        tone: tone,
                        title: title,
                        detail: detail,
                        showsDetail: false
                    )
                    Spacer(minLength: 6)
                    if state.phase == .failed {
                        failureControls
                    } else if showsResultActions {
                        resultControls
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .opacity(terminalContentVisible ? 1 : 0)
        case .medium:
            VStack(spacing: 9) {
                header.frame(height: headerHeight)
                HStack(spacing: 12) {
                    terminalSummary(
                        symbol: symbol,
                        tone: tone,
                        title: title,
                        detail: detail,
                        showsDetail: true
                    )
                    Spacer(minLength: 8)
                    if state.phase == .failed {
                        failureControls
                    }
                }
                .frame(maxHeight: .infinity)
                if state.phase != .failed, showsResultActions {
                    resultControls
                }
            }
            .opacity(terminalContentVisible ? 1 : 0)
        case .large:
            VStack(spacing: 16) {
                header.frame(height: headerHeight)
                Spacer(minLength: 0)
                terminalSummary(
                    symbol: symbol,
                    tone: tone,
                    title: title,
                    detail: detail,
                    showsDetail: true
                )
                Spacer(minLength: 0)
                if state.phase == .failed {
                    HStack {
                        Spacer()
                        failureControls
                    }
                } else if showsResultActions {
                    resultControls
                }
            }
            .opacity(terminalContentVisible ? 1 : 0)
        }
    }

    private func terminalSummary(
        symbol: String,
        tone: Color,
        title: String,
        detail: String,
        showsDetail: Bool
    ) -> some View {
        HStack(spacing: settings.panelSizePreset == .compact ? 9 : 14) {
            Image(systemName: symbol)
                .font(.system(size: terminalIconSize, weight: .semibold))
                .foregroundStyle(tone)
                .shadow(color: tone.opacity(0.68), radius: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(
                        .system(
                            size: transcriptFontSize + 1,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .lineLimit(1)
                if showsDetail {
                    Text(detail)
                        .font(settings.panelSizePreset == .large ? .callout : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("transcription-panel.summary")
        .accessibilityLabel("\(title). \(detail)")
    }

    private var header: some View {
        HStack(spacing: headerSpacing) {
            ZStack {
                Circle()
                    .fill(indicatorColor.opacity(0.18))
                    .frame(width: headerIndicatorSize, height: headerIndicatorSize)
                Circle()
                    .fill(indicatorColor)
                    .frame(width: headerIndicatorSize * 0.48, height: headerIndicatorSize * 0.48)
                    .shadow(color: indicatorColor.opacity(0.8), radius: 5)
            }

            Text(headerTitle)
                .accessibilityIdentifier("transcription-panel.status")
                .font(.system(size: headerFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(headerAccentColor)
                .layoutPriority(2)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(state.inputDeviceWarning ?? state.activeEngineName)
                .font(.system(size: headerFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(state.inputDeviceWarning == nil ? Color.secondary : Color.orange)
                .help(state.inputDeviceWarning ?? state.activeEngineName)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 8)

            if state.phase == .preparing {
                if canLatchHotKeyRecording {
                    Button(action: onLatchHotKey) {
                        Image(systemName: "pin")
                            .font(.system(size: headerTrailingIconSize, weight: .semibold))
                            .frame(width: headerTrailingIconSize + 7, height: headerTrailingIconSize + 7)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
                    .help("Keep waiting and start recording when the model is ready")
                } else if state.recordingControlSource == .hotKeyLatched {
                    Image(systemName: "pin.fill")
                        .font(.system(size: headerTrailingIconSize, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("Recording will start when the model is ready")
                }

                Image(systemName: state.isImportingAudioFile ? "waveform.badge.plus" : "hourglass")
                    .font(.system(size: headerTrailingIconSize, weight: .semibold))
                    .foregroundStyle(.orange)
            } else if state.phase == .listening {
                if canLatchHotKeyRecording {
                    Button(action: onLatchHotKey) {
                        Image(systemName: "pin")
                            .font(.system(size: headerTrailingIconSize, weight: .semibold))
                            .frame(width: headerTrailingIconSize + 7, height: headerTrailingIconSize + 7)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
                    .help("Keep recording after releasing the hot key")
                } else if state.recordingControlSource == .hotKeyLatched {
                    Image(systemName: "pin.fill")
                        .font(.system(size: headerTrailingIconSize, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("Recording continues until you press Stop")
                }

                Text(formattedRecordingDuration)
                    .font(.system(size: headerFontSize, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "waveform")
                    .font(.system(size: headerTrailingIconSize, weight: .semibold))
                    .foregroundStyle(.orange)
            } else if state.phase == .stopping || state.phase == .finalizing {
                Image(systemName: "sparkles")
                    .font(.system(size: headerTrailingIconSize, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var transcriptViewport: some View {
        if state.combinedTranscript.isEmpty && !hasPendingFeedback {
            HStack(spacing: 7) {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: transcriptFontSize - 2, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .font(.system(size: transcriptFontSize, weight: .regular, design: .rounded))
            .frame(height: transcriptRowHeight, alignment: .leading)
        } else {
            SlidingTranscriptView(
                text: state.compactTranscriptText,
                fontSize: transcriptFontSize,
                pendingFeedbackStyle: state.phase.isRecordingRelated
                    ? settings.effectivePendingFeedbackStyle : nil,
                pendingItemCount: pendingFeedbackItemCount,
                pendingItemExtent: pendingFeedbackItemExtent,
                pendingFeedbackIsActive: pendingFeedbackIsVisible
            )
            .font(.system(size: transcriptFontSize, weight: .regular, design: .rounded))
            .frame(height: transcriptRowHeight)
        }
    }

    private var recordingControls: some View {
        HStack(spacing: actionButtonSpacing) {
            panelIconButton(
                systemName: "text.alignleft",
                help: "Open full transcript",
                action: onOpenTranscript
            )

            if state.phase == .listening {
                panelIconButton(
                    systemName: "stop.fill",
                    help: "Stop recording",
                    action: onStop
                )
                .accessibilityIdentifier("transcription-panel.stop")
            }

            panelIconButton(
                systemName: "xmark",
                help: "Cancel recording",
                action: onCancel
            )
            .accessibilityIdentifier("transcription-panel.cancel")
        }
        .accessibilityElement(children: .contain)
    }

    private var failureControls: some View {
        HStack(spacing: actionButtonSpacing) {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("transcription-panel.retry")
            closeButton
        }
        .accessibilityElement(children: .contain)
    }

    private var resultControls: some View {
        HStack(spacing: actionButtonSpacing) {
            Button(action: onCopy) {
                resultButtonLabel("Copy again", systemImage: "doc.on.doc")
            }
            .buttonStyle(
                PanelActionButtonStyle(
                    compact: settings.panelSizePreset == .compact,
                    prominent: true,
                    tone: resultTone
                )
            )
            .disabled(state.editableText.isEmpty)
            .help("Copy again")
            .accessibilityIdentifier("transcription-panel.copy")

            Button(action: onOpenTranscript) {
                resultButtonLabel("Open transcript", systemImage: "text.alignleft")
            }
            .buttonStyle(
                PanelActionButtonStyle(
                    compact: settings.panelSizePreset == .compact,
                    prominent: false,
                    tone: resultTone
                )
            )
            .help("Open transcript")
            .accessibilityIdentifier("transcription-panel.open-transcript")

            Button(action: onClose) {
                resultButtonLabel("Close", systemImage: "xmark")
            }
            .buttonStyle(
                PanelActionButtonStyle(
                    compact: settings.panelSizePreset == .compact,
                    prominent: false,
                    tone: resultTone
                )
            )
            .help("Close")
            .accessibilityIdentifier("transcription-panel.close")
        }
        .accessibilityElement(children: .contain)
        .frame(maxWidth: settings.panelSizePreset == .compact ? nil : 520)
    }

    @ViewBuilder
    private func resultButtonLabel(_ title: String, systemImage: String) -> some View {
        if settings.panelSizePreset == .compact {
            Image(systemName: systemImage)
                .frame(width: actionButtonSize, height: actionButtonSize)
        } else {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: resultButtonLabelHeight)
        }
    }

    private var closeButton: some View {
        panelIconButton(systemName: "xmark", help: "Close", action: onClose)
    }

    private func panelIconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: actionIconSize, weight: .medium))
                .frame(width: actionButtonSize, height: actionButtonSize)
        }
        .buttonStyle(PanelIconButtonStyle())
        .accessibilityLabel(help)
        .help(help)
    }

    private func updateTerminalAnimation() {
        guard isTerminalState else {
            terminalWashExpanded = false
            terminalContentVisible = false
            terminalAnimationScheduled = false
            return
        }

        guard !terminalAnimationScheduled else { return }
        terminalAnimationScheduled = true

        terminalWashExpanded = false
        terminalContentVisible = false
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.52)) {
                terminalWashExpanded = true
            }
            withAnimation(.spring(response: 0.40, dampingFraction: 0.72).delay(0.14)) {
                terminalContentVisible = true
            }
        }
    }

    private func processingPulse(at date: Date) -> Double {
        (sin(date.timeIntervalSinceReferenceDate * .pi * 1.35) + 1) / 2
    }

    private func recordingPulse(at date: Date) -> Double {
        (sin(date.timeIntervalSinceReferenceDate * .pi * 1.65) + 1) / 2
    }

    private var finalizationDetail: String {
        if state.isImportingAudioFile, let progress = state.audioImportProgress {
            return compactImportProgressDetail(progress)
        }
        if state.pendingRecognitionWork.chunkCount > 0 || state.recognitionQueueDepth > 0 {
            let count = max(state.pendingRecognitionWork.chunkCount, state.recognitionQueueDepth)
            return "Finishing \(count) remaining audio \(count == 1 ? "segment" : "segments")"
        }
        return "Polishing the final transcript"
    }

    private var compactAudioImportPresentation: CompactAudioImportPresentation {
        let phase: CompactAudioImportPresentation.Phase
        switch state.phase {
        case .preparing:
            phase = .preparing
        case .listening:
            phase = .listening
        case .stopping:
            phase = .stopping
        case .finalizing:
            phase = .finalizing
        case .result:
            phase = .result
        case .failed:
            phase = .failed
        case .idle, .monitoring, .cancelled:
            phase = .other
        }
        return CompactAudioImportPresentation.resolve(
            phase: phase,
            isImportingAudioFile: state.isImportingAudioFile,
            progress: state.audioImportProgress,
            preparationProgress: state.preparationProgress
        )
    }

    private var compactImportLayout: CompactAudioImportLayoutPolicy {
        .productionCompact
    }

    private var compactImportProgressMaxWidth: CGFloat {
        guard settings.panelSizePreset == .compact else { return 300 }
        return compactAudioImportPresentation.recordingLayout == .dedicatedImportProgress
            ? compactImportLayout.contentWidth : 190
    }

    private var compactImportProgressIndicatorHeight: CGFloat? {
        settings.panelSizePreset == .compact ? compactImportLayout.progressIndicatorHeight : nil
    }

    private var compactImportFallbackFont: Font {
        settings.panelSizePreset == .compact
            ? .system(size: compactImportLayout.fallbackFontSize) : .caption
    }

    private func compactImportProgressDetail(_ progress: AudioImportProgress) -> String {
        switch progress.stage {
        case .preparing: return "Preparing the selected recognizer"
        case .converting: return state.statusMessage
        case .analyzing: return "Detecting speech and building chunks"
        case .transcribing:
            guard progress.totalChunks > 0 else { return "Transcribing imported audio" }
            let current = min(max(progress.currentChunk, 1), progress.totalChunks)
            var detail = "Chunk \(current) of \(progress.totalChunks)"
            if let remaining = progress.estimatedRemainingDuration {
                detail += " · ~\(compactImportDuration(remaining)) left"
            } else {
                detail += " · estimating time"
            }
            return detail
        case .finalizing: return "Assembling the final transcript"
        case .cancelling: return "Cancelling transcription"
        }
    }

    private func compactImportDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 { return "\(max(1, seconds)) sec" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours)h \(remainder)m"
    }

    private var voiceGlowStrength: Double {
        guard state.phase == .listening else { return 0 }
        let level = Double(state.currentNormalizedLevel)
        return state.voiceActivityState == .speech
            ? min(max(level, 0.18), 1)
            : min(max(level * 0.34, 0.12), 0.28)
    }

    private var headerTitle: String {
        switch state.phase {
        case .preparing: return state.isImportingAudioFile ? "Importing" : "Waiting"
        case .listening: return "Recording"
        case .stopping, .finalizing: return "Processing"
        case .result:
            switch state.completionPresentation {
            case .noSpeech: return "No speech"
            case .partialIssue: return "Completed with issue"
            case .copied: return "Copied"
            default: return "Completed"
            }
        case .failed: return "Error"
        default: return state.statusMessage
        }
    }

    private var headerAccentColor: Color {
        switch state.phase {
        case .stopping, .finalizing: return .orange
        case .result: return resultTone
        case .failed: return .red
        default: return .primary
        }
    }

    private var indicatorColor: Color {
        switch state.phase {
        case .listening: return .red
        case .preparing, .stopping, .finalizing: return .orange
        case .result: return resultTone
        case .failed: return .red
        default: return .secondary
        }
    }

    private var resultTone: Color {
        switch state.completionPresentation {
        case .partialIssue: return .orange
        case .noSpeech, .tooShort: return .yellow
        default: return .green
        }
    }

    private var resultSymbol: String {
        switch state.completionPresentation {
        case .partialIssue: return "exclamationmark.triangle.fill"
        case .noSpeech: return "waveform.slash"
        case .tooShort: return "timer"
        default: return "checkmark.circle.fill"
        }
    }

    private var resultTitle: String {
        switch state.completionPresentation {
        case .copied: return "Copied to clipboard"
        case .partialIssue: return "Transcript completed with an issue"
        case .noSpeech: return "No speech recognized"
        case .tooShort: return "Recording too short"
        default:
            return state.recordingControlSource == .hotKeyHold
                ? "Copied to clipboard"
                : "Transcript ready"
        }
    }

    private var resultDetail: String {
        switch state.completionPresentation {
        case .partialIssue: return "You can review the partial result"
        case .noSpeech: return "Nothing was copied"
        case .tooShort: return "Record for at least 1 second"
        default:
            return usesManualRecordingControls
                ? "Review, copy, or close when you are done"
                : "The panel will close automatically"
        }
    }

    private var showsManualResultControls: Bool {
        switch state.completionPresentation {
        case .interactive, .partialIssue:
            return true
        case .copied:
            return usesManualRecordingControls
        default:
            return false
        }
    }

    private var showsTerminalWash: Bool {
        state.phase == .result || state.phase == .failed
    }

    private var isTerminalState: Bool {
        showsTerminalWash
    }

    private var canLatchHotKeyRecording: Bool {
        state.recordingControlSource == .hotKeyHold
            && (state.phase == .preparing || state.phase == .listening)
    }

    private var usesManualRecordingControls: Bool {
        state.recordingControlSource?.requiresManualStop == true
    }

    private var terminalColor: Color {
        state.phase == .failed ? .red : resultTone
    }

    private var borderColors: [Color] {
        switch state.phase {
        case .listening:
            return [.cyan.opacity(0.85), .indigo.opacity(0.75), .pink.opacity(0.80), .orange]
        case .preparing, .stopping, .finalizing:
            return [.orange.opacity(0.55), .yellow.opacity(0.95), .orange.opacity(0.62)]
        case .result:
            return [resultTone.opacity(0.65), resultTone, resultTone.opacity(0.70)]
        case .failed:
            return [.red.opacity(0.65), .red, .red.opacity(0.72)]
        default:
            return [.white.opacity(0.16), .white.opacity(0.28), .white.opacity(0.16)]
        }
    }

    private var placeholder: String {
        switch state.phase {
        case .preparing: return state.statusMessage
        case .listening: return "Recording — your transcript will appear here"
        default: return "Ready for a new recording"
        }
    }

    private var placeholderSymbol: String {
        state.phase == .preparing
            ? (state.isImportingAudioFile ? "waveform.badge.plus" : "hourglass")
            : "waveform"
    }

    private var multilineTranscriptText: String {
        state.phase == .result
            ? TranscriptTextNormalizer.normalize(String(state.editableText.suffix(1_200)))
            : state.transcriptPresentation.multilineText
    }

    private var hasPendingFeedback: Bool {
        pendingFeedbackIsVisible
    }

    private var pendingFeedbackItemCount: Int {
        displayedPendingFeedbackItemCount
    }

    private var pendingFeedbackItemExtent: Double {
        guard pendingFeedbackIsVisible else { return 0 }
        return min(
            Double(maximumPendingFeedbackItemCount),
            displayedPendingFeedbackItemExtent
        )
    }

    private var pendingFeedbackPresentation: PendingFeedbackPresentation {
        state.pendingFeedbackPresentation(
            maximumItemCount: maximumPendingFeedbackItemCount
        )
    }

    private var maximumPendingFeedbackItemCount: Int {
        switch settings.panelSizePreset {
        case .compact: return 3
        case .medium: return 6
        case .large: return 8
        }
    }

    @MainActor
    private func reconcilePendingFeedbackVisibility(hasUnresolvedWork: Bool) async {
        if hasUnresolvedWork {
            if pendingFeedbackIsVisible {
                displayedPendingFeedbackItemCount = max(1, pendingFeedbackPresentation.itemCount)
                displayedPendingFeedbackItemExtent = max(1, state.pendingFeedbackItemExtent)
                return
            }
            do {
                try await Task.sleep(
                    for: .seconds(PendingFeedbackTimingPolicy.appearanceDelay)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            displayedPendingFeedbackItemCount = max(1, pendingFeedbackPresentation.itemCount)
            displayedPendingFeedbackItemExtent = max(1, state.pendingFeedbackItemExtent)
            pendingFeedbackShownAt = Date()
            pendingFeedbackIsVisible = true
            return
        }

        guard pendingFeedbackIsVisible else {
            displayedPendingFeedbackItemCount = 0
            displayedPendingFeedbackItemExtent = 0
            pendingFeedbackShownAt = nil
            return
        }
        let elapsed = pendingFeedbackShownAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = PendingFeedbackTimingPolicy.remainingVisibleDuration(after: elapsed)
        if remaining > 0 {
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        pendingFeedbackIsVisible = false
        displayedPendingFeedbackItemCount = 0
        displayedPendingFeedbackItemExtent = 0
        pendingFeedbackShownAt = nil
    }

    private var panelHeight: CGFloat {
        settings.panelSizePreset.height
    }

    private var panelWindowHeight: CGFloat {
        panelHeight + AppSettings.PanelSizePreset.visualEffectInset * 2
    }

    private var waveformHeight: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return compactImportLayout.progressIndicatorHeight
        case .medium: return 24
        case .large: return 54
        }
    }

    private var transcriptFontSize: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return 14
        case .medium: return 16
        case .large: return 19
        }
    }

    private var terminalIconSize: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return 22
        case .medium: return 28
        case .large: return 40
        }
    }

    private var processingIconSize: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return 18
        case .medium: return 22
        case .large: return 32
        }
    }

    private var headerHeight: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return compactImportLayout.headerHeight
        case .medium: return 20
        case .large: return 26
        }
    }

    private var headerFontSize: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return 12
        case .medium: return 14
        case .large: return 15
        }
    }

    private var headerIndicatorSize: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return 16
        case .medium: return 18
        case .large: return 20
        }
    }

    private var headerTrailingIconSize: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return 12
        case .medium: return 14
        case .large: return 16
        }
    }

    private var headerSpacing: CGFloat {
        settings.panelSizePreset == .compact ? 6 : 9
    }

    private var transcriptRowHeight: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return compactImportLayout.transcriptRowHeight
        case .medium: return 38
        case .large: return 48
        }
    }

    private var resultButtonLabelHeight: CGFloat {
        settings.panelSizePreset == .medium ? 34 : 40
    }

    private var actionButtonSize: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return 30
        case .medium: return 36
        case .large: return 42
        }
    }

    private var actionIconSize: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return 12
        case .medium: return 14
        case .large: return 16
        }
    }

    private var actionButtonSpacing: CGFloat {
        settings.panelSizePreset == .compact ? 5 : 9
    }

    private var horizontalPadding: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return compactImportLayout.horizontalPadding
        case .medium: return 20
        case .large: return 24
        }
    }

    private var verticalPadding: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return compactImportLayout.verticalPadding
        case .medium: return 14
        case .large: return 22
        }
    }

    private var cornerRadius: CGFloat {
        switch settings.panelSizePreset {
        case .compact: return 22
        case .medium: return 25
        case .large: return 30
        }
    }

    private var formattedRecordingDuration: String {
        let totalSeconds = max(0, Int(state.recordingDuration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct PanelIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.15 : 0.075),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct PanelActionButtonStyle: ButtonStyle {
    let compact: Bool
    let prominent: Bool
    let tone: Color

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .medium, design: .rounded))
            .padding(.horizontal, compact ? 0 : 14)
            .frame(minWidth: compact ? 0 : 118)
            .foregroundStyle(.primary)
            .background(
                backgroundColor(isPressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(prominent ? 0.17 : 0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if prominent {
            return tone.opacity(isPressed ? 0.36 : 0.27)
        }
        return Color.white.opacity(isPressed ? 0.15 : 0.075)
    }
}

@MainActor
private final class PanelWindowDragCoordinator: ObservableObject {
    weak var window: NSWindow?
    private var initialOrigin: NSPoint?
    private var initialPointerLocation: NSPoint?

    func update() {
        guard let window else { return }
        let pointerLocation = NSEvent.mouseLocation
        if initialOrigin == nil || initialPointerLocation == nil {
            initialOrigin = window.frame.origin
            initialPointerLocation = pointerLocation
        }
        guard let initialOrigin, let initialPointerLocation else { return }
        window.setFrameOrigin(
            NSPoint(
                x: initialOrigin.x + pointerLocation.x - initialPointerLocation.x,
                y: initialOrigin.y + pointerLocation.y - initialPointerLocation.y
            )
        )
    }

    func end() {
        initialOrigin = nil
        initialPointerLocation = nil
    }
}

private struct PanelWindowReader: NSViewRepresentable {
    let coordinator: PanelWindowDragCoordinator

    func makeNSView(context: Context) -> WindowReadingView {
        WindowReadingView(coordinator: coordinator)
    }

    func updateNSView(_ nsView: WindowReadingView, context: Context) {
        nsView.coordinator = coordinator
        nsView.captureWindow()
    }

    final class WindowReadingView: NSView {
        weak var coordinator: PanelWindowDragCoordinator?

        init(coordinator: PanelWindowDragCoordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            captureWindow()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func captureWindow() {
            coordinator?.window = window
        }
    }
}

#if DEBUG
    @MainActor
    private struct CompactPanelPreviewHost: View {
        private let environment: VoicePanelPreviewEnvironment

        init(scenario: VoicePanelPreviewScenario, size: AppSettings.PanelSizePreset = .medium) {
            let environment = VoicePanelPreviewEnvironment(scenario: scenario)
            environment.settings.panelSizePreset = size
            self.environment = environment
        }

        var body: some View {
            CompactPanelView(
                state: environment.state,
                settings: environment.settings,
                onLatchHotKey: {},
                onStop: {},
                onCancel: {},
                onOpenTranscript: {},
                onImportAudioFile: { _ in },
                onCopy: {},
                onRetry: {},
                onClose: {}
            )
        }
    }

    @MainActor
    private struct PanelWindowReaderPreviewHost: View {
        @StateObject private var coordinator = PanelWindowDragCoordinator()

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                Text("Drag coordinator reader")
                    .foregroundStyle(.secondary)
                PanelWindowReader(coordinator: coordinator)
            }
            .frame(width: 280, height: 100)
            .padding()
        }
    }

    #Preview("Compact Panel · Listening") {
        CompactPanelPreviewHost(scenario: .listening)
    }

    #Preview("Compact Panel · Finalizing") {
        CompactPanelPreviewHost(scenario: .finalizing)
    }

    #Preview("Compact Panel · Result") {
        CompactPanelPreviewHost(scenario: .result)
    }

    #Preview("Compact Panel · Error") {
        CompactPanelPreviewHost(scenario: .failed)
    }

    #Preview("Panel Window Reader") {
        PanelWindowReaderPreviewHost()
    }
#endif
