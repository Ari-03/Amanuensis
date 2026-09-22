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
    var recordingLevel = 0.6
    var isMovingRecorder = false
    var pasteNeedsAccessibility = false
    var accessibilityGranted = true
    var history: [RecordingEntry] = []
    var toggleCount = 0
    var onResize: ((CGSize) -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onEndDrag: (() -> Void)?
    var onCancelDrag: (() -> Void)?
    var currentMode: DictationMode { modes.first { $0.id == settings.selectedModeID } ?? modes[0] }
    func toggleRecording() { toggleCount += 1 }
    func cancelRecording() { phase = .idle }
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
            precondition(abs(panel.frame.midY - original.midY) < 1)
            await pause(220)
            precondition(panel.frame.size == NSSize(width: 256, height: 44))
            print("PASS: Native bounds animate through intermediate sizes around a fixed center")

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
            precondition(panel.frame.size == RecorderLayout.idleSize)
            model.phase = .recording
            await pause(350)
            precondition(panel.frame.size == RecorderLayout.idleSize)
            model.phase = .complete
            await pause(350)
            precondition(panel.frame.size == RecorderLayout.idleSize)
            print("PASS: Idle and recording keep the same compact bounds")

            model.accessibilityGranted = false
            model.pasteNeedsAccessibility = true
            await pause(350)
            precondition(panel.frame.height >= 38)
            precondition(panel.frame.width > RecorderLayout.idleSize.width)
            model.accessibilityGranted = true
            model.pasteNeedsAccessibility = false
            await pause(350)
            precondition(panel.frame.size == RecorderLayout.idleSize)
            print(
                "PASS: Missing paste permission reveals a recovery control; clearing it restores the idle pill"
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

            model.phase = .idle
            model.settings.recorderStyle = .notch
            recorder.show(content: AnyView(RecorderView(model: model)), style: .notch, placement: .top)
            await pause(350)
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
            precondition(panel.level == .floating && panel.frame.size == RecorderLayout.idleSize)
            print(
                "PASS: Menu-bar clicks still record without taking focus, and Mini restores floating placement"
            )

            recorder.hide()
            precondition(!panel.isVisible)
            print("Recorder checks passed.")
            app.terminate(nil)
        }
        app.run()
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
