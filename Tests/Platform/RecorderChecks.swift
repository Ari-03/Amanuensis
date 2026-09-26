import AppKit
import Observation
import SwiftUI

/// Only the recording dependencies are substituted; the panel, gestures, and SwiftUI controls are real.
@MainActor @Observable
final class AppModel {
    var settings = AppSettings()
    var modes = DictationMode.initial
    var phase: DictationPhase = .idle
    var recordingDuration: TimeInterval = 12
    var recordingSpectrum = Array(repeating: 0.6, count: AudioSpectrum.bandCount)
    var isMovingRecorder = false
    var pasteNeedsAccessibility = false
    var accessibilityGranted = true
    var history: [RecordingEntry] = []
    var toggleCount = 0
    var isCancellationPending = false
    var onResize: ((CGSize) -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onEndDrag: (() -> Void)?
    var onCancelDrag: (() -> Void)?
    var currentMode: DictationMode { modes.first { $0.id == settings.selectedModeID } ?? modes[0] }
    func toggleRecording() { toggleCount += 1 }
    func requestCancelRecording() { isCancellationPending = true }
    func dismissCancellation() { isCancellationPending = false }
    func selectMode(_ id: UUID) { settings.selectedModeID = id }
    func resizeRecorder(to size: CGSize) { onResize?(size) }
    func moveRecorder(translation: CGSize) { onDrag?(translation) }
    func finishMovingRecorder() { onEndDrag?() }
    func cancelMovingRecorder() { onCancelDrag?() }
    func refreshAccessibility() {}
    func requestAccessibility() {}
    func copyText(_ text: String) {}
}

@main
struct RecorderChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let recorder = RecorderPanelController()
            recorder.show(content: AnyView(Color.clear), style: .mini, placement: .top)
            let panel = app.windows.first { $0.isVisible && $0 is NSPanel }!
            let original = panel.frame
            precondition(original.size == RecorderLayout.idleSize)
            precondition(!panel.canBecomeKey && !panel.canBecomeMain)

