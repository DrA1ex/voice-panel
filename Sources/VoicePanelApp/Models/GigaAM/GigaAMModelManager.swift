import Combine
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum GigaAMModelInstallState: Equatable {
    case notInstalled
    case downloading(Double)
    case verifying(Double)
    case installed
    case failed(String)
}

enum GigaAMModelError: LocalizedError {
    case invalidDownload(String)
    case checksumMismatch(String)
    case missingModel

    var errorDescription: String? {
        switch self {
        case .invalidDownload(let filename):
            return "The GigaAM download did not produce a valid \(filename) file."
        case .checksumMismatch(let filename):
            return "The SHA-256 checksum for \(filename) does not match the published model file."
        case .missingModel:
            return "The selected GigaAM model is not installed."
        }
    }
}

@MainActor
final class GigaAMModelManager: ObservableObject {
    @Published private(set) var states: [GigaAMModelID: GigaAMModelInstallState] = [:]

    private let fileManager: FileManager
    private let modelsDirectory: URL
    private var installationTasks: [GigaAMModelID: Task<GigaAMInstalledPackage, Error>] = [:]
    #if DEBUG
        private var previewModelSizes: [GigaAMModelID: Int64] = [:]
    #endif

    init(
        fileManager: FileManager = .default,
        modelsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.modelsDirectory =
            modelsDirectory
            ?? support
            .appendingPathComponent("VoicePanel", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("GigaAM", isDirectory: true)
        refresh()
    }

    func state(for model: GigaAMModelID) -> GigaAMModelInstallState {
        states[model] ?? .notInstalled
    }

    func packageDirectory(for model: GigaAMModelID) -> URL {
        modelsDirectory.appendingPathComponent(model.rawValue, isDirectory: true)
    }

    func installedPackage(for model: GigaAMModelID) -> GigaAMInstalledPackage? {
        guard isInstalled(model) else { return nil }
        return GigaAMInstalledPackage(model: model, directory: packageDirectory(for: model))
    }

    func isInstalled(_ model: GigaAMModelID) -> Bool {
        if case .installed = state(for: model) { return true }
        return false
    }

    var installedModels: [GigaAMModelID] {
        GigaAMModelID.allCases.filter(isInstalled)
    }

    func installedSize(for model: GigaAMModelID) -> Int64 {
        guard isInstalled(model) else { return 0 }
        #if DEBUG
            if let previewSize = previewModelSizes[model] { return previewSize }
        #endif
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard
            let enumerator = fileManager.enumerator(
                at: packageDirectory(for: model),
                includingPropertiesForKeys: keys
            )
        else { return 0 }
        return enumerator.reduce(into: Int64(0)) { total, element in
            guard
                let url = element as? URL,
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { return }
            total += Int64(values.fileSize ?? 0)
        }
    }

    #if DEBUG
        func configurePreview(installedModels: [GigaAMModelID]) {
            states = Dictionary(
                uniqueKeysWithValues: GigaAMModelID.allCases.map { model in
                    (model, installedModels.contains(model) ? .installed : .notInstalled)
                })
            previewModelSizes = Dictionary(
                uniqueKeysWithValues: installedModels.enumerated().map {
                    ($0.element, Int64(510_000_000 + $0.offset * 180_000_000))
                })
        }
    #endif

    func refresh() {
        for model in GigaAMModelID.allCases {
            let directory = packageDirectory(for: model)
            let complete = model.files.allSatisfy { file in
                let url = directory.appendingPathComponent(file.filename)
                let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                return size > (file.role == .tokens ? 16 : 1_000_000)
            }
            states[model] = complete ? .installed : .notInstalled
        }
    }

    func ensureInstalled(_ model: GigaAMModelID) async throws -> GigaAMInstalledPackage {
        if let package = installedPackage(for: model) { return package }
        return try await install(model)
    }

    @discardableResult
    func install(_ model: GigaAMModelID) async throws -> GigaAMInstalledPackage {
        if let existingTask = installationTasks[model] {
            return try await existingTask.value
        }

        let task = Task { @MainActor [self] in
            try await performInstall(model)
        }
        installationTasks[model] = task
        defer { installationTasks[model] = nil }
        return try await task.value
    }

    private func performInstall(_ model: GigaAMModelID) async throws -> GigaAMInstalledPackage {
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
                let downloader = GigaAMFileDownloadDelegate(destination: target) { [weak self] fileProgress in
                    let overall = (baseWeight + file.downloadWeight * fileProgress) / totalWeight
                    Task { @MainActor in self?.states[model] = .downloading(overall * 0.88) }
                }
                try await downloader.download(from: file.downloadURL)
                guard fileManager.fileExists(atPath: target.path) else {
                    throw GigaAMModelError.invalidDownload(file.filename)
                }
                completedWeight += file.downloadWeight
            }

            let fileCount = Double(model.files.count)
            for (index, file) in model.files.enumerated() {
                try Task.checkCancellation()
                states[model] = .verifying(0.88 + 0.12 * Double(index) / fileCount)
                let url = staging.appendingPathComponent(file.filename)
                let digest = try sha256(of: url)
                guard digest.caseInsensitiveCompare(file.sha256) == .orderedSame else {
                    throw GigaAMModelError.checksumMismatch(file.filename)
                }
            }

            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            states[model] = .installed
            return GigaAMInstalledPackage(model: model, directory: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            states[model] = .failed(error.localizedDescription)
            throw error
        }
    }

    func remove(_ model: GigaAMModelID) throws {
        let directory = packageDirectory(for: model)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        states[model] = .notInstalled
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

private final class GigaAMFileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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
            lock.performLocked { self.continuation = continuation }
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

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.performLocked { didMoveFile = true }
        } catch {
            lock.performLocked { completionError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let snapshot = lock.performLocked { () -> (CheckedContinuation<Void, Error>?, Error?, Bool) in
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
            snapshot.0?.resume(throwing: GigaAMModelError.invalidDownload(destination.lastPathComponent))
        }
    }
}

extension NSLock {
    fileprivate func performLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
