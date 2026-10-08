import Foundation

public struct TranscriptHistoryRecoveryArchive: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let keyIdentifier: String
    public let fileName: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        keyIdentifier: String,
        fileName: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.keyIdentifier = keyIdentifier
        self.fileName = fileName
    }
}

public struct TranscriptHistoryRecoveryArchiveStore: Sendable {
    private let directoryURL: URL
    private let manifestURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        manifestURL = directoryURL.appendingPathComponent("archives.json")
    }

    public func archives() throws -> [TranscriptHistoryRecoveryArchive] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let data = try Data(contentsOf: manifestURL)
        guard !data.isEmpty else { return [] }
        return try decoder.decode([TranscriptHistoryRecoveryArchive].self, from: data)
            .filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func archive(
        fileAt sourceURL: URL,
        keyIdentifier: String,
        now: Date = Date()
    ) throws -> TranscriptHistoryRecoveryArchive? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let id = UUID()
        let archive = TranscriptHistoryRecoveryArchive(
            id: id,
            createdAt: now,
            keyIdentifier: keyIdentifier,
            fileName: "history-\(id.uuidString.lowercased()).archive"
        )
        let destinationURL = fileURL(for: archive)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

        do {
            var updatedArchives = try archives()
            updatedArchives.append(archive)
            try save(updatedArchives)
            return archive
        } catch {
            try? FileManager.default.moveItem(at: destinationURL, to: sourceURL)
            throw error
        }
    }

    public func fileURL(for archive: TranscriptHistoryRecoveryArchive) -> URL {
        directoryURL.appendingPathComponent((archive.fileName as NSString).lastPathComponent)
    }

    public func remove(_ archive: TranscriptHistoryRecoveryArchive) throws {
        let archivedFileURL = fileURL(for: archive)
        if FileManager.default.fileExists(atPath: archivedFileURL.path) {
            try FileManager.default.removeItem(at: archivedFileURL)
        }
        try save(try archives().filter { $0.id != archive.id })
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
    }

    private func save(_ archives: [TranscriptHistoryRecoveryArchive]) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(archives).write(to: manifestURL, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
