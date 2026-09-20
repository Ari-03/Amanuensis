import CoreAudio
import Foundation

enum PlaybackOutputValue {
    case volume(Float32)
    case mute(UInt32)

    func matches(_ other: PlaybackOutputValue) -> Bool {
        switch (self, other) {
        case (.volume(let lhs), .volume(let rhs)): abs(lhs - rhs) < 0.0001
        case (.mute(let lhs), .mute(let rhs)): lhs == rhs
        default: false
        }
    }
}

@MainActor
protocol PlaybackOutputControlling {
    func defaultOutputDevice() throws -> AudioDeviceID
    func deviceUID(_ device: AudioDeviceID) throws -> String
    func isWritable(_ selector: AudioObjectPropertySelector, on device: AudioDeviceID) -> Bool
    func read(_ selector: AudioObjectPropertySelector, on device: AudioDeviceID) throws -> PlaybackOutputValue
    func write(_ value: PlaybackOutputValue, selector: AudioObjectPropertySelector, on device: AudioDeviceID)
        throws
}

/// Temporarily changes writable output controls and preserves later user changes.
@MainActor
final class PlaybackController {
    private struct Change {
        let device: AudioDeviceID
        let deviceUID: String
        let selector: AudioObjectPropertySelector
        let original: PlaybackOutputValue
        let applied: PlaybackOutputValue
    }

    private let output: any PlaybackOutputControlling

    init(output: any PlaybackOutputControlling = CoreAudioPlaybackOutput()) {
        self.output = output
    }

    private var change: Change?
    private(set) var restorationError: String?

    /// Availability can change when headphones or another output device connects.
    func availableBehaviors() -> [PlaybackBehavior] {
        guard let device = try? output.defaultOutputDevice() else { return [.keepPlaying] }
        var behaviors: [PlaybackBehavior] = [.keepPlaying]
        if output.isWritable(kAudioDevicePropertyVolumeScalar, on: device) {
            behaviors.append(.lower)
        }
        if output.isWritable(kAudioDevicePropertyMute, on: device)
            || output.isWritable(kAudioDevicePropertyVolumeScalar, on: device)
        {
            behaviors.append(.mute)
        }
        return behaviors
    }

    func begin(_ behavior: PlaybackBehavior) throws {
        guard change == nil else { throw PlaybackControlError.alreadyActive }
        restorationError = nil
        guard behavior != .keepPlaying else { return }
        guard behavior != .pause else { throw PlaybackControlError.pauseUnsupported }

        let device = try output.defaultOutputDevice()
        let deviceUID = try output.deviceUID(device)
        let selector: AudioObjectPropertySelector
        if behavior == .mute, output.isWritable(kAudioDevicePropertyMute, on: device) {
            selector = kAudioDevicePropertyMute
        } else {
            selector = kAudioDevicePropertyVolumeScalar
        }
        guard output.isWritable(selector, on: device) else {
            throw PlaybackControlError.unsupportedOutput(behavior.rawValue)
        }

        let original = try output.read(selector, on: device)
        let requested: PlaybackOutputValue
        switch original {
        case .volume(let volume):
            requested = .volume(behavior == .mute ? 0 : volume * 0.25)
        case .mute:
            requested = .mute(1)
        }
        guard try output.defaultOutputDevice() == device, try output.deviceUID(device) == deviceUID else {
            throw PlaybackControlError.outputChanged
        }
        try output.write(requested, selector: selector, on: device)
        change = Change(
            device: device, deviceUID: deviceUID, selector: selector, original: original, applied: requested)

        do {
            let actual = try output.read(selector, on: device)
            let succeeded: Bool
            switch (original, actual) {
            case (.volume(let before), .volume(let after)):
                succeeded =
                    behavior == .mute ? after < 0.0001 : ((before == 0 && after == 0) || after < before)
            case (.mute, .mute(let after)):
                succeeded = after == 1
            default:
                succeeded = false
            }
            guard succeeded else { throw PlaybackControlError.changeNotApplied }
            // Devices may quantize volume, so restoration compares their actual value.
            change = Change(
                device: device, deviceUID: deviceUID, selector: selector, original: original, applied: actual)
            guard try output.defaultOutputDevice() == device, try output.deviceUID(device) == deviceUID else {
                throw PlaybackControlError.outputChanged
            }
        } catch {
            end()
            throw error
        }
    }

