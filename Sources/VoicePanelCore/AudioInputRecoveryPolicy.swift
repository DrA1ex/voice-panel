import Foundation

public enum AudioInputTopologyChange: Equatable, Sendable {
    case defaultInputChanged
    case deviceListChanged
}

public struct AudioInputRecoveryDecision: Equatable, Sendable {
    public let persistedSelection: UInt32
    public let reconnectSelection: UInt32?
    public let usesSystemFallback: Bool
    public let shouldReconnect: Bool

    public init(
        persistedSelection: UInt32,
        reconnectSelection: UInt32?,
        usesSystemFallback: Bool,
        shouldReconnect: Bool
    ) {
        self.persistedSelection = persistedSelection
        self.reconnectSelection = reconnectSelection
        self.usesSystemFallback = usesSystemFallback
        self.shouldReconnect = shouldReconnect
    }
}

public enum AudioInputRecoveryPolicy {
    /// Resolves a persisted input preference after Core Audio reports a topology
    /// change. A zero selection means "follow the system default".
    public static func decision(
        preferredSelection: UInt32,
        availableDeviceIDs: Set<UInt32>,
        defaultDeviceID: UInt32?,
        currentRequestedSelection: UInt32?,
        currentResolvedDeviceID: UInt32?,
        hasActiveSession: Bool,
        isCapturing: Bool,
        change: AudioInputTopologyChange
    ) -> AudioInputRecoveryDecision {
        let preferredIsAvailable =
            preferredSelection == 0 || availableDeviceIDs.contains(preferredSelection)
        let persistedSelection = preferredIsAvailable ? preferredSelection : 0
        let usesSystemFallback = preferredSelection != 0 && persistedSelection == 0

        guard hasActiveSession else {
            return AudioInputRecoveryDecision(
                persistedSelection: persistedSelection,
                reconnectSelection: nil,
                usesSystemFallback: usesSystemFallback,
                shouldReconnect: false
            )
        }

        let resolvedTarget =
            persistedSelection == 0 ? defaultDeviceID : persistedSelection
        guard resolvedTarget != nil else {
            return AudioInputRecoveryDecision(
                persistedSelection: persistedSelection,
                reconnectSelection: nil,
                usesSystemFallback: usesSystemFallback,
                shouldReconnect: false
            )
        }

        let currentResolvedStillExists = currentResolvedDeviceID.map(availableDeviceIDs.contains) ?? false
        let requestedSelectionChanged = currentRequestedSelection != persistedSelection
        let resolvedSelectionChanged = currentResolvedDeviceID != resolvedTarget
        let topologyRequiresRebind: Bool
        switch change {
        case .deviceListChanged:
            // AVAudioEngine can stop delivering input after an unrelated device
            // is attached or removed even when its selected device survives.
            topologyRequiresRebind = true
        case .defaultInputChanged:
            topologyRequiresRebind = persistedSelection == 0
        }

        return AudioInputRecoveryDecision(
            persistedSelection: persistedSelection,
            reconnectSelection: persistedSelection,
            usesSystemFallback: usesSystemFallback,
            shouldReconnect: !isCapturing
                || !currentResolvedStillExists
                || requestedSelectionChanged
                || resolvedSelectionChanged
                || topologyRequiresRebind
        )
    }
}
