import CoreAudio
import Foundation

@MainActor
private final class FakePlaybackOutput: PlaybackOutputControlling {
    var defaultDevice: AudioDeviceID = 1
    var uids: [AudioDeviceID: String] = [1: "speakers", 2: "headphones"]
    var writes: [AudioDeviceID] = []
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
    func isWritable(_ selector: AudioObjectPropertySelector, on device: AudioDeviceID) -> Bool {
        selector == kAudioDevicePropertyVolumeScalar
            || (muteSupported && selector == kAudioDevicePropertyMute)
    }
    func read(_ selector: AudioObjectPropertySelector, on device: AudioDeviceID) throws -> PlaybackOutputValue
    {
        guard !failRead, let value = values[device] else { throw CheckError.unavailable }
        return value
    }
    func write(_ value: PlaybackOutputValue, selector: AudioObjectPropertySelector, on device: AudioDeviceID)
        throws
    {
        guard !failWrite else { throw CheckError.unavailable }
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
        try check("Match the device's quantized volume when restoring") {
            let output = FakePlaybackOutput()
            output.values[1] = .volume(0.7)
            output.quantizeVolume = true
            let controller = PlaybackController(output: output)
            try controller.begin(.lower)
            expect(output.values[1]?.matches(.volume(0.2)) == true, "Fake did not quantize volume.")
            controller.end()
            expect(output.values[1]?.matches(.volume(0.7)) == true, "Quantized volume was not restored.")
        }
        check("Roll back when output switches during begin") {
            let output = FakePlaybackOutput()
            output.switchDefaultAfterWrite = true
            let controller = PlaybackController(output: output)
            var failed = false
            do { try controller.begin(.lower) } catch { failed = true }
            expect(failed, "Recording proceeded despite the output changing during begin.")
            expect(output.values[1]?.matches(.volume(0.8)) == true, "Failed begin left output lowered.")
            expect(output.writes == [1, 1], "Failed begin did not restore its original output.")
        }
        print("\(checks) playback checks passed.")
    }
}
