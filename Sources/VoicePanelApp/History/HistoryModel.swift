import Combine
import Foundation
import VoicePanelCore

@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var records: [TranscriptHistoryRecord] = []
    @Published var searchText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var isUnlocked = false
    @Published private(set) var isUnlocking = false
    @Published private(set) var isRecoveringHistory = false
    @Published private(set) var recoverableArchiveCount = 0
    @Published private(set) var canStartNewEncryptedHistory = false

    private var repository: TranscriptHistoryRepository?
    private let settings: AppSettings
    private let authenticator: HistoryAccessAuthenticator
    private let legacyFileURL: URL
    private let activeKeyIdentifierFileURL: URL
    private let recoveryArchiveStore: TranscriptHistoryRecoveryArchiveStore
    private var activeKeyIdentifier: String
    private var cancellables = Set<AnyCancellable>()
    private var unlockGeneration = UUID()
    private var allowsAutomaticRepositoryAccess = true

    private static let plaintextLegacyArchiveIdentifier = "plaintext-legacy-v0"

    init(
        settings: AppSettings,
        repository: TranscriptHistoryRepository? = nil,
        authenticator: HistoryAccessAuthenticator? = nil
    ) {
        self.settings = settings
        self.authenticator = authenticator ?? HistoryAccessAuthenticator()
        legacyFileURL = Self.applicationSupportDirectory().appendingPathComponent("history.json")
        activeKeyIdentifierFileURL = Self.defaultActiveKeyIdentifierFileURL()
        activeKeyIdentifier = Self.loadActiveKeyIdentifier(from: activeKeyIdentifierFileURL)
        recoveryArchiveStore = TranscriptHistoryRecoveryArchiveStore(
            directoryURL: Self.defaultRecoveryDirectoryURL()
        )

        if let repository {
            self.repository = repository
        } else {
            self.repository = nil
            do {
                let openedRepository = try Self.openRepository(
                    keyIdentifier: activeKeyIdentifier,
                    allowsInteraction: false
                )
                self.repository = openedRepository
            } catch {
                allowsAutomaticRepositoryAccess = false
            }
        }
        try? persistActiveKeyIdentifier(activeKeyIdentifier)

        if settings.historyStorageMode == .encrypted {
            migrateLegacyHistoryIfNeeded()
            applyRetentionPolicy()
        } else {
            removeAllStoredHistory()
        }
        refreshRecoverableArchiveCount()

        configureObservers()
    }

    #if DEBUG
        init(
            previewSettings settings: AppSettings,
            records: [TranscriptHistoryRecord] = [],
            isUnlocked: Bool = true
        ) {
            self.settings = settings
            authenticator = HistoryAccessAuthenticator()

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoicePanel-Preview-History-\(UUID().uuidString)", isDirectory: true)
            legacyFileURL = directory.appendingPathComponent("history.json")
            activeKeyIdentifierFileURL = directory.appendingPathComponent("history.key-id")
            recoveryArchiveStore = TranscriptHistoryRecoveryArchiveStore(
                directoryURL: directory.appendingPathComponent("History Recovery", isDirectory: true)
            )
            activeKeyIdentifier = "preview-history-key"

            let repository = TranscriptHistoryRepository(
                fileURL: directory.appendingPathComponent("history.enc"),
                encryptionKey: Data(repeating: 0x42, count: 32)
            )
            self.repository = repository
            _ = try? repository.replaceAll(records)
            self.records = records.sorted { $0.createdAt > $1.createdAt }
            self.isUnlocked = isUnlocked
        }

        init(uiTestSettings settings: AppSettings, directoryURL: URL) {
            self.settings = settings
            authenticator = HistoryAccessAuthenticator()

            try? FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            legacyFileURL = directoryURL.appendingPathComponent("history.json")
            activeKeyIdentifierFileURL = directoryURL.appendingPathComponent("history.key-id")
            recoveryArchiveStore = TranscriptHistoryRecoveryArchiveStore(
                directoryURL: directoryURL.appendingPathComponent("History Recovery", isDirectory: true)
            )
            activeKeyIdentifier = "00000000-0000-0000-0000-000000000001"

            let repository = TranscriptHistoryRepository(
                fileURL: directoryURL.appendingPathComponent("history.enc"),
                encryptionKey: Self.loadOrCreateUITestEncryptionKey(in: directoryURL)
            )
            self.repository = repository
            isUnlocked = settings.historyStorageMode == .encrypted

            if settings.historyStorageMode == .encrypted {
                migrateLegacyHistoryIfNeeded()
                applyRetentionPolicy()
            } else {
                removeAllStoredHistory()
            }
            refreshRecoverableArchiveCount()
            configureObservers()
        }
    #endif

    var storageEnabled: Bool {
        settings.historyStorageMode == .encrypted
    }

    var canResetEncryptedHistory: Bool {
        storageEnabled && !isUnlocked && !isUnlocking && canStartNewEncryptedHistory
    }

    var canRecoverPreviousHistory: Bool {
        storageEnabled && recoverableArchiveCount > 0
    }

    var filteredRecords: [TranscriptHistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || $0.languageIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    func unlock() async {
        guard storageEnabled, !isUnlocked, !isUnlocking else { return }
        isUnlocking = true
        allowsAutomaticRepositoryAccess = false
        canStartNewEncryptedHistory = false
        lastError = nil
        let currentUnlockGeneration = UUID()
        unlockGeneration = currentUnlockGeneration
        defer { isUnlocking = false }

        do {
            try await authenticator.authenticate()
        } catch {
            guard unlockGeneration == currentUnlockGeneration, storageEnabled else { return }
            lock()
            lastError = error.localizedDescription
            return
        }

        guard unlockGeneration == currentUnlockGeneration, storageEnabled else { return }

        do {
            let repository: TranscriptHistoryRepository
            if let existingRepository = self.repository {
                repository = existingRepository
            } else {
                repository = try Self.openRepository(
                    keyIdentifier: activeKeyIdentifier,
                    allowsInteraction: true
                )
                self.repository = repository
            }
            migrateLegacyHistoryIfNeeded()
            records = try retainedRecordsForCurrentPolicy(repository: repository)
            isUnlocked = true
            allowsAutomaticRepositoryAccess = true
            canStartNewEncryptedHistory = false
            lastError = nil
        } catch {
            lock()
            allowsAutomaticRepositoryAccess = false
            canStartNewEncryptedHistory = true
            lastError =
                "The encrypted history could not be opened after authentication: "
                + error.localizedDescription
        }
    }

    func lock() {
        unlockGeneration = UUID()
        authenticator.cancel()
        repository?.invalidateCache()
        records = []
        searchText = ""
        isUnlocked = false
    }

    @discardableResult
    func upsert(_ record: TranscriptHistoryRecord) -> Bool {
        guard storageEnabled else { return false }
        do {
            let repository = try repositoryForWrite()
            defer {
                if !isUnlocked {
                    repository.invalidateCache()
                }
            }
            let updatedRecords = try repository.upsert(record)
            if isUnlocked { records = updatedRecords }
            lastError = nil
            applyRetentionPolicy()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func updateText(id: UUID, text: String) {
        guard storageEnabled, let repository else { return }
        defer {
            if !isUnlocked {
                repository.invalidateCache()
            }
        }
        do {
            let existing: TranscriptHistoryRecord?
            if let unlockedRecord = records.first(where: { $0.id == id }) {
                existing = unlockedRecord
            } else {
                existing = try repository.load().first(where: { $0.id == id })
            }
            guard var updated = existing else { return }
            updated.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.updatedAt = Date()
            let updatedRecords = try repository.upsert(updated)
            if isUnlocked { records = updatedRecords }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func togglePinned(id: UUID) {
        guard isUnlocked, let repository,
            var updated = records.first(where: { $0.id == id })
        else { return }
        updated.isPinned.toggle()
        updated.updatedAt = Date()
        do {
            records = try repository.upsert(updated)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(id: UUID) {
        guard isUnlocked, let repository else { return }
        do {
            records = try repository.remove(id: id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearUnpinned() {
        guard isUnlocked, let repository else { return }
        do {
            records = try repository.removeAllUnpinned()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resetEncryptedHistory() {
        guard storageEnabled else { return }
        lock()
        repository = nil

        do {
            let encryptedFileURL = Self.defaultEncryptedFileURL()
            _ = try recoveryArchiveStore.archive(
                fileAt: encryptedFileURL,
                keyIdentifier: activeKeyIdentifier
            )
            _ = try recoveryArchiveStore.archive(
                fileAt: legacyFileURL,
                keyIdentifier: Self.plaintextLegacyArchiveIdentifier
            )

            let rotation = HistoryEncryptionKeyStore.rotated()
            let key = try rotation.keyStore.loadOrCreateKey()
            try persistActiveKeyIdentifier(rotation.identifier)
            activeKeyIdentifier = rotation.identifier
            repository = TranscriptHistoryRepository(
                fileURL: encryptedFileURL,
                encryptionKey: key
            )
            records = []
            searchText = ""
            isUnlocked = true
            allowsAutomaticRepositoryAccess = true
            canStartNewEncryptedHistory = false
            lastError = nil
            refreshRecoverableArchiveCount()
        } catch {
            canStartNewEncryptedHistory = true
            lastError =
                "A new encrypted history store could not be created: "
                + error.localizedDescription
            refreshRecoverableArchiveCount()
        }
    }

    func recoverPreviousHistory() async {
        guard storageEnabled, !isRecoveringHistory else { return }
        isRecoveringHistory = true
        defer {
            isRecoveringHistory = false
            refreshRecoverableArchiveCount()
        }

        if !isUnlocked {
            await unlock()
        }
        guard isUnlocked, let repository else { return }

        do {
            let archives = try recoveryArchiveStore.archives()
            var recordSets = [try repository.load()]
            var recoveredArchives: [TranscriptHistoryRecoveryArchive] = []
            var recoveryFailures: [String] = []

            for archive in archives {
                do {
                    let archiveRepository = TranscriptHistoryRepository(
                        fileURL: recoveryArchiveStore.fileURL(for: archive),
                        encryptionKey: try recoveryKey(for: archive)
                    )
                    recordSets.append(try archiveRepository.load())
                    recoveredArchives.append(archive)
                } catch {
                    recoveryFailures.append(error.localizedDescription)
                }
            }

            guard !recoveredArchives.isEmpty else {
                lastError = recoveryFailures.first.map {
                    "Previous history remains archived: \($0)"
                }
                return
            }

            _ = try repository.replaceAll(TranscriptHistoryMergePolicy.merge(recordSets))
            records = try retainedRecordsForCurrentPolicy(repository: repository)
            for archive in recoveredArchives {
                try recoveryArchiveStore.remove(archive)
            }
            if recoveryFailures.isEmpty {
                lastError = nil
            } else {
                lastError =
                    "Recovered \(recoveredArchives.count) previous history archive(s). "
                    + "\(recoveryFailures.count) archive(s) remain unavailable."
            }
        } catch {
            lastError = "Previous history could not be recovered: \(error.localizedDescription)"
        }
    }

    func applyRetentionPolicy(now: Date = Date()) {
        guard storageEnabled else {
            removeAllStoredHistory()
            return
        }
        guard let repository else { return }
        defer {
            if !isUnlocked {
                repository.invalidateCache()
            }
        }
        do {
            let retainedRecords = try retainedRecordsForCurrentPolicy(now: now, repository: repository)
            if isUnlocked { records = retainedRecords }
            lastError = nil
        } catch {
            if isUnlocked { records = [] }
            lastError = error.localizedDescription
        }
    }

    private func configureObservers() {
        settings.$historyStorageMode
            .dropFirst()
            .sink { [weak self] mode in self?.storageModeDidChange(mode) }
            .store(in: &cancellables)

        settings.$historyRetentionPreset
            .dropFirst()
            .sink { [weak self] _ in self?.applyRetentionPolicy() }
            .store(in: &cancellables)

        Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.applyRetentionPolicy() }
            .store(in: &cancellables)
    }

    #if DEBUG
        private static func loadOrCreateUITestEncryptionKey(in directoryURL: URL) -> Data {
            let keyURL = directoryURL.appendingPathComponent("history.test-key")
            if let existing = try? Data(contentsOf: keyURL), existing.count == 32 {
                return existing
            }

            let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            try? key.write(to: keyURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyURL.path
            )
            return key
        }
    #endif

    private func repositoryForWrite() throws -> TranscriptHistoryRepository {
        if let repository { return repository }
        guard allowsAutomaticRepositoryAccess else {
            throw HistoryAutomaticAccessError.requiresExplicitUnlock
        }
        do {
            let opened = try Self.openRepository(
                keyIdentifier: activeKeyIdentifier,
                allowsInteraction: false
            )
            repository = opened
            migrateLegacyHistoryIfNeeded()
            return opened
        } catch {
            allowsAutomaticRepositoryAccess = false
            throw error
        }
    }

    private func storageModeDidChange(_ mode: AppSettings.HistoryStorageMode) {
        switch mode {
        case .none:
            removeAllStoredHistory()
        case .encrypted:
            lock()
            allowsAutomaticRepositoryAccess = true
            migrateLegacyHistoryIfNeeded()
            applyRetentionPolicy()
        }
    }

    private func retainedRecordsForCurrentPolicy(
        now: Date = Date(),
        repository explicitRepository: TranscriptHistoryRepository? = nil
    ) throws -> [TranscriptHistoryRecord] {
        guard let repository = explicitRepository ?? repository else { return [] }
        switch settings.historyRetentionPreset {
        case .forever:
            return try repository.load()
        default:
            guard let interval = settings.historyRetentionPreset.retentionInterval else {
                return try repository.load()
            }
            return try repository.purgeExpired(before: now.addingTimeInterval(-interval))
        }
    }

    private func recoveryKey(for archive: TranscriptHistoryRecoveryArchive) throws -> Data? {
        guard archive.keyIdentifier != Self.plaintextLegacyArchiveIdentifier else { return nil }
        SystemPromptFocusCoordinator.willBegin()
        defer { SystemPromptFocusCoordinator.didEnd() }
        return try HistoryEncryptionKeyStore.forIdentifier(archive.keyIdentifier).loadExistingKey()
    }

    private func refreshRecoverableArchiveCount() {
        recoverableArchiveCount = (try? recoveryArchiveStore.archives().count) ?? 0
    }

    private func persistActiveKeyIdentifier(_ identifier: String) throws {
        let directoryURL = activeKeyIdentifierFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data(identifier.utf8).write(to: activeKeyIdentifierFileURL, options: .atomic)
        HistoryEncryptionKeyStore.activate(identifier)
    }

    private func migrateLegacyHistoryIfNeeded() {
        guard let repository,
            FileManager.default.fileExists(atPath: legacyFileURL.path)
        else { return }
        do {
            let legacyRepository = TranscriptHistoryRepository(fileURL: legacyFileURL)
            let legacyRecords = try legacyRepository.load()
            let encryptedRecords = try repository.load()
            var merged = Dictionary(uniqueKeysWithValues: encryptedRecords.map { ($0.id, $0) })
            for record in legacyRecords where merged[record.id] == nil {
                merged[record.id] = record
            }
            _ = try repository.replaceAll(Array(merged.values))
            try FileManager.default.removeItem(at: legacyFileURL)
            lastError = nil
        } catch {
            lastError = "Could not migrate the previous transcript history: \(error.localizedDescription)"
        }
    }

    private func removeAllStoredHistory() {
        lock()
        do {
            let encryptedFileURL = Self.defaultEncryptedFileURL()
            if let repository {
                _ = try repository.removeAll()
            } else if FileManager.default.fileExists(atPath: encryptedFileURL.path) {
                try FileManager.default.removeItem(at: encryptedFileURL)
            }
            try recoveryArchiveStore.removeAll()
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                try FileManager.default.removeItem(at: legacyFileURL)
            }
            canStartNewEncryptedHistory = false
            lastError = nil
            recoverableArchiveCount = 0
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func openRepository(
        keyIdentifier: String,
        allowsInteraction: Bool
    ) throws -> TranscriptHistoryRepository {
        let encryptedFileURL = defaultEncryptedFileURL()
        let keyStore = HistoryEncryptionKeyStore.forIdentifier(keyIdentifier)
        let encryptionKey: Data
        if FileManager.default.fileExists(atPath: encryptedFileURL.path) {
            encryptionKey = try keyStore.loadExistingKey(allowsInteraction: allowsInteraction)
        } else {
            encryptionKey = try keyStore.loadOrCreateKey(allowsInteraction: allowsInteraction)
        }
        return TranscriptHistoryRepository(
            fileURL: encryptedFileURL,
            encryptionKey: encryptionKey
        )
    }

    private static func applicationSupportDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VoicePanel", isDirectory: true)
    }

    private static func defaultEncryptedFileURL() -> URL {
        applicationSupportDirectory().appendingPathComponent("history.enc")
    }

    private static func defaultRecoveryDirectoryURL() -> URL {
        applicationSupportDirectory().appendingPathComponent("History Recovery", isDirectory: true)
    }

    private static func defaultActiveKeyIdentifierFileURL() -> URL {
        applicationSupportDirectory().appendingPathComponent("history.key-id")
    }

    private static func loadActiveKeyIdentifier(from fileURL: URL) -> String {
        if let data = try? Data(contentsOf: fileURL),
            let identifier = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            HistoryEncryptionKeyStore.isValidIdentifier(identifier)
        {
            return identifier
        }
        return HistoryEncryptionKeyStore.activeIdentifier()
    }
}

private enum HistoryAutomaticAccessError: LocalizedError {
    case requiresExplicitUnlock

    var errorDescription: String? {
        "History remains locked. Unlock it explicitly to resume encrypted storage."
    }
}