            recorder.resize(to: NSSize(width: 256, height: 44))
            await pause(65)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                precondition(panel.frame.width > original.width && panel.frame.width < 256)
            }
            precondition(abs(panel.frame.midX - original.midX) < 1)
            precondition(abs(panel.frame.maxY - original.maxY) < 1)
            await pause(220)
            precondition(panel.frame.size == NSSize(width: 256, height: 44))
            precondition(abs(panel.frame.maxY - (panel.screen!.visibleFrame.maxY - 8)) < 1)
            print("PASS: Native bounds expand inward from the top edge with an 8-point gap")

            var saved: RecorderPlacement?
            var dragging = false
            recorder.onPlacementChanged = { saved = $0 }
            recorder.onDraggingChanged = { dragging = $0 }
            let start = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            let screen = panel.screen!
            let drop = NSPoint(x: screen.visibleFrame.maxX - 20, y: screen.visibleFrame.minY + 20)
            recorder.beginDrag(at: start)
            recorder.resize(to: RecorderLayout.idleSize)
            precondition(panel.frame.width == 256 && dragging)
            recorder.continueDrag(at: drop)
            precondition(app.windows.filter { $0.isVisible && $0 is NSPanel }.count == 2)
            recorder.finishDrag(at: drop)
            await pause(220)
            precondition(saved?.x == 1 && saved?.y == 0 && saved?.displayID != nil)
            precondition(!dragging && panel.frame.size == RecorderLayout.idleSize)
            precondition(abs(panel.frame.minY - (panel.screen!.visibleFrame.minY + 8)) < 1)
            precondition(app.windows.filter { $0.isVisible && $0 is NSPanel }.count == 1)
            print(
                "PASS: Drag displays targets, freezes resizing, saves the snapped display and position, and removes targets"
            )

            let model = AppModel()
            model.onResize = { recorder.resize(to: $0) }
            model.onDrag = { recorder.updateDrag(translation: $0) }
            model.onEndDrag = { recorder.finishDrag(at: NSEvent.mouseLocation) }
            model.onCancelDrag = { recorder.cancelDrag() }
            recorder.onDraggingChanged = { model.isMovingRecorder = $0 }
            recorder.show(content: AnyView(RecorderView(model: model)), style: .mini, placement: .top)
            await pause(350)
            precondition(
                panel.frame.size == NSSize(width: 36, height: 6),
                "An idle recorder must return to the minimized bar")
            precondition(panel.frame.size == RecorderLayout.idleSize)
            model.phase = .recording
            await pause(350)
            precondition(panel.frame.width >= 156 && panel.frame.height >= 36)
            model.phase = .complete
            await pause(350)
            precondition(panel.frame.size == RecorderLayout.idleSize)
            print("PASS: Recording expands the minimized bar, and completion minimizes it again")

            model.accessibilityGranted = false
            model.pasteNeedsAccessibility = true
            await pause(350)
            precondition(panel.frame.size == RecorderLayout.idleSize)
            model.accessibilityGranted = true
            model.pasteNeedsAccessibility = false
            await pause(350)
            precondition(panel.frame.size == RecorderLayout.idleSize)
            print(
                "PASS: Missing paste permission does not keep the recorder expanded"
            )

            for phase in [DictationPhase.idle, .recording] {
                model.phase = phase
                await pause(300)
                let point = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
                let beforeClick = model.toggleCount
                await postMouse(.leftMouseDown, at: point, to: panel)
                await postMouse(.leftMouseUp, at: point, to: panel)
                await pause(100)
                precondition(model.toggleCount == beforeClick + 1)

                var sawDrag = false
                saved = nil
                recorder.onDraggingChanged = { moving in
                    if moving { sawDrag = true }
                    model.isMovingRecorder = moving
                }
                await postMouse(.leftMouseDown, at: point, to: panel)
                await postMouse(.leftMouseDragged, at: NSPoint(x: point.x + 15, y: point.y), to: panel)
                await postMouse(.leftMouseDragged, at: NSPoint(x: point.x + 60, y: point.y), to: panel)
                await postMouse(.leftMouseUp, at: NSPoint(x: point.x + 60, y: point.y), to: panel)
                await pause(300)
                precondition(sawDrag && saved != nil && !model.isMovingRecorder)
                precondition(model.toggleCount == beforeClick + 1)
            }
            print(
                "PASS: Clicking records; dragging either the idle pill or recording button snaps without recording"
            )

            let miniDisplayID = recorder.miniDisplayID
            precondition(miniDisplayID != nil)
            model.phase = .idle
            model.settings.recorderStyle = .notch
            recorder.show(content: AnyView(RecorderView(model: model)), style: .notch, placement: .top)
            await pause(350)
            precondition(
                recorder.miniDisplayID == miniDisplayID,
                "Notch must retain Mini's selected display when no display ID is saved in settings")
            let menuBarHeight = max(NSStatusBar.system.thickness, panel.screen!.safeAreaInsets.top)
            precondition(
                panel.frame.minY >= panel.screen!.frame.maxY - menuBarHeight,
                "Notch controls must stay inside the menu bar, not below the camera")
            let menuBarTop = panel.screen!.frame.maxY
            precondition(panel.frame.width == RecorderLayout.idleSize(for: .notch).width)
            precondition(panel.frame.height == menuBarHeight)
            precondition(abs(panel.frame.maxY - menuBarTop) < 1)
            precondition(!panel.hasShadow && panel.level == .statusBar)
            if let cameraSide = panel.screen!.auxiliaryTopRightArea {
                precondition(cameraSide.contains(panel.frame))
            } else {
                precondition(abs(panel.frame.midX - panel.screen!.frame.midX) < 1)
            }
            model.pasteNeedsAccessibility = true
            model.accessibilityGranted = false
            model.phase = .recording
            await pause(350)
            precondition(panel.frame.height == menuBarHeight)
            precondition(abs(panel.frame.maxY - menuBarTop) < 1)
            precondition(panel.frame.width > RecorderLayout.idleSize(for: .notch).width)
            let fixedFrame = panel.frame
            recorder.show(content: AnyView(RecorderView(model: model)), style: .notch, placement: .bottom)
            await pause(300)
            precondition(panel.frame == fixedFrame)
            saved = nil
            recorder.beginDrag(at: NSPoint(x: fixedFrame.midX, y: fixedFrame.midY))
            recorder.continueDrag(at: drop)
            recorder.finishDrag(at: drop)
            precondition(panel.frame == fixedFrame && saved == nil && !model.isMovingRecorder)
            print(
                "PASS: Notch stays inside the menu bar while expanding and ignores saved positions and dragging"
            )

            model.pasteNeedsAccessibility = false
            model.accessibilityGranted = true
            model.phase = .idle
            await pause(300)
            let beforeNotchClick = model.toggleCount
            let notchPoint = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
            await postMouse(.leftMouseDown, at: notchPoint, to: panel)
            await postMouse(.leftMouseUp, at: notchPoint, to: panel)
            precondition(model.toggleCount == beforeNotchClick + 1)
            precondition(!panel.canBecomeKey && !panel.canBecomeMain)
            model.settings.recorderStyle = .mini
            recorder.show(content: AnyView(RecorderView(model: model)), style: .mini, placement: .bottom)
            await pause(300)
            precondition(recorder.miniDisplayID == miniDisplayID)
            let restoredDisplayID =
                (panel.screen!.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value
            precondition(restoredDisplayID == miniDisplayID)
            precondition(panel.level == .floating && panel.frame.size == RecorderLayout.idleSize)
            print(
                "PASS: Menu-bar clicks still record without taking focus, and Mini restores its display and floating placement"
            )

            for style in [RecorderStyle.mini, .notch] {
                model.settings.recorderStyle = style
                recorder.show(content: AnyView(RecorderView(model: model)), style: style, placement: .top)
                for phase in [DictationPhase.preparing, .transcribing, .cleaning, .delivering] {
                    model.phase = phase
                    await pause(350)
                    let labelWidth = (phase.rawValue as NSString).size(withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11)
                    ]).width
                    precondition(
                        panel.frame.width >= labelWidth + 100,
                        "\(style) must leave room for the full \(phase.rawValue) label and adjacent controls")
                }
                for phase in [DictationPhase.complete, .failed, .interrupted, .idle] {
                    model.phase = phase
                    await pause(350)
                    precondition(panel.frame.width == 36, "Every finished state must minimize the recorder")
                }
                model.phase = .recording
                model.isCancellationPending = true
                await pause(350)
                let promptWidth = ("Cancel transcription? Press Esc again to discard." as NSString)
                    .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
                precondition(panel.frame.width >= promptWidth + 100, "The cancellation prompt must fit")
                precondition(!panel.canBecomeKey && !panel.canBecomeMain)
                if style == .notch {
                    precondition(panel.frame.height == menuBarHeight, "Confirmation must fit the menu bar")
                }
                model.dismissCancellation()
                await pause(350)
                precondition(model.phase == .recording, "Dismissing confirmation must leave recording active")
                precondition(panel.frame.width < promptWidth)
            }
            print("PASS: Both styles fit full processing labels and minimize after completion or failure")
            print("PASS: Both styles fit cancellation confirmation without taking keyboard focus")

            let silentHeight = waveformPeak(intensity: 0)
            let quietHeight = waveformPeak(intensity: 0.35)
            let speakingHeight = waveformPeak(intensity: 0.85)
            precondition(silentHeight <= 4)
            precondition(quietHeight >= 8, "Quiet speech must visibly lift the dots into bars")
            precondition(speakingHeight > quietHeight && speakingHeight <= 22)
            precondition(waveformPeak(intensity: 1, active: false) == silentHeight)
            print("PASS: Rendered bars respond visibly to quiet and normal speech, then return to dots")

            var bands = AudioSpectrum.silence
            bands[1] = 1
            let lowBars = waveformHeights(bands: bands)
            bands[1] = 0
            bands[10] = 1
            let highBars = waveformHeights(bands: bands)
            precondition(lowBars[1] > lowBars[10] && highBars[10] > highBars[1])
            precondition(waveformHeights(bands: [.nan, .infinity, -1]).allSatisfy { $0 <= 4 })
            print("PASS: Individual frequency bands change the rendered shape independently")

            recorder.hide()
            precondition(!panel.isVisible)
            await checkInvocationDisplays()
            let notchFirst = RecorderPanelController()
            notchFirst.show(content: AnyView(Color.clear), style: .notch, placement: nil)
            precondition(notchFirst.miniDisplayID == nil)
            notchFirst.show(content: AnyView(Color.clear), style: .mini, placement: nil)
            precondition(notchFirst.miniDisplayID != nil)
            notchFirst.hide()
            print("PASS: Starting in Notch selects a display the first time Mini is shown")
            print("Recorder checks passed.")
            app.terminate(nil)
        }
        app.run()
    }

    /// Refreshes and resizes must retain the invocation display even with an older saved display.
    @MainActor private static func checkInvocationDisplays() async {
        let recorder = RecorderPanelController()
        let savedID =
            (NSScreen.screens.first!.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber)
            .uint32Value
        let placement = RecorderPlacement(x: 0.75, y: 0, displayID: savedID)
        for style in [RecorderStyle.mini, .notch] {
            for screen in NSScreen.screens {
                recorder.followDisplay(containing: NSPoint(x: screen.frame.midX, y: screen.frame.midY))
                recorder.show(content: AnyView(Color.clear), style: style, placement: placement)
                let panel = NSApp.windows.first { $0.isVisible && $0 is NSPanel }!
                for size in [CGSize(width: 180, height: 38), RecorderLayout.idleSize(for: style)] {
                    recorder.resize(to: size)
                    recorder.show(content: AnyView(Color.clear), style: style, placement: placement)
                    await pause(220)
                    precondition(
                        panel.screen == screen, "Saved placement must not override the invocation display")
                    if style == .mini {
                        let expected = placement.frame(
                            size: size, in: screen.visibleFrame.insetBy(dx: 16, dy: 8))
                        precondition(
                            panel.frame == expected, "The same selected position must be used on each display"
                        )
                    }
                    precondition(!panel.canBecomeKey && !panel.canBecomeMain)
                }
                recorder.hide()
                recorder.show(content: AnyView(Color.clear), style: style, placement: placement)
                precondition(
                    panel.screen == screen, "Hidden controls must also appear on the invocation display")
                recorder.hide()
            }
        }
        print(
            "PASS: Invocation display survives refresh, resize, and hide/show for both styles on \(NSScreen.screens.count) connected display(s)"
        )
    }

    /// Measure the tallest rendered bar, including the actual SwiftUI frame and fill.
    @MainActor private static func waveformPeak(intensity: Double, active: Bool = true) -> Int {
        waveformHeights(bands: Array(repeating: intensity, count: AudioSpectrum.bandCount), active: active)
            .max() ?? 0
    }

    @MainActor private static func waveformHeights(bands: [Double], active: Bool = true) -> [Int] {
        let renderer = ImageRenderer(
            content: RecorderWaveform(bands: bands, active: active))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
        return (0..<AudioSpectrum.bandCount).map { index in
            (0..<bitmap.pixelsHigh).filter { y in
                (bitmap.colorAt(x: index * 6 + 1, y: y)?.alphaComponent ?? 0) > 0.5
            }.count
        }
    }

    @MainActor private static func postMouse(
        _ type: NSEvent.EventType, at point: NSPoint, to window: NSWindow
    ) async {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(event, atStart: false)
        await pause(40)
    }

    private static func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}
