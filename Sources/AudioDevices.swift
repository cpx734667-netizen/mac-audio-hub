import Foundation
import CoreAudio
import AppKit

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isBluetooth: Bool

    var idString: String { String(id) }

    var latencyHint: String {
        if isBluetooth { return "蓝牙输出，延迟较高" }
        if isBuiltIn { return "低延迟" }
        return "外接输出"
    }
}

enum AudioDevices {
    static func outputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        var devices: [AudioDevice] = []
        for id in ids {
            guard hasOutputStreams(id), let name = name(for: id), !name.isEmpty else { continue }
            let transport = transportType(for: id)
            let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? String(id)
            devices.append(AudioDevice(
                id: id,
                uid: uid,
                name: name,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE
            ))
        }

        return devices.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    @discardableResult
    static func setSystemDefaultOutput(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        return status == noErr
    }

    static func recommendedOutputDevice() -> AudioDevice? {
        let devices = outputDevices()
        if let builtIn = devices.first(where: { $0.isBuiltIn }) {
            return builtIn
        }
        if let defaultID = defaultOutputDeviceID(),
           let current = devices.first(where: { $0.id == defaultID && !$0.isBluetooth }) {
            return current
        }
        return devices.first(where: { !$0.isBluetooth }) ?? devices.first
    }

    static func name(for id: AudioDeviceID, fallback: String = "系统默认输出") -> String {
        name(for: id) ?? fallback
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(for: id)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        let trimmed = (string as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return (string as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func transportType(for id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }
}

// MARK: - System audio input (including iPhone Continuity)

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isContinuity: Bool

    var shortName: String {
        var value = name
        for quote in ["“", "”", "\""] {
            value = value.replacingOccurrences(of: quote, with: "")
        }
        if let range = value.range(of: "的麦克风") {
            value = String(value[..<range.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}

extension AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInputStreams(id) else { return nil }
            let name = name(for: id) ?? "音频输入"
            let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "\(id)"
            let continuity = name.localizedCaseInsensitiveContains("iPhone")
                || name.localizedCaseInsensitiveContains("iPad")
                || name.localizedCaseInsensitiveContains("Continuity")
            return AudioInputDevice(id: id, uid: uid, name: name, isContinuity: continuity)
        }
    }

    @discardableResult
    static func setSystemDefaultInput(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        return status == noErr
    }

    static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &id
        )
        return status == noErr && id != 0 ? id : nil
    }

    static func openSoundInputSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.sound?input"
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size > 0
    }
}
