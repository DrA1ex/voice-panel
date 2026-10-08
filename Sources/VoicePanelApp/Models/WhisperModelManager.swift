import Combine
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum WhisperModelInstallState: Equatable {
    case notInstalled
    case downloading(Double)
    case verifying
    case installed
    case failed(String)
}

enum WhisperModelError: LocalizedError {
    case invalidDownload
    case checksumMismatch
    case missingModel
    case coreMLUnsupported
    case missingCoreMLEncoder
    case invalidCoreMLArchive

    var errorDescription: String? {
        switch self {
        case .invalidDownload:
            return "The Whisper model download did not produce a valid file."
        case .checksumMismatch:
            return "The Whisper download checksum does not match the published file. The download was removed."
        case .missingModel:
            return "The selected Whisper model is not installed."
        case .coreMLUnsupported:
            return "The selected Whisper model does not have a compatible Core ML encoder package."
        case .missingCoreMLEncoder:
            return "The required Core ML encoder is not installed. Load the model from Settings to download it."
        case .invalidCoreMLArchive:
            return "The Core ML encoder archive did not contain the expected compiled model."
        }
    }
}

struct WhisperPreparedRuntimeFiles: Sendable {
    let modelFileURL: URL
    let runtimeModelURL: URL
    let configuration: WhisperRuntimeConfiguration
}

@MainActor
final class WhisperModelManager: ObservableObject {
    @Published private(set) var states: [WhisperModelID: WhisperModelInstallState] = [:]
    @Published private(set) var coreMLStates: [WhisperCoreMLEncoderID: WhisperModelInstallState] = [:]

