import Foundation
import LocalAuthentication

@MainActor
final class HistoryAccessAuthenticator {
    private var context: LAContext?

    func authenticate() async throws {
        let context = LAContext()
        self.context = context
        defer {
            if self.context === context { self.context = nil }
        }
        context.localizedCancelTitle = "Keep History Locked"
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            throw availabilityError ?? HistoryAuthenticationError.unavailable
        }

        SystemPromptFocusCoordinator.willBegin()
        defer { SystemPromptFocusCoordinator.didEnd() }
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your encrypted VoicePanel transcript history"
            ) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? HistoryAuthenticationError.failed)
                }
            }
        }
    }

    func cancel() {
        context?.invalidate()
        context = nil
    }
}

private enum HistoryAuthenticationError: LocalizedError {
    case unavailable
    case failed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Touch ID or Mac login authentication is not available."
        case .failed:
            return "The encrypted transcript history could not be unlocked."
        }
    }
}
