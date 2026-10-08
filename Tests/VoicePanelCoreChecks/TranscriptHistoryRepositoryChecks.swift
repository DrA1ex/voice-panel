import Foundation
import VoicePanelCore

let transcriptHistoryRepositoryChecks: [CheckCase] = [
    CheckCase(name: "History upsert persists and updates a record") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = TranscriptHistoryRepository(
            fileURL: directory.appendingPathComponent("history.json")
        )
        var record = TranscriptHistoryRecord(
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            text: "First",
            duration: 2,
            languageIdentifier: "ru-RU",
            engineName: "Apple Speech"
        )

        try repository.upsert(record)
        record.text = "Updated"
        record.updatedAt = Date(timeIntervalSince1970: 110)
        try repository.upsert(record)

        let loaded = try repository.load()
        try expectEqual(loaded.count, 1)
        try expectEqual(loaded[0].text, "Updated")
    },

    CheckCase(name: "History purge keeps pinned records") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = TranscriptHistoryRepository(
            fileURL: directory.appendingPathComponent("history.json")
        )
        let oldDate = Date(timeIntervalSince1970: 100)
        let unpinned = TranscriptHistoryRecord(
            createdAt: oldDate,
            updatedAt: oldDate,
            text: "Expired",
            duration: 1,
            languageIdentifier: "ru-RU",
            engineName: "Apple Speech"
        )
        let pinned = TranscriptHistoryRecord(
            createdAt: oldDate,
            updatedAt: oldDate,
            text: "Pinned",
            duration: 1,
            languageIdentifier: "ru-RU",
            engineName: "Apple Speech",
            isPinned: true
        )

        try repository.upsert(unpinned)
        try repository.upsert(pinned)
        let remaining = try repository.purgeExpired(before: Date(timeIntervalSince1970: 200))

        try expectEqual(remaining.map(\.text), ["Pinned"])
    },

    CheckCase(name: "Encrypted history never writes transcript plaintext") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("history.enc")
        let key = Data((0..<32).map(UInt8.init))
        let repository = TranscriptHistoryRepository(fileURL: fileURL, encryptionKey: key)
        let secretText = "private transcript marker"
        let record = TranscriptHistoryRecord(
            text: secretText,
            duration: 2,
            languageIdentifier: "en-US",
            engineName: "Test"
        )

        try repository.upsert(record)
        let storedData = try Data(contentsOf: fileURL)
        try expect(storedData.starts(with: Data("VPH1".utf8)), "encrypted history header is missing")
        try expect(
            !storedData.contains(Data(secretText.utf8)),
            "encrypted history must not contain transcript plaintext"
        )
        let decryptedRecords = try repository.load()
        try expectEqual(decryptedRecords.count, 1)
        try expectEqual(decryptedRecords[0].id, record.id)
        try expectEqual(decryptedRecords[0].text, secretText)

        let wrongKeyRepository = TranscriptHistoryRepository(
            fileURL: fileURL,
            encryptionKey: Data(repeating: 0xFF, count: 32)
        )
        var rejectedWrongKey = false
        do {
            _ = try wrongKeyRepository.load()
        } catch {
            rejectedWrongKey = true
        }
        try expect(rejectedWrongKey, "history unexpectedly decrypted with a different key")
    },

    CheckCase(name: "Encrypted history can be erased without its previous key") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("history.enc")
        let originalRepository = TranscriptHistoryRepository(
            fileURL: fileURL,
            encryptionKey: Data(repeating: 0x11, count: 32)
        )
        try originalRepository.upsert(
            TranscriptHistoryRecord(
                text: "old encrypted transcript",
                duration: 1,
                languageIdentifier: "en-US",
                engineName: "Test"
            )
        )

        let replacementRepository = TranscriptHistoryRepository(
            fileURL: fileURL,
            encryptionKey: Data(repeating: 0x22, count: 32)
        )
        try replacementRepository.removeAll()
        let replacementRecords = try replacementRepository.load()
        try expectEqual(replacementRecords, [])
    },

    CheckCase(name: "History reset archives the encrypted file with its key identifier") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("history.enc")
        let archiveStore = TranscriptHistoryRecoveryArchiveStore(
            directoryURL: directory.appendingPathComponent("Recovery", isDirectory: true)
        )
        let encryptedBytes = Data("VPH1-encrypted-payload".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encryptedBytes.write(to: sourceURL)

        let archive = try archiveStore.archive(
            fileAt: sourceURL,
            keyIdentifier: "legacy-v1",
            now: Date(timeIntervalSince1970: 500)
        )
        try expect(archive != nil, "existing encrypted history was not archived")
        try expect(
            !FileManager.default.fileExists(atPath: sourceURL.path),
            "active history file remained after archival"
        )
        var archives = try archiveStore.archives()
        try expectEqual(archives.count, 1)
        try expectEqual(archives[0].keyIdentifier, "legacy-v1")
        let archivedBytes = try Data(contentsOf: archiveStore.fileURL(for: archives[0]))
        try expectEqual(archivedBytes, encryptedBytes)

        try Data("VPH1-newer-encrypted-payload".utf8).write(to: sourceURL)
        _ = try archiveStore.archive(
            fileAt: sourceURL,
            keyIdentifier: "rotated-key-id",
            now: Date(timeIntervalSince1970: 600)
        )
        archives = try archiveStore.archives()
        try expectEqual(archives.count, 2)
        try expect(
            archives.contains(where: { $0.keyIdentifier == "legacy-v1" })
                && archives.contains(where: { $0.keyIdentifier == "rotated-key-id" }),
            "a later key rotation replaced an earlier recovery reference"
        )

        for archive in archives {
            try archiveStore.remove(archive)
        }
        let remainingArchives = try archiveStore.archives()
        try expectEqual(remainingArchives, [])
    },

    CheckCase(name: "Recovered history merges without replacing newer current edits") {
        let sharedID = UUID()
        let current = TranscriptHistoryRecord(
            id: sharedID,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300),
            text: "current edit",
            duration: 1,
            languageIdentifier: "en-US",
            engineName: "Current"
        )
        let olderRecoveredCopy = TranscriptHistoryRecord(
            id: sharedID,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            text: "older recovered edit",
            duration: 1,
            languageIdentifier: "en-US",
            engineName: "Previous"
        )
        let recoveredOnly = TranscriptHistoryRecord(
            createdAt: Date(timeIntervalSince1970: 400),
            updatedAt: Date(timeIntervalSince1970: 400),
            text: "recovered transcript",
            duration: 2,
            languageIdentifier: "ru-RU",
            engineName: "Previous"
        )

        let merged = TranscriptHistoryMergePolicy.merge([
            [current],
            [olderRecoveredCopy, recoveredOnly],
        ])
        try expectEqual(merged.count, 2)
        try expectEqual(merged.first(where: { $0.id == sharedID })?.text, "current edit")
        try expect(merged.contains(where: { $0.id == recoveredOnly.id }), "recovered record is missing")
    },
    CheckCase(name: "History cache notices an external atomic replacement") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("history.json")
        let firstRepository = TranscriptHistoryRepository(fileURL: fileURL)
        let secondRepository = TranscriptHistoryRepository(fileURL: fileURL)
        try firstRepository.upsert(
            TranscriptHistoryRecord(
                text: "First",
                duration: 1,
                languageIdentifier: "en-US",
                engineName: "Test"
            )
        )
        _ = try firstRepository.load()
        try secondRepository.upsert(
            TranscriptHistoryRecord(
                text: "Second",
                duration: 1,
                languageIdentifier: "en-US",
                engineName: "Test"
            )
        )

        let reloadedCount = try firstRepository.load().count
        try expectEqual(reloadedCount, 2)

        try FileManager.default.removeItem(at: fileURL)
        let countAfterExternalRemoval = try firstRepository.load().count
        try expectEqual(countAfterExternalRemoval, 0)
    },

]
