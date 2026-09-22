import AudioToolbox
import CoreAudio
import Foundation

@MainActor
private final class FakePlaybackOutput: PlaybackOutputControlling {
    var defaultDevice: AudioDeviceID = 1
    var uids: [AudioDeviceID: String] = [1: "speakers", 2: "headphones"]
    var writes: [AudioDeviceID] = []
    var volumeSelector: AudioObjectPropertySelector? = kAudioDevicePropertyVolumeScalar
    var muteSupported = false
    var failRead = false
    var failWrite = false
    var ignoreWrites = false
    var quantizeVolume = false
    var switchDefaultAfterWrite = false
    var values: [AudioDeviceID: PlaybackOutputValue] = [1: .volume(0.8), 2: .volume(0.6)]

    func defaultOutputDevice() throws -> AudioDeviceID { defaultDevice }
    func deviceUID(_ device: AudioDeviceID) throws -> String {
        guard let uid = uids[device] else { throw CheckError.unavailable }
        return uid
    }
    func deviceName(_ device: AudioDeviceID) throws -> String {
        try deviceUID(device)
    }
    func isWritable(_ selector: AudioObjectPropertySelector, on device: AudioDeviceID) -> Bool {
        selector == volumeSelector
            || (muteSupported && selector == kAudioDevicePropertyMute)
    }
    func read(_ selector: AudioObjectPropertySelector, on device: AudioDeviceID) throws -> PlaybackOutputValue
    {
        guard !failRead, isWritable(selector, on: device), let value = values[device] else {
            throw CheckError.unavailable
        }
        return value
    }
    func write(_ value: PlaybackOutputValue, selector: AudioObjectPropertySelector, on device: AudioDeviceID)
        throws
    {
        guard !failWrite, isWritable(selector, on: device) else { throw CheckError.unavailable }
        writes.append(device)
        guard !ignoreWrites else { return }
        if quantizeVolume, case .volume(let scalar) = value {
            values[device] = .volume((scalar * 10).rounded() / 10)
        } else {
            values[device] = value
        }
        if switchDefaultAfterWrite { defaultDevice = 2 }
    }
}

private enum CheckError: Error { case unavailable }