    private let fileManager: FileManager
    private let modelsDirectory: URL
    private let runtimeAliasesDirectory: URL
    private var installationTasks: [WhisperModelID: Task<URL, Error>] = [:]
    private var coreMLInstallationTasks: [WhisperCoreMLEncoderID: Task<URL, Error>] = [:]
    #if DEBUG
        private var previewModelSizes: [WhisperModelID: Int64] = [:]
        private var previewCoreMLSizes: [WhisperCoreMLEncoderID: Int64] = [:]
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
            .appendingPathComponent("Whisper", isDirectory: true)
        runtimeAliasesDirectory = self.modelsDirectory.appendingPathComponent(
            "RuntimeAliases",
            isDirectory: true
        )
        refresh()
    }

    func state(for model: WhisperModelID) -> WhisperModelInstallState {
        states[model] ?? .notInstalled
    }

    func coreMLState(for encoder: WhisperCoreMLEncoderID) -> WhisperModelInstallState {
        coreMLStates[encoder] ?? .notInstalled
    }

    func modelURL(for model: WhisperModelID) -> URL {
        modelsDirectory.appendingPathComponent(model.filename)
    }

    func coreMLEncoderURL(for encoder: WhisperCoreMLEncoderID) -> URL {
        modelsDirectory.appendingPathComponent(encoder.directoryFilename, isDirectory: true)
    }

    func isInstalled(_ model: WhisperModelID) -> Bool {
        if case .installed = state(for: model) { return true }
        return false
    }

    func isCoreMLEncoderInstalled(_ encoder: WhisperCoreMLEncoderID) -> Bool {
        if case .installed = coreMLState(for: encoder) { return true }
        return false
    }

    var installedModels: [WhisperModelID] {
        WhisperModelID.allCases.filter(isInstalled)
    }

    var installedCoreMLEncoders: [WhisperCoreMLEncoderID] {
        WhisperCoreMLEncoderID.allCases.filter(isCoreMLEncoderInstalled)
    }

    func installedSize(for model: WhisperModelID) -> Int64 {
        guard isInstalled(model) else { return 0 }
        #if DEBUG
            if let previewSize = previewModelSizes[model] { return previewSize }
        #endif
        return Self.itemSize(at: modelURL(for: model), fileManager: fileManager)
    }

    func installedCoreMLEncoderSize(for encoder: WhisperCoreMLEncoderID) -> Int64 {
        guard isCoreMLEncoderInstalled(encoder) else { return 0 }
        #if DEBUG
            if let previewSize = previewCoreMLSizes[encoder] { return previewSize }
        #endif
        return Self.itemSize(at: coreMLEncoderURL(for: encoder), fileManager: fileManager)
    }

    #if DEBUG
        func configurePreview(
            installedModels: [WhisperModelID],
            installedCoreMLEncoders: [WhisperCoreMLEncoderID] = []
        ) {
            states = Dictionary(
                uniqueKeysWithValues: WhisperModelID.allCases.map { model in
                    (model, installedModels.contains(model) ? .installed : .notInstalled)
                })
            coreMLStates = Dictionary(
                uniqueKeysWithValues: WhisperCoreMLEncoderID.allCases.map { encoder in
                    (encoder, installedCoreMLEncoders.contains(encoder) ? .installed : .notInstalled)
                })
            previewModelSizes = Dictionary(
                uniqueKeysWithValues: installedModels.enumerated().map {
                    ($0.element, Int64(148_000_000 + $0.offset * 92_000_000))
                })
            previewCoreMLSizes = Dictionary(
                uniqueKeysWithValues: installedCoreMLEncoders.enumerated().map {
                    ($0.element, Int64(74_000_000 + $0.offset * 38_000_000))
                })
        }
    #endif

    func refresh() {
        for model in WhisperModelID.allCases {
            let size = Self.itemSize(at: modelURL(for: model), fileManager: fileManager)
            states[model] = size >= model.minimumExpectedByteCount ? .installed : .notInstalled
        }
        for encoder in WhisperCoreMLEncoderID.allCases {
            var isDirectory: ObjCBool = false
            let path = coreMLEncoderURL(for: encoder).path
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            coreMLStates[encoder] = exists && isDirectory.boolValue ? .installed : .notInstalled
        }
    }

    func ensureInstalled(_ model: WhisperModelID) async throws -> URL {
        if isInstalled(model) {
            return modelURL(for: model)
        }
        return try await install(model)
    }

    @discardableResult
    func install(_ model: WhisperModelID) async throws -> URL {
        if let existingTask = installationTasks[model] {
            return try await existingTask.value
        }

        let task = Task { @MainActor [self] in
            try await performInstall(model)
        }
        installationTasks[model] = task

        do {
            let url = try await task.value
            installationTasks[model] = nil
            return url
        } catch {
            installationTasks[model] = nil
            throw error
        }
    }

    func ensureCoreMLEncoderInstalled(_ encoder: WhisperCoreMLEncoderID) async throws -> URL {
        if isCoreMLEncoderInstalled(encoder) {
            return coreMLEncoderURL(for: encoder)
        }
        return try await installCoreMLEncoder(encoder)
    }

    @discardableResult
    func installCoreMLEncoder(_ encoder: WhisperCoreMLEncoderID) async throws -> URL {
        if let existingTask = coreMLInstallationTasks[encoder] {
            return try await existingTask.value
        }

        let task = Task { @MainActor [self] in
            try await performCoreMLInstall(encoder)
        }
        coreMLInstallationTasks[encoder] = task

        do {
            let url = try await task.value
            coreMLInstallationTasks[encoder] = nil
            return url
        } catch {
            coreMLInstallationTasks[encoder] = nil
            throw error
        }
    }

    func prepareRuntimeFiles(
        for model: WhisperModelID,
        requestedConfiguration: WhisperRuntimeConfiguration,
        installIfNeeded: Bool
    ) async throws -> WhisperPreparedRuntimeFiles {
        let modelFileURL: URL
        if isInstalled(model) {
            modelFileURL = self.modelURL(for: model)
        } else if installIfNeeded {
            modelFileURL = try await ensureInstalled(model)
        } else {
            throw WhisperModelError.missingModel
        }

        let requestedMode = requestedConfiguration.requestedComputeMode
        let effectiveMode: WhisperComputeMode
        let runtimeModelURL: URL

        switch requestedMode {
        case .automatic:
            if let encoder = model.coreMLEncoder, isCoreMLEncoderInstalled(encoder) {
                effectiveMode = .coreMLMetal
                runtimeModelURL = modelFileURL
            } else {
                effectiveMode = .metal
                runtimeModelURL = try runtimeAliasURL(for: model, source: modelFileURL)
            }

        case .coreMLMetal, .coreMLCPU:
            guard let encoder = model.coreMLEncoder else {
                throw WhisperModelError.coreMLUnsupported
            }
            if !isCoreMLEncoderInstalled(encoder) {
                guard installIfNeeded else { throw WhisperModelError.missingCoreMLEncoder }
                _ = try await ensureCoreMLEncoderInstalled(encoder)
            }
            effectiveMode = requestedMode
            runtimeModelURL = modelFileURL

        case .metal, .cpu:
            effectiveMode = requestedMode
            runtimeModelURL = try runtimeAliasURL(for: model, source: modelFileURL)
        }

        return WhisperPreparedRuntimeFiles(
            modelFileURL: modelFileURL,
            runtimeModelURL: runtimeModelURL,
            configuration: WhisperRuntimeConfiguration(
                requestedComputeMode: requestedMode,
                effectiveComputeMode: effectiveMode,
                flashAttention: requestedConfiguration.flashAttention
            )
        )
    }

    private func performInstall(_ model: WhisperModelID) async throws -> URL {
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let destination = modelURL(for: model)
        let staging = modelsDirectory.appendingPathComponent(".\(model.filename).download")
        try? fileManager.removeItem(at: staging)
        states[model] = .downloading(0)

        do {
            let downloader = ModelDownloadDelegate(destination: staging) { [weak self] progress in
                Task { @MainActor in self?.states[model] = .downloading(progress) }
            }
            try await downloader.download(from: model.downloadURL)
            guard fileManager.fileExists(atPath: staging.path) else {
                throw WhisperModelError.invalidDownload
            }

            states[model] = .verifying
            let digest = try checksum(of: staging, checksum: model.expectedChecksum)
            guard digest.caseInsensitiveCompare(model.expectedChecksum.value) == .orderedSame else {
                try? fileManager.removeItem(at: staging)
                throw WhisperModelError.checksumMismatch
            }

            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            states[model] = .installed
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            states[model] = .failed(error.localizedDescription)
            throw error
        }
    }

    private func performCoreMLInstall(_ encoder: WhisperCoreMLEncoderID) async throws -> URL {
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let destination = coreMLEncoderURL(for: encoder)
        let archive = modelsDirectory.appendingPathComponent(".\(encoder.archiveFilename).download")
        let extraction = modelsDirectory.appendingPathComponent(
            ".\(encoder.rawValue)-coreml-extract", isDirectory: true)
        try? fileManager.removeItem(at: archive)
        try? fileManager.removeItem(at: extraction)
        coreMLStates[encoder] = .downloading(0)

        do {
            let downloader = ModelDownloadDelegate(destination: archive) { [weak self] progress in
                Task { @MainActor in self?.coreMLStates[encoder] = .downloading(progress) }
            }
            try await downloader.download(from: encoder.downloadURL)
            guard Self.itemSize(at: archive, fileManager: fileManager) >= encoder.archiveByteCount * 7 / 10 else {
                throw WhisperModelError.invalidDownload
            }

            coreMLStates[encoder] = .verifying
            let digest = try checksum(of: archive, checksum: .sha256(encoder.expectedSHA256))
            guard digest.caseInsensitiveCompare(encoder.expectedSHA256) == .orderedSame else {
                throw WhisperModelError.checksumMismatch
            }

            try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)
            try await Self.extractZip(archive: archive, destination: extraction)
            guard
                let extractedModel = Self.findDirectory(
                    named: encoder.directoryFilename,
                    below: extraction,
                    fileManager: fileManager
                )
            else {
                throw WhisperModelError.invalidCoreMLArchive
            }

            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: extractedModel, to: destination)
            try? fileManager.removeItem(at: archive)
            try? fileManager.removeItem(at: extraction)
            coreMLStates[encoder] = .installed
            return destination
        } catch {
            try? fileManager.removeItem(at: archive)
            try? fileManager.removeItem(at: extraction)
            coreMLStates[encoder] = .failed(error.localizedDescription)
            throw error
        }
    }

    func remove(_ model: WhisperModelID) throws {
        let url = modelURL(for: model)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try? fileManager.removeItem(at: runtimeAliasesDirectory.appendingPathComponent(model.filename))
        states[model] = .notInstalled
    }

    func removeCoreMLEncoder(_ encoder: WhisperCoreMLEncoderID) throws {
        let url = coreMLEncoderURL(for: encoder)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        coreMLStates[encoder] = .notInstalled
    }

    private func runtimeAliasURL(for model: WhisperModelID, source: URL) throws -> URL {
        try fileManager.createDirectory(at: runtimeAliasesDirectory, withIntermediateDirectories: true)
        let alias = runtimeAliasesDirectory.appendingPathComponent(model.filename)
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: alias.path),
            destination == source.path
        {
            return alias
        }
        try? fileManager.removeItem(at: alias)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: source)
        return alias
    }

    private func checksum(of url: URL, checksum: WhisperChecksum) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        switch checksum {
        case .sha1:
            var hasher = Insecure.SHA1()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()

        case .sha256:
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private nonisolated static func extractZip(archive: URL, destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, destination.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "ditto failed"
                throw NSError(
                    domain: "VoicePanel.WhisperCoreMLArchive",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }.value
    }

    private nonisolated static func findDirectory(
        named name: String,
        below root: URL,
        fileManager: FileManager
    ) -> URL? {
        if root.lastPathComponent == name { return root }
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == name,
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            {
                return url
            }
        }
        return nil
    }

    private nonisolated static func itemSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
            values.isDirectory != true
        {
            return Int64(values.fileSize ?? 0)
        }
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            if let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var didMoveFile = false
    private var session: URLSession?

    init(destination: URL, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(from url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.performLocked { self.continuation = continuation }
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
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
            lock.performLocked { moveError = error }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let snapshot = lock.performLocked { () -> (CheckedContinuation<Void, Error>?, Error?, Bool) in
            let continuation = self.continuation
            self.continuation = nil
            return (continuation, moveError, didMoveFile)
        }
        self.session?.finishTasksAndInvalidate()
        self.session = nil

        if let error {
            snapshot.0?.resume(throwing: error)
        } else if let moveError = snapshot.1 {
            snapshot.0?.resume(throwing: moveError)
        } else if snapshot.2 {
            snapshot.0?.resume()
        } else {
            snapshot.0?.resume(throwing: WhisperModelError.invalidDownload)
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
