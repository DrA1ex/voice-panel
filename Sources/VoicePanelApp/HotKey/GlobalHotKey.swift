import Carbon

final class GlobalHotKey {
    private static weak var activeInstance: GlobalHotKey?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onPressed: (@MainActor () -> Void)?
    private var onReleased: (@MainActor () -> Void)?
    private var isPressed = false

    init() {
        Self.activeInstance = self
        installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(
        preset: AppSettings.HotKeyPreset,
        onPressed: @escaping @MainActor () -> Void,
        onReleased: @escaping @MainActor () -> Void
    ) {
        unregister()
        self.onPressed = onPressed
        self.onReleased = onReleased

        let mapping = Self.mapping(for: preset)
        let hotKeyID = EventHotKeyID(signature: OSType(0x5650_4E4C), id: 1)  // "VPNL"
        RegisterEventHotKey(
            mapping.keyCode,
            mapping.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        isPressed = false
    }

    private func installEventHandler() {
        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.id == 1 else { return noErr }

            let kind = GetEventKind(event)
            Task { @MainActor in
                guard let instance = GlobalHotKey.activeInstance else { return }
                switch kind {
                case UInt32(kEventHotKeyPressed):
                    guard !instance.isPressed else { return }
                    instance.isPressed = true
                    instance.onPressed?()
                case UInt32(kEventHotKeyReleased):
                    guard instance.isPressed else { return }
                    instance.isPressed = false
                    instance.onReleased?()
                default:
                    break
                }
            }
            return noErr
        }

        let status = eventTypes.withUnsafeBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                buffer.count,
                buffer.baseAddress,
                nil,
                &eventHandlerRef
            )
        }
        if status != noErr {
            assertionFailure("Failed to install global hot-key event handler: \(status)")
        }
    }

    private static func mapping(for preset: AppSettings.HotKeyPreset) -> (keyCode: UInt32, modifiers: UInt32) {
        switch preset {
        case .controlOptionSpace:
            return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .commandShiftSpace:
            return (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        case .controlShiftSpace:
            return (UInt32(kVK_Space), UInt32(controlKey | shiftKey))
        }
    }
}