    /// Restores the original device even if another device has become the default.
    func end() {
        guard let previous = change else { return }
        change = nil
        do {
            // Core Audio may reuse a disconnected device's numeric ID for a new device.
            guard try output.deviceUID(previous.device) == previous.deviceUID else {
                throw PlaybackControlError.outputChanged
            }
            let current = try output.read(previous.selector, on: previous.device)
            guard current.matches(previous.applied) else { return }
            guard try output.deviceUID(previous.device) == previous.deviceUID else {
                throw PlaybackControlError.outputChanged
            }
            try output.write(previous.original, selector: previous.selector, on: previous.device)
            let restored = try output.read(previous.selector, on: previous.device)
            guard restored.matches(previous.original) else { throw PlaybackControlError.changeNotApplied }
        } catch {
            restorationError = "The previous output setting could not be restored. Check your volume."
        }
    }

}

@MainActor
private struct CoreAudioPlaybackOutput: PlaybackOutputControlling {
    func defaultOutputDevice() throws -> AudioDeviceID {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { throw PlaybackControlError.noOutput }
        return device
    }

    func deviceUID(_ device: AudioDeviceID) throws -> String {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw PlaybackControlError.coreAudio(status) }
        return uid.takeRetainedValue() as String
    }

    func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func isWritable(_ selector: AudioObjectPropertySelector, on device: AudioDeviceID) -> Bool {
        var property = address(selector)
        guard AudioObjectHasProperty(device, &property) else { return false }
        var writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &property, &writable) == noErr && writable.boolValue
    }

    func read(_ selector: AudioObjectPropertySelector, on device: AudioDeviceID) throws -> PlaybackOutputValue
    {
        var property = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status: OSStatus
        if selector == kAudioDevicePropertyMute {
            var value: UInt32 = 0
            status = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value)
            guard status == noErr else { throw PlaybackControlError.coreAudio(status) }
            return .mute(value)
        } else {
            var value: Float32 = 0
            status = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value)
            guard status == noErr, value.isFinite, (0...1).contains(value) else {
                throw PlaybackControlError.coreAudio(status)
            }
            return .volume(value)
        }
    }

    func write(_ value: PlaybackOutputValue, selector: AudioObjectPropertySelector, on device: AudioDeviceID)
        throws
    {
        var property = address(selector)
        let status: OSStatus
        switch value {
        case .volume(var scalar):
            status = AudioObjectSetPropertyData(
                device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar
            )
        case .mute(var muted):
            status = AudioObjectSetPropertyData(
                device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted
            )
        }
        guard status == noErr else { throw PlaybackControlError.coreAudio(status) }
    }
}

private enum PlaybackControlError: LocalizedError {
    case alreadyActive
    case pauseUnsupported
    case unsupportedOutput(String)
    case noOutput
    case outputChanged
    case changeNotApplied
    case coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyActive: "A playback adjustment is already active."
        case .pauseUnsupported:
            "Pausing media is not available yet. Choose Keep playing, Lower volume, or Mute."
        case .unsupportedOutput(let behavior):
            "This output device does not provide a writable control for \(behavior.lowercased()). Choose Keep playing."
        case .noOutput: "No audio output device is available."
        case .outputChanged: "The audio output changed before recording began. Try again."
        case .changeNotApplied: "The output device did not apply the requested playback setting."
        case .coreAudio(let status): "The output device could not be controlled (Core Audio \(status))."
        }
    }
}
