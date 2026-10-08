import Foundation

enum VoicePanelUITestProgress {
    private static let lock = NSLock()

    static func report(_ message: String) {
        let rendered = "[VoicePanel UI] \(message)"
        print(rendered)

        guard let path = progressPath else { return }

        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            _ = fileManager.createFile(atPath: path, contents: nil)
        }

        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }

        do {
            _ = try handle.seekToEnd()
            if let data = "\(Date().timeIntervalSince1970) \(rendered)\n".data(using: .utf8) {
                try handle.write(contentsOf: data)
                try handle.synchronize()
            }
        } catch {
            print("[VoicePanel UI] Failed to write progress marker: \(error)")
        }
    }
    private static var progressPath: String? {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["VOICEPANEL_UI_TEST_PROGRESS_PATH"], !configured.isEmpty {
            return configured
        }

        let sourceFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot
            .appendingPathComponent(".build/ui-tests/VoicePanelUITests.progress.log")
            .path
    }

}
