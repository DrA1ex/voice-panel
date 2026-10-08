import Combine
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@MainActor
final class SileroVADModelManager: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading
        case verifying
        case installed
        case failed(String)
    }

    static let downloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
    )!
    static let expectedSHA256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"

    @Published private(set) var state: State = .notInstalled

    private let fileManager: FileManager
    private let session: URLSession
    private let modelsDirectory: URL
    private var installationTask: Task<URL, Error>?

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        modelsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.session = session
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.modelsDirectory =
            modelsDirectory
            ?? support
            .appendingPathComponent("VoicePanel", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("VAD", isDirectory: true)
        refresh()
    }

    var modelURL: URL {
        modelsDirectory.appendingPathComponent("silero_vad.onnx")
    }

    var isInstalled: Bool {
        state == .installed && fileManager.fileExists(atPath: modelURL.path)
    }

    var statusText: String {
        switch state {
        case .notInstalled: return "Not installed · about 629 KB"
        case .downloading: return "Downloading Silero VAD…"
        case .verifying: return "Verifying Silero VAD…"
        case .installed: return "Installed · ready"
        case .failed(let message): return message
        }
    }

    func refresh() {
        state = hasValidInstalledModel ? .installed : .notInstalled
    }

    func ensureInstalled() async throws -> URL {
        if isInstalled || hasValidInstalledModel {
            state = .installed
            return modelURL
        }
        if let installationTask { return try await installationTask.value }

        let task = Task<URL, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            self.state = .downloading
            do {
                let (temporaryURL, response) = try await self.session.download(
                    from: Self.downloadURL
                )
                guard let response = response as? HTTPURLResponse,
                    (200..<300).contains(response.statusCode)
                else {
                    throw SileroVADModelError.downloadFailed
                }

                self.state = .verifying
                guard Self.sha256(of: temporaryURL) == Self.expectedSHA256 else {
                    throw SileroVADModelError.checksumMismatch
                }

                try self.fileManager.createDirectory(
                    at: self.modelsDirectory,
                    withIntermediateDirectories: true
                )
                let stagingURL = self.modelsDirectory.appendingPathComponent(
                    ".silero_vad-\(UUID().uuidString).onnx"
                )
                try? self.fileManager.removeItem(at: stagingURL)
                try self.fileManager.moveItem(at: temporaryURL, to: stagingURL)
                try? self.fileManager.removeItem(at: self.modelURL)
                try self.fileManager.moveItem(at: stagingURL, to: self.modelURL)
                self.state = .installed
                return self.modelURL
            } catch {
                self.state = .failed(error.localizedDescription)
                throw error
            }
        }
        installationTask = task
        defer { installationTask = nil }
        return try await task.value
    }

    func remove() throws {
        installationTask?.cancel()
        installationTask = nil
        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }
        state = .notInstalled
    }

    private var hasValidInstalledModel: Bool {
        guard fileManager.fileExists(atPath: modelURL.path) else { return false }
        return Self.sha256(of: modelURL) == Self.expectedSHA256
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SileroVADModelError: LocalizedError {
    case downloadFailed
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Silero VAD could not be downloaded."
        case .checksumMismatch:
            return "The downloaded Silero VAD model failed its integrity check."
        }
    }
}
