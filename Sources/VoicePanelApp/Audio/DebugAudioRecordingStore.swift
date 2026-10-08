import AVFoundation
import Foundation
import VoicePanelCore

/// Writes one continuous, VAD-independent microphone stream per recording session.
/// Work is serialized off the realtime audio callback and audio is normalized to
/// the same 16 kHz mono format accepted by the import and benchmark paths.
final class DebugAudioRecordingStore: @unchecked Sendable {
    static var recordingsDirectoryURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return
            base
            .appendingPathComponent("VoicePanel", isDirectory: true)
            .appendingPathComponent("Debug Recordings", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "dev.voicepanel.debug-audio-writer", qos: .utility)
    private var sessionName: String?
    private var activeSessionID: UUID?
    private var file: AVAudioFile?
    private var resampler = StreamingLinearAudioResampler(targetSampleRate: 16_000)

    func start(sessionID: UUID, startedAt: Date = Date()) {
        queue.async { [weak self] in
            guard let self else { return }
            self.file = nil
            self.resampler.reset()
            self.activeSessionID = sessionID
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            self.sessionName = "VoicePanel_\(formatter.string(from: startedAt))_\(sessionID.uuidString.prefix(8)).wav"
        }
    }

    func append(sessionID: UUID, samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        queue.async { [weak self] in
            guard let self,
                self.activeSessionID == sessionID,
                self.sessionName != nil
            else { return }
            let normalized = self.resampler.process(samples: samples, from: sampleRate)
            guard !normalized.isEmpty else { return }
            do {
                let file = try self.file ?? self.makeFile()
                self.file = file
                try Self.write(normalized, to: file)
            } catch {
                self.file = nil
                self.sessionName = nil
            }
        }
    }

    func finish(sessionID: UUID) {
        queue.async { [weak self] in
            guard self?.activeSessionID == sessionID else { return }
            self?.file = nil
            self?.sessionName = nil
            self?.activeSessionID = nil
            self?.resampler.reset()
        }
    }

    private func makeFile() throws -> AVAudioFile {
        guard let sessionName else { throw CocoaError(.fileNoSuchFile) }
        let directory = Self.recordingsDirectoryURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        return try AVAudioFile(
            forWriting: directory.appendingPathComponent(sessionName),
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    private static func write(_ samples: [Float], to file: AVAudioFile) throws {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            ), let channel = buffer.floatChannelData?[0]
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
