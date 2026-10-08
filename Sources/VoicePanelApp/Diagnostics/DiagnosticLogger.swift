import Foundation

struct ModelLoadBreadcrumb: Codable, Equatable, Sendable {
    let token: UUID
    let engine: String
    let modelID: String
    let startedAt: Date
    let modelPath: String
}

final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    let logsDirectory: URL
    let logFileURL: URL
    let previousRunWasUnclean: Bool
    let previousModelLoadBreadcrumb: ModelLoadBreadcrumb?

    private let queue = DispatchQueue(label: "io.github.dra1ex.voicepanel.diagnostics")
    private let fileManager = FileManager.default
    private let diagnosticsDirectory: URL
    private let runningSessionURL: URL
    private let modelLoadURL: URL
    private let maximumLogSize: UInt64 = 2 * 1024 * 1024
    private let retainedLogCount = 3
    private let timestampFormatter = ISO8601DateFormatter()
    private let synchronizationInterval = 16
    private var logHandle: FileHandle?
    private var currentLogSize: UInt64 = 0
    private var unsynchronizedWriteCount = 0

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        logsDirectory = home.appendingPathComponent("Library/Logs/VoicePanel", isDirectory: true)
        logFileURL = logsDirectory.appendingPathComponent("voicepanel.log")

        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        diagnosticsDirectory =
            support
            .appendingPathComponent("VoicePanel", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        runningSessionURL = diagnosticsDirectory.appendingPathComponent("running-session.json")
        modelLoadURL = diagnosticsDirectory.appendingPathComponent("model-load.json")

        previousRunWasUnclean = FileManager.default.fileExists(atPath: runningSessionURL.path)
        previousModelLoadBreadcrumb = Self.readBreadcrumb(from: modelLoadURL)

        try? FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: diagnosticsDirectory,
            withIntermediateDirectories: true
        )
        currentLogSize = Self.fileSize(at: logFileURL)
        writeReadmeIfNeeded()
    }

    deinit {
        try? logHandle?.synchronize()
        try? logHandle?.close()
    }

    func beginApplicationSession(version: String) {
        queue.sync {
            rotateIfNeeded()
            let payload: [String: String] = [
                "pid": String(ProcessInfo.processInfo.processIdentifier),
                "version": version,
                "startedAt": timestampFormatter.string(from: Date()),
            ]
            writeJSON(payload, to: runningSessionURL)
            append(
                level: "INFO",
                message: "Application session started",
                metadata: [
                    "version": version,
                    "previousRunUnclean": String(previousRunWasUnclean),
                ]
            )
            if let breadcrumb = previousModelLoadBreadcrumb {
                append(
                    level: "ERROR",
                    message: "Previous process ended during model load",
                    metadata: [
                        "engine": breadcrumb.engine,
                        "model": breadcrumb.modelID,
                    ]
                )
            }
        }
    }

    func finishApplicationSession() {
        queue.sync {
            append(level: "INFO", message: "Application session finished", metadata: [:])
            closeLogHandle(synchronize: true)
            try? fileManager.removeItem(at: runningSessionURL)
        }
    }

    @discardableResult
    func beginModelLoad(engine: String, modelID: String, modelURL: URL) -> UUID {
        queue.sync {
            let breadcrumb = ModelLoadBreadcrumb(
                token: UUID(),
                engine: engine,
                modelID: modelID,
                startedAt: Date(),
                modelPath: modelURL.path
            )
            if let data = try? JSONEncoder().encode(breadcrumb) {
                try? data.write(to: modelLoadURL, options: .atomic)
            }
            append(
                level: "INFO",
                message: "Model load started",
                metadata: ["engine": engine, "model": modelID]
            )
            return breadcrumb.token
        }
    }

    func endModelLoad(token: UUID, engine: String, modelID: String, result: String) {
        queue.sync {
            if Self.readBreadcrumb(from: modelLoadURL)?.token == token {
                try? fileManager.removeItem(at: modelLoadURL)
            }
            append(
                level: result == "ready" ? "INFO" : "ERROR",
                message: "Model load finished",
                metadata: [
                    "engine": engine,
                    "model": modelID,
                    "result": result,
                ]
            )
        }
    }

    func clearPreviousModelLoadBreadcrumb() {
        queue.sync {
            try? fileManager.removeItem(at: modelLoadURL)
            append(level: "INFO", message: "Model-load recovery marker cleared", metadata: [:])
        }
    }

    func info(_ message: String, metadata: [String: String] = [:]) {
        log(level: "INFO", message: message, metadata: metadata)
    }

    func warning(_ message: String, metadata: [String: String] = [:]) {
        log(level: "WARN", message: message, metadata: metadata)
    }

    func error(_ message: String, metadata: [String: String] = [:]) {
        log(level: "ERROR", message: message, metadata: metadata)
    }

    private func log(level: String, message: String, metadata: [String: String]) {
        queue.async { [self] in
            rotateIfNeeded()
            append(level: level, message: message, metadata: metadata)
        }
    }

    private func append(level: String, message: String, metadata: [String: String]) {
        let metadataText =
            metadata
            .sorted { $0.key < $1.key }
            .map { "\(sanitize($0.key))=\(sanitize($0.value))" }
            .joined(separator: " ")
        let suffix = metadataText.isEmpty ? "" : " \(metadataText)"
        let line = "\(timestampFormatter.string(from: Date())) [\(level)] \(sanitize(message))\(suffix)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            let handle = try writableLogHandle()
            try handle.write(contentsOf: data)
            currentLogSize += UInt64(data.count)
            unsynchronizedWriteCount += 1
            if level == "ERROR" || unsynchronizedWriteCount >= synchronizationInterval {
                try handle.synchronize()
                unsynchronizedWriteCount = 0
            }
        } catch {
            closeLogHandle(synchronize: false)
            // Diagnostics must never crash or block the application lifecycle.
        }
    }

    private func writableLogHandle() throws -> FileHandle {
        if let logHandle { return logHandle }
        if !fileManager.fileExists(atPath: logFileURL.path) {
            _ = fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logFileURL)
        try handle.seekToEnd()
        logHandle = handle
        return handle
    }

    private func closeLogHandle(synchronize: Bool) {
        guard let logHandle else { return }
        if synchronize {
            try? logHandle.synchronize()
        }
        try? logHandle.close()
        self.logHandle = nil
        unsynchronizedWriteCount = 0
    }

    private func rotateIfNeeded() {
        guard currentLogSize >= maximumLogSize else { return }
        closeLogHandle(synchronize: true)

        if retainedLogCount > 1 {
            for index in stride(from: retainedLogCount - 1, through: 1, by: -1) {
                let source = logsDirectory.appendingPathComponent("voicepanel.log.\(index)")
                let destination = logsDirectory.appendingPathComponent("voicepanel.log.\(index + 1)")
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                if fileManager.fileExists(atPath: source.path) {
                    try? fileManager.moveItem(at: source, to: destination)
                }
            }
        }

        let firstArchive = logsDirectory.appendingPathComponent("voicepanel.log.1")
        if fileManager.fileExists(atPath: firstArchive.path) {
            try? fileManager.removeItem(at: firstArchive)
        }
        if fileManager.fileExists(atPath: logFileURL.path) {
            try? fileManager.moveItem(at: logFileURL, to: firstArchive)
        }
        // A failed rotation must not make the logger believe that an oversized
        // active file is empty; otherwise it can grow by another full limit.
        currentLogSize = Self.fileSize(at: logFileURL)
    }

    private func writeReadmeIfNeeded() {
        let readme = logsDirectory.appendingPathComponent("README.txt")
        guard !fileManager.fileExists(atPath: readme.path) else { return }
        let text = """
            VoicePanel diagnostic logs

            These logs contain lifecycle, model, queue, timing, and error metadata.
            Voice audio and transcript contents are intentionally not logged.
            Native macOS crash reports may also appear in ~/Library/Logs/DiagnosticReports.
            """
        try? text.write(to: readme, atomically: true, encoding: .utf8)
    }

    private func writeJSON(_ value: [String: String], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static func readBreadcrumb(from url: URL) -> ModelLoadBreadcrumb? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelLoadBreadcrumb.self, from: data)
    }

    private static func fileSize(at url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
    }
}
