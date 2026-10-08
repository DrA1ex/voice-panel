import Combine
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum RussianCorrectionModelInstallState: Equatable {
    case notInstalled
    case downloading(Double)
    case verifying(Double)
    case installed
    case failed(String)
}

enum RussianCorrectionModelError: LocalizedError {
    case invalidDownload(String)
    case checksumMismatch(String)
    case invalidTokenizer(String)
    case missingModel

    var errorDescription: String? {
        switch self {
        case .invalidDownload(let filename):
            return "The Russian correction download did not produce a valid \(filename) file."
        case .checksumMismatch(let filename):
            return "The SHA-256 checksum for \(filename) does not match the published model file."
        case .invalidTokenizer(let filename):
            return "The Russian correction tokenizer file \(filename) is invalid."
        case .missingModel:
            return "The Russian correction model is not installed."
        }
    }
}

@MainActor
final class RussianCorrectionModelManager: ObservableObject {
    @Published private(set) var states: [RussianCorrectionModelID: RussianCorrectionModelInstallState] = [:]

    private let fileManager: FileManager
    private let modelsDirectory: URL
    private var installationTasks: [RussianCorrectionModelID: Task<RussianCorrectionInstalledPackage, Error>] = [:]

    init(fileManager: FileManager = .default, modelsDirectory: URL? = nil) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.modelsDirectory =
            modelsDirectory
            ?? support
            .appendingPathComponent("VoicePanel", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("TextCorrection", isDirectory: true)
        refresh()
    }

    func state(for model: RussianCorrectionModelID) -> RussianCorrectionModelInstallState {
        states[model] ?? .notInstalled
    }

    func packageDirectory(for model: RussianCorrectionModelID) -> URL {
        modelsDirectory.appendingPathComponent(model.rawValue, isDirectory: true)
    }

    func installedPackage(for model: RussianCorrectionModelID) -> RussianCorrectionInstalledPackage? {
        guard isInstalled(model) else { return nil }
        return RussianCorrectionInstalledPackage(model: model, directory: packageDirectory(for: model))
    }

    func isInstalled(_ model: RussianCorrectionModelID) -> Bool {
        if case .installed = state(for: model) { return true }
        return false
    }

    func installedSize(for model: RussianCorrectionModelID) -> Int64 {
        guard isInstalled(model) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard
            let enumerator = fileManager.enumerator(
                at: packageDirectory(for: model),
                includingPropertiesForKeys: Array(keys)
            )
        else { return 0 }
        return enumerator.reduce(into: Int64(0)) { total, element in
            guard
                let url = element as? URL,
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { return }
            total += Int64(values.fileSize ?? 0)
        }
    }

    func refresh() {
        for model in RussianCorrectionModelID.allCases {
            let directory = packageDirectory(for: model)
            let complete = model.files.allSatisfy { file in
                let url = directory.appendingPathComponent(file.filename)
                let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                return size >= file.minimumSize
            }
            states[model] = complete ? .installed : .notInstalled
        }
    }

    func ensureInstalled(_ model: RussianCorrectionModelID) async throws -> RussianCorrectionInstalledPackage {
        if let package = installedPackage(for: model) { return package }
        return try await install(model)
    }

    @discardableResult
    func install(_ model: RussianCorrectionModelID) async throws -> RussianCorrectionInstalledPackage {
        if let existing = installationTasks[model] { return try await existing.value }
        let task = Task { @MainActor [self] in try await performInstall(model) }
        installationTasks[model] = task
        defer { installationTasks[model] = nil }
        return try await task.value
    }

    func remove(_ model: RussianCorrectionModelID) throws {
        installationTasks[model]?.cancel()
        installationTasks[model] = nil
        let directory = packageDirectory(for: model)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        states[model] = .notInstalled
    }

    private func performInstall(_ model: RussianCorrectionModelID) async throws -> RussianCorrectionInstalledPackage {
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let destination = packageDirectory(for: model)
        let staging = modelsDirectory.appendingPathComponent(
            ".\(model.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        states[model] = .downloading(0)

        do {
            let totalWeight = model.files.reduce(0) { $0 + $1.downloadWeight }
            var completedWeight = 0.0
            for file in model.files {
                try Task.checkCancellation()
                let target = staging.appendingPathComponent(file.filename)
                let baseWeight = completedWeight
                let downloader = RussianCorrectionFileDownloadDelegate(destination: target) { [weak self] progress in
                    let overall = (baseWeight + file.downloadWeight * progress) / totalWeight
                    Task { @MainActor in self?.states[model] = .downloading(overall * 0.90) }
                }
                try await downloader.download(from: file.downloadURL)
                let size = (try? fileManager.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size >= file.minimumSize else {
                    throw RussianCorrectionModelError.invalidDownload(file.filename)
                }
                completedWeight += file.downloadWeight
            }

            let verifiable = model.files.filter { $0.sha256 != nil }
            for (index, file) in verifiable.enumerated() {
                try Task.checkCancellation()
                states[model] = .verifying(0.90 + 0.10 * Double(index) / Double(max(1, verifiable.count)))
                let digest = try sha256(of: staging.appendingPathComponent(file.filename))
                guard digest.caseInsensitiveCompare(file.sha256!) == .orderedSame else {
                    throw RussianCorrectionModelError.checksumMismatch(file.filename)
                }
            }
            try validateTokenizer(in: staging, model: model)

            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            states[model] = .installed
            return RussianCorrectionInstalledPackage(model: model, directory: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            states[model] = .failed(error.localizedDescription)
            throw error
        }
    }

    private func validateTokenizer(in directory: URL, model: RussianCorrectionModelID) throws {
        guard let vocabFile = model.files.first(where: { $0.role == .vocabulary }) else { return }
        let data = try Data(contentsOf: directory.appendingPathComponent(vocabFile.filename))
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any], dictionary.count > 40_000
        else {
            throw RussianCorrectionModelError.invalidTokenizer(vocabFile.filename)
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class RussianCorrectionFileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completionError: Error?
    private var didMoveFile = false
    private var session: URLSession?

    init(destination: URL, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(from url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withRussianCorrectionLock { self.continuation = continuation }
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForResource = 60 * 60 * 4
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withRussianCorrectionLock { didMoveFile = true }
        } catch {
            lock.withRussianCorrectionLock { completionError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let snapshot = lock.withRussianCorrectionLock { () -> (CheckedContinuation<Void, Error>?, Error?, Bool) in
            let value = continuation
            continuation = nil
            return (value, completionError, didMoveFile)
        }
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        if let error {
            snapshot.0?.resume(throwing: error)
        } else if let completionError = snapshot.1 {
            snapshot.0?.resume(throwing: completionError)
        } else if snapshot.2 {
            snapshot.0?.resume()
        } else {
            snapshot.0?.resume(throwing: RussianCorrectionModelError.invalidDownload(destination.lastPathComponent))
        }
    }
}

extension NSLock {
    fileprivate func withRussianCorrectionLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