@main
private enum PlaybackChecks {
    @MainActor
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            guard condition else {
                print("FAIL: \(message)")
                exit(1)
            }
        }
        func check(_ name: String, _ body: () throws -> Void) rethrows {
            try body()
            checks += 1
            print("PASS: \(name)")
        }

        for behavior in [PlaybackBehavior.lower, .mute] {
            try check("\(behavior.rawValue) through virtual output volume") {
                let output = FakePlaybackOutput()
                output.volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
                let controller = PlaybackController(output: output)
                expect(
                    controller.availableBehaviors().contains(behavior), "Writable virtual volume was ignored."
                )
                try controller.begin(behavior)
                let expected: Float32 = behavior == .mute ? 0 : 0.2
                expect(
                    output.values[1]?.matches(.volume(expected)) == true, "Virtual volume was not adjusted.")
                controller.end()
                expect(output.values[1]?.matches(.volume(0.8)) == true, "Virtual volume was not restored.")
                expect(controller.restorationError == nil, "Virtual volume restoration failed.")
            }
        }

        check("Reject outputs without writable volume or mute") {
            let output = FakePlaybackOutput()
            output.volumeSelector = nil
            let controller = PlaybackController(output: output)
            expect(controller.availableBehaviors() == [.keepPlaying], "Unsupported controls were offered.")
            for behavior in [PlaybackBehavior.lower, .mute] {
                var failed = false
                do { try controller.begin(behavior) } catch {
                    failed = true
                    expect(
                        error.localizedDescription.contains("speakers"), "Unsupported output was not named.")
                }
                expect(failed, "An unavailable playback setting was accepted.")
            }
            expect(output.writes.isEmpty, "Unsupported output was changed.")
        }

        try check("Restore the former output after the default changes") {
            let output = FakePlaybackOutput()
            let controller = PlaybackController(output: output)
            try controller.begin(.lower)
            output.defaultDevice = 2
            controller.end()
            expect(output.values[1]?.matches(.volume(0.8)) == true, "Former output stays lowered.")
            expect(output.values[2]?.matches(.volume(0.6)) == true, "New default was changed.")
            expect(output.writes == [1, 1], "Restoration wrote to an unexpected output.")
            expect(controller.restorationError == nil, "Successful restoration reported an error.")
            controller.end()
            expect(output.writes.count == 2, "Ending twice restores twice.")
        }
        try check("Restore mute on the original output") {
            let output = FakePlaybackOutput()
            output.muteSupported = true
            output.values[1] = .mute(0)
            let controller = PlaybackController(output: output)
            try controller.begin(.mute)
            expect(output.values[1]?.matches(.mute(1)) == true, "Mute was not applied.")
            output.defaultDevice = 2
            controller.end()
            expect(output.values[1]?.matches(.mute(0)) == true, "Original mute was not restored.")
        }
        try check("Preserve volume changed by the user") {
            let output = FakePlaybackOutput()
            let controller = PlaybackController(output: output)
            try controller.begin(.lower)
            output.values[1] = .volume(0.5)
            output.defaultDevice = 2
            controller.end()
            expect(output.values[1]?.matches(.volume(0.5)) == true, "User volume was overwritten.")
            expect(output.writes == [1], "Restoration wrote over a user change.")
            expect(controller.restorationError == nil, "User change should not be an error.")
        }
        try check("Report a disconnected original device") {
            let output = FakePlaybackOutput()
            let controller = PlaybackController(output: output)
            try controller.begin(.lower)
            output.uids[1] = nil
            output.defaultDevice = 2
            controller.end()
            expect(controller.restorationError != nil, "Disconnect failure was hidden.")
            expect(output.writes == [1], "Disconnected device was written.")
        }
        try check("Do not restore into a reused device ID") {
            let output = FakePlaybackOutput()
            let controller = PlaybackController(output: output)
            try controller.begin(.lower)
            output.uids[1] = "unrelated USB device"
            controller.end()
            expect(output.writes == [1], "An unrelated device inherited the old volume.")
            expect(controller.restorationError != nil, "Device replacement failure was hidden.")
        }
        for failure in ["read", "write", "silent write"] {
            try check("Report restoration \(failure) failure") {
                let output = FakePlaybackOutput()
                let controller = PlaybackController(output: output)
                try controller.begin(.lower)
                output.failRead = failure == "read"
                output.failWrite = failure == "write"
                output.ignoreWrites = failure == "silent write"
                controller.end()
                expect(controller.restorationError != nil, "Restoration failure was hidden.")
            }
        }
        for (name, selector) in [
            ("main", kAudioDevicePropertyVolumeScalar),
            ("virtual", kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
        ] {
            try check("Restore quantized \(name) volume") {
                let output = FakePlaybackOutput()
                output.volumeSelector = selector
                output.values[1] = .volume(0.7)
                output.quantizeVolume = true
                let controller = PlaybackController(output: output)
                try controller.begin(.lower)
                expect(output.values[1]?.matches(.volume(0.2)) == true, "Fake did not quantize volume.")
                controller.end()
                expect(output.values[1]?.matches(.volume(0.7)) == true, "Quantized volume was not restored.")
            }
            check("Roll back \(name) volume when output switches during begin") {
                let output = FakePlaybackOutput()
                output.volumeSelector = selector
                output.switchDefaultAfterWrite = true
                let controller = PlaybackController(output: output)
                var failed = false
                do { try controller.begin(.lower) } catch { failed = true }
                expect(failed, "Recording proceeded despite the output changing during begin.")
                expect(output.values[1]?.matches(.volume(0.8)) == true, "Failed begin left output lowered.")
                expect(output.writes == [1, 1], "Failed begin did not restore its original output.")
            }
        }
        print("\(checks) playback checks passed.")
    }
}
