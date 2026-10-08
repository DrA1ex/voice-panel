import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

struct DecodedAudioFile: Sendable {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

enum AudioFileDecoderError: LocalizedError {
    case noAudioTrack
    case unsupportedFormat
    case readerCouldNotStart
    case decodingFailed(String)
    case emptyAudio
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The selected file does not contain an audio track."
        case .unsupportedFormat:
            return "This audio format could not be converted to 16 kHz mono PCM."
        case .readerCouldNotStart:
            return "VoicePanel could not start reading the selected audio file."
        case .decodingFailed(let message):
            return "Audio conversion failed: \(message)"
        case .emptyAudio:
            return "The selected file contains no usable audio."
        case .noSpeechDetected:
            return "No speech was detected in the selected audio file."
        }
    }
}

enum AudioFileDecoder {
    static let outputSampleRate: Double = 16_000

    static func decode(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DecodedAudioFile {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw AudioFileDecoderError.noAudioTrack }

            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: outputSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw AudioFileDecoderError.unsupportedFormat }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error.map { AudioFileDecoderError.decodingFailed($0.localizedDescription) }
                    ?? AudioFileDecoderError.readerCouldNotStart
            }

            let durationSeconds = max(CMTimeGetSeconds(duration), 0)
            var samples: [Float] = []
            var lastReportedPercent = -1
            if durationSeconds.isFinite, durationSeconds > 0 {
                samples.reserveCapacity(Int(durationSeconds * outputSampleRate))
            }

            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                guard byteCount > 0 else { continue }

                var bytes = Data(count: byteCount)
                let status = bytes.withUnsafeMutableBytes { rawBuffer -> OSStatus in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return -1
                    }
                    return CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: byteCount,
                        destination: baseAddress
                    )
                }
                guard status == kCMBlockBufferNoErr else {
                    throw AudioFileDecoderError.decodingFailed("Could not read PCM samples.")
                }

                bytes.withUnsafeBytes { rawBuffer in
                    let floatBuffer = rawBuffer.bindMemory(to: Float.self)
                    samples.append(contentsOf: floatBuffer)
                }

                if durationSeconds > 0, durationSeconds.isFinite {
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let currentSeconds = max(CMTimeGetSeconds(timestamp), 0)
                    let normalizedProgress = min(max(currentSeconds / durationSeconds, 0), 1)
                    let percent = Int((normalizedProgress * 100).rounded(.down))
                    // The UI renders integer percentages. Emitting once per
                    // decoded sample buffer can enqueue thousands of main-actor
                    // tasks for long files without presenting any extra detail.
                    if percent != lastReportedPercent {
                        lastReportedPercent = percent
                        progress(normalizedProgress)
                    }
                }
            }

            guard reader.status == .completed else {
                throw reader.error.map { AudioFileDecoderError.decodingFailed($0.localizedDescription) }
                    ?? AudioFileDecoderError.decodingFailed("The reader stopped before reaching the end of the file.")
            }
            guard !samples.isEmpty else { throw AudioFileDecoderError.emptyAudio }
            if lastReportedPercent < 100 {
                progress(1)
            }
            return DecodedAudioFile(samples: samples, sampleRate: outputSampleRate)
        }.value
    }
}
