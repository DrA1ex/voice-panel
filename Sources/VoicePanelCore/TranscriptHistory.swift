import Foundation

public struct TranscriptHistoryRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var text: String
    public var duration: TimeInterval
    public var languageIdentifier: String
    public var engineName: String
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        text: String,
        duration: TimeInterval,
        languageIdentifier: String,
        engineName: String,
        isPinned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = text
        self.duration = duration
        self.languageIdentifier = languageIdentifier
        self.engineName = engineName
        self.isPinned = isPinned
    }
}

public enum TranscriptHistoryMergePolicy {
    public static func merge(
        _ recordSets: [[TranscriptHistoryRecord]]
    ) -> [TranscriptHistoryRecord] {
        var merged: [UUID: TranscriptHistoryRecord] = [:]
        for record in recordSets.joined() {
            if let existing = merged[record.id], existing.updatedAt >= record.updatedAt {
                continue
            }
            merged[record.id] = record
        }
        return merged.values.sorted { $0.createdAt > $1.createdAt }
    }
}

public final class TranscriptHistoryRepository: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private struct FileFingerprint: Equatable {
        let byteCount: UInt64
        let modificationTime: TimeInterval
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let encryptionKey: Data?
    private var cachedRecords: [TranscriptHistoryRecord]?
    private var cachedFingerprint: FileFingerprint?
    private static let encryptedFileMagic = Data("VPH1".utf8)

    public init(fileURL: URL, encryptionKey: Data? = nil) {
        self.fileURL = fileURL
        self.encryptionKey = encryptionKey
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> [TranscriptHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    /// Clears the in-memory snapshot immediately. Normal loads also compare a
    /// lightweight file fingerprint so external atomic replacements are noticed.
    public func invalidateCache() {
        lock.lock()
        cachedRecords = nil
        cachedFingerprint = nil
        lock.unlock()
    }

    @discardableResult
    public func upsert(_ record: TranscriptHistoryRecord) throws -> [TranscriptHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }

        var records = try loadLocked()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            guard records[index] != record else { return records }
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.createdAt > $1.createdAt }
        try saveLocked(records)
        return records
    }

    @discardableResult
    public func remove(id: UUID) throws -> [TranscriptHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }

        var records = try loadLocked()
        let previousCount = records.count
        records.removeAll { $0.id == id }
        guard records.count != previousCount else { return records }
        try saveLocked(records)
        return records
    }

    @discardableResult
    public func removeAllUnpinned() throws -> [TranscriptHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }

        var records = try loadLocked()
        let previousCount = records.count
        records.removeAll { !$0.isPinned }
        guard records.count != previousCount else { return records }
        try saveLocked(records)
        return records
    }

    @discardableResult
    public func purgeExpired(before cutoff: Date) throws -> [TranscriptHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }

        var records = try loadLocked()
        let previousCount = records.count
        records.removeAll { !$0.isPinned && $0.createdAt < cutoff }
        guard records.count != previousCount else { return records }
        try saveLocked(records)
        return records
    }

    @discardableResult
    public func replaceAll(_ records: [TranscriptHistoryRecord]) throws -> [TranscriptHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        let existing = try loadLocked()
        guard existing != sorted else { return existing }
        try saveLocked(sorted)
        return sorted
    }

    @discardableResult
    public func removeAll() throws -> [TranscriptHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        cachedRecords = []
        cachedFingerprint = nil
        return []
    }

    private func loadLocked() throws -> [TranscriptHistoryRecord] {
        let fingerprint = fileFingerprint()
        if let cachedRecords, cachedFingerprint == fingerprint {
            return cachedRecords
        }
        guard fingerprint != nil else {
            cachedRecords = []
            cachedFingerprint = nil
            return []
        }
        let storedData = try Data(contentsOf: fileURL)
        guard !storedData.isEmpty else {
            cachedRecords = []
            cachedFingerprint = fileFingerprint()
            return []
        }
        let data = try decodedPayload(from: storedData)
        let records = try decoder.decode([TranscriptHistoryRecord].self, from: data)
            .sorted { $0.createdAt > $1.createdAt }
        cachedRecords = records
        cachedFingerprint = fileFingerprint() ?? fingerprint
        return records
    }

    private func saveLocked(_ records: [TranscriptHistoryRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encodedPayload(from: encoder.encode(records))
        try data.write(to: fileURL, options: [.atomic])
        cachedRecords = records
        cachedFingerprint = fileFingerprint()
    }

    private func fileFingerprint() -> FileFingerprint? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? NSNumber,
            let modificationDate = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return FileFingerprint(
            byteCount: size.uint64Value,
            modificationTime: modificationDate.timeIntervalSinceReferenceDate
        )
    }

    private func encodedPayload(from plaintext: Data) throws -> Data {
        guard let encryptionKey else { return plaintext }
        do {
            return Self.encryptedFileMagic + (try AESGCMCompat.seal(plaintext, key: encryptionKey))
        } catch {
            throw TranscriptHistoryRepositoryError.invalidEncryptedPayload
        }
    }

    private func decodedPayload(from storedData: Data) throws -> Data {
        guard storedData.starts(with: Self.encryptedFileMagic) else { return storedData }
        guard let encryptionKey else {
            throw TranscriptHistoryRepositoryError.missingEncryptionKey
        }
        do {
            let combined = Data(storedData.dropFirst(Self.encryptedFileMagic.count))
            return try AESGCMCompat.open(combined, key: encryptionKey)
        } catch {
            throw TranscriptHistoryRepositoryError.decryptionFailed
        }
    }
}

public enum TranscriptHistoryRepositoryError: LocalizedError {
    case invalidEncryptedPayload
    case missingEncryptionKey
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEncryptedPayload:
            return "Could not create the encrypted history payload."
        case .missingEncryptionKey:
            return "The history encryption key is unavailable."
        case .decryptionFailed:
            return "The encrypted transcript history could not be opened with this key."
        }
    }
}
