import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
}

struct AudioInputDeviceSnapshot: Sendable {
    let devices: [AudioInputDevice]
    let defaultDeviceID: AudioDeviceID?

    var availableDeviceIDs: Set<UInt32> {
        Set(devices.map { UInt32($0.id) })
    }
}

enum AudioInputDeviceChangeEvent: Equatable, Sendable {
    case defaultInputChanged(AudioDeviceID?)
    case deviceListChanged
}

extension Notification.Name {
    static let voicePanelAudioInputDevicesDidChange = Notification.Name(
        "VoicePanelAudioInputDevicesDidChange"
    )
}

enum AudioInputDeviceManager {
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ) == noErr
        else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &deviceIDs
            ) == noErr
        else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard inputChannelCount(for: deviceID) > 0 else { return nil }
            return AudioInputDevice(id: deviceID, name: deviceName(for: deviceID) ?? "Input \(deviceID)")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    static func snapshot() -> AudioInputDeviceSnapshot {
        AudioInputDeviceSnapshot(
            devices: inputDevices(),
            defaultDeviceID: defaultInputDeviceID()
        )
    }

    static func isInputDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        inputDevices().contains(where: { $0.id == deviceID })
    }

    static func resolveInputDeviceID(_ requestedDeviceID: AudioDeviceID) throws -> AudioDeviceID {
        if requestedDeviceID != 0 {
            guard isInputDeviceAvailable(requestedDeviceID) else {
                throw AudioCaptureError.inputDeviceUnavailable(requestedDeviceID)
            }
            return requestedDeviceID
        }
        guard let defaultDeviceID = defaultInputDeviceID(),
            isInputDeviceAvailable(defaultDeviceID)
        else {
            throw AudioCaptureError.noDefaultInputDevice
        }
        return defaultDeviceID
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        return status == noErr ? name as String : nil
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        guard
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                rawPointer
            ) == noErr
        else {
            return 0
        }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + $1.mNumberChannels }
    }
}

final class AudioInputDeviceMonitor: @unchecked Sendable {
    var onChange: ((AudioInputDeviceChangeEvent) -> Void)?

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let queue = DispatchQueue.main
    private var defaultAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var observesDefault = false
    private var observesDevices = false

    private lazy var defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.publish(.defaultInputChanged(AudioInputDeviceManager.defaultInputDeviceID()))
    }
    private lazy var devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.publish(.deviceListChanged)
    }

    deinit {
        stop()
    }

    func start() {
        guard !observesDefault, !observesDevices else { return }
        observesDefault =
            AudioObjectAddPropertyListenerBlock(
                systemObject,
                &defaultAddress,
                queue,
                defaultListener
            ) == noErr
        observesDevices =
            AudioObjectAddPropertyListenerBlock(
                systemObject,
                &devicesAddress,
                queue,
                devicesListener
            ) == noErr
    }

    func stop() {
        if observesDefault {
            AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &defaultAddress,
                queue,
                defaultListener
            )
            observesDefault = false
        }
        if observesDevices {
            AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &devicesAddress,
                queue,
                devicesListener
            )
            observesDevices = false
        }
    }

    private func publish(_ event: AudioInputDeviceChangeEvent) {
        onChange?(event)
        NotificationCenter.default.post(
            name: .voicePanelAudioInputDevicesDidChange,
            object: nil
        )
    }
}
