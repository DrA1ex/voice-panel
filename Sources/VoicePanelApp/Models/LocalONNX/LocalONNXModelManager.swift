import Combine
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum LocalONNXModelInstallState: Equatable {
    case notInstalled
    case downloading(Double)
    case verifying(Double)
    case installed
    case failed(String)
}

enum LocalONNXModelError: LocalizedError {
    case invalidDownload(String)
    case checksumMismatch(String)
    case missingIntegrityMetadata(String)
    case missingModel

    var errorDescription: String? {
        switch self {
        case .invalidDownload(let filename):
            return "The local ASR download did not produce a valid \(filename) file."
        case .checksumMismatch(let filename):
            return "The content checksum for \(filename) does not match the published model file."
        case .missingIntegrityMetadata(let filename):
            return "Hugging Face did not provide a content identity for \(filename)."
        case .missingModel:
            return "The selected local ASR model is not installed."
        }
    }
}

private enum LocalONNXRemoteDigest: Equatable, Sendable {
    case sha256(String)
    case gitBlobSHA1(String)
}

@MainActor
final class LocalONNXModelManager: ObservableObject {
    @Published private(set) var states: [LocalONNXModelID: LocalONNXModelInstallState] = [:]

    private let fileManager: FileManager
    private let modelsDirectory: URL
    private var installationTasks: [LocalONNXModelID: Task<LocalONNXInstalledPackage, Error>] = [:]
    #if DEBUG
        private var previewModelSizes: [LocalONNXModelID: Int64] = [:]
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
            .appendingPathComponent("LocalONNX", isDirectory: true)
        refresh()
    }

    func state(for model: LocalONNXModelID) -> LocalONNXModelInstallState {
        states[model] ?? .notInstalled
    }

    func packageDirectory(for model: LocalONNXModelID) -> URL {
        modelsDirectory.appendingPathComponent(model.rawValue, isDirectory: true)
    }

    func installedPackage(for model: LocalONNXModelID) -> LocalONNXInstalledPackage? {
        guard isInstalled(model) else { return nil }
        return LocalONNXInstalledPackage(model: model, directory: packageDirectory(for: model))
    }

    func isInstalled(_ model: LocalONNXModelID) -> Bool {
        if case .installed = state(for: model) { return true }
        return false
    }

    var installedModels: [LocalONNXModelID] {
        LocalONNXModelID.allCases.filter(isInstalled)
    }

    func installedSize(for model: LocalONNXModelID) -> Int64 {
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
        func configurePreview(installedModels: [LocalONNXModelID]) {
            states = Dictionary(
                uniqueKeysWithValues: LocalONNXModelID.allCases.map { model in
                    (model, installedModels.contains(model) ? .installed : .notInstalled)
                })
            previewModelSizes = Dictionary(
                uniqueKeysWithValues: installedModels.enumerated().map {
                    ($0.element, Int64(720_000_000 + $0.offset * 410_000_000))
                })
        }
    #endif

    func refresh() {
        for model in LocalONNXModelID.allCases {
            let directory = packageDirectory(for: model)
            let complete = model.files.allSatisfy { file in
                let url = directory.appendingPathComponent(file.relativePath)
                let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                return size >= file.minimumSize
            }
            states[model] = complete ? .installed : .notInstalled
        }
    }

    func ensureInstalled(_ model: LocalONNXModelID) async throws -> LocalONNXInstalledPackage {
        if let package = installedPackage(for: model) { return package }
        return try await install(model)
    }

    @discardableResult
    func install(_ model: LocalONNXModelID) async throws -> LocalONNXInstalledPackage {
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

    private func performInstall(_ model: LocalONNXModelID) async throws -> LocalONNXInstalledPackage {
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
            var downloadedDigests: [String: LocalONNXRemoteDigest] = [:]
            for file in model.files {
                try Task.checkCancellation()
                let target = staging.appendingPathComponent(file.relativePath)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let baseWeight = completedWeight
                let downloader = LocalONNXFileDownloadDelegate(destination: target) { [weak self] fileProgress in
                    let overall = (baseWeight + file.downloadWeight * fileProgress) / totalWeight
                    Task { @MainActor in self?.states[model] = .downloading(overall * 0.88) }
                }
                let sourceDigest = try await downloader.download(from: file.downloadURL)
                if let sourceDigest {
                    downloadedDigests[file.relativePath] = sourceDigest
                }
                guard fileManager.fileExists(atPath: target.path) else {
                    throw LocalONNXModelError.invalidDownload(file.relativePath)
                }
                completedWeight += file.downloadWeight
            }

            let fileCount = Double(model.files.count)
            for (index, file) in model.files.enumerated() {
                try Task.checkCancellation()
                states[model] = .verifying(0.88 + 0.12 * Double(index) / fileCount)
                let url = staging.appendingPathComponent(file.relativePath)
                switch file.integrity {
                case .pinnedSHA256(let expectedDigest):
                    let digest = try sha256(of: url)
                    guard digest.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
                        throw LocalONNXModelError.checksumMismatch(file.relativePath)
                    }

                case .huggingFaceContentAddressed:
                    guard let sourceDigest = downloadedDigests[file.relativePath] else {
                        throw LocalONNXModelError.missingIntegrityMetadata(file.relativePath)
                    }
                    let matches: Bool
                    switch sourceDigest {
                    case .sha256(let expectedDigest):
                        matches = try sha256(of: url).caseInsensitiveCompare(expectedDigest) == .orderedSame
                    case .gitBlobSHA1(let expectedDigest):
                        matches = try gitBlobSHA1(of: url).caseInsensitiveCompare(expectedDigest) == .orderedSame
                    }
                    guard matches else {
                        throw LocalONNXModelError.checksumMismatch(file.relativePath)
                    }
                }
            }

            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            states[model] = .installed
            return LocalONNXInstalledPackage(model: model, directory: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            states[model] = .failed(error.localizedDescription)
            throw error
        }
    }

    func remove(_ model: LocalONNXModelID) throws {
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

    private func gitBlobSHA1(of url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw LocalONNXModelError.invalidDownload(url.lastPathComponent)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size.int64Value)\0".utf8))
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class LocalONNXFileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalONNXRemoteDigest?, Error>?
    private var completionError: Error?
    private var didMoveFile = false
    private var sourceDigest: LocalONNXRemoteDigest?
    private var session: URLSession?

    init(destination: URL, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(from url: URL) async throws -> LocalONNXRemoteDigest? {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<LocalONNXRemoteDigest?, Error>) in
            lock.performLocked { self.continuation = continuation }
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForResource = 60 * 60 * 6
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
        if let response = downloadTask.response as? HTTPURLResponse {
            captureDigest(from: response)
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.performLocked { didMoveFile = true }
        } catch {
            lock.performLocked { completionError = error }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        captureDigest(from: response)
        completionHandler(request)
    }

    private func captureDigest(from response: HTTPURLResponse) {
        let linkedDigest = Self.contentDigest(
            from: response.value(forHTTPHeaderField: "X-Linked-Etag")
        )
        let responseDigest = Self.contentDigest(
            from: response.value(forHTTPHeaderField: "ETag")
        )
        guard let digest = linkedDigest ?? responseDigest else { return }
        lock.performLocked {
            if linkedDigest != nil || sourceDigest == nil {
                sourceDigest = digest
            }
        }
    }

    private static func contentDigest(from headerValue: String?) -> LocalONNXRemoteDigest? {
        guard let headerValue else { return nil }
        var normalized = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("W/") {
            normalized.removeFirst(2)
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        guard
            normalized.unicodeScalars.allSatisfy({ scalar in
                (48...57).contains(Int(scalar.value)) || (97...102).contains(Int(scalar.value))
            })
        else { return nil }
        switch normalized.count {
        case 64:
            return .sha256(normalized)
        case 40:
            return .gitBlobSHA1(normalized)
        default:
            return nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let snapshot = lock.performLocked {
            () -> (CheckedContinuation<LocalONNXRemoteDigest?, Error>?, Error?, Bool, LocalONNXRemoteDigest?) in
            let value = continuation
            continuation = nil
            return (value, completionError, didMoveFile, sourceDigest)
        }
        self.session?.finishTasksAndInvalidate()
        self.session = nil

        if let error {
            snapshot.0?.resume(throwing: error)
        } else if let completionError = snapshot.1 {
            snapshot.0?.resume(throwing: completionError)
        } else if snapshot.2 {
            snapshot.0?.resume(returning: snapshot.3)
        } else {
            snapshot.0?.resume(throwing: LocalONNXModelError.invalidDownload(destination.lastPathComponent))
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
