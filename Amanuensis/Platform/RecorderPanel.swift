import AppKit
import QuartzCore
import SwiftUI

/// Shows recording controls without taking keyboard focus from the destination.
@MainActor
final class RecorderPanelController {
    private let panel: RecorderPanel
    private let hostingView: RecorderHostingView
    private let targetsPanel: RecorderPanel
    private var placement: RecorderPlacement = .bottom
    private var screenNumber: UInt32?
    private var screenObserver: NSObjectProtocol?
    private var contentSize = RecorderLayout.idleSize
    private var animation: Task<Void, Never>?
    private var dragOrigin: NSPoint?
    private var dragMouseOrigin: NSPoint = .zero
    private(set) var isVisible = false
    var onPlacementChanged: ((RecorderPlacement) -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?

    init() {
        panel = RecorderPanel()
        targetsPanel = RecorderPanel()
        hostingView = RecorderHostingView(rootView: AnyView(EmptyView()))
        // The panel owns its animated size; SwiftUI fills that size instead of imposing constraints.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.hasShadow = true
        panel.setAccessibilityLabel("Amanuensis recording controls")
        targetsPanel.ignoresMouseEvents = true
        targetsPanel.hasShadow = false

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelDrag()
                self?.placePanel(animated: false)
            }
        }
    }

    isolated deinit {
        animation?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func show(content: AnyView, style: RecorderStyle, placement: RecorderPlacement?) {
        self.placement = placement ?? (style == .notch ? .top : .bottom)
        guard style != .hidden else {
            hide()
            return
        }
        if let displayID = placement?.displayID {
            screenNumber = displayID
        } else if !isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            screenNumber = screen.map(displayID)
        }
        hostingView.rootView = content
        let wasVisible = isVisible
        isVisible = true
        placePanel(animated: wasVisible)
        panel.orderFrontRegardless()
    }

    func resize(to size: NSSize) {
        guard contentSize != size else { return }
        contentSize = size
        placePanel(animated: true)
    }

    func hide() {
        cancelDrag()
        animation?.cancel()
        isVisible = false
        panel.orderOut(nil)
    }

    func updateDrag(translation: CGSize) {
        let mouse = NSEvent.mouseLocation
        if dragOrigin == nil {
            beginDrag(at: mouse, translation: NSPoint(x: translation.width, y: -translation.height))
        }
        continueDrag(at: mouse)
    }

    // These methods also let native checks exercise the drag lifecycle without posting global input.
    func beginDrag(at mouse: NSPoint, translation: NSPoint = .zero) {
        guard isVisible else { return }
        animation?.cancel()
        dragOrigin = panel.frame.origin
        dragMouseOrigin = NSPoint(x: mouse.x - translation.x, y: mouse.y - translation.y)
        onDraggingChanged?(true)
    }

    func continueDrag(at mouse: NSPoint) {
        guard let origin = dragOrigin else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: origin.x + mouse.x - dragMouseOrigin.x,
                y: origin.y + mouse.y - dragMouseOrigin.y))
        showTargets()
    }

    func finishDrag(at mouse: NSPoint) {
        guard dragOrigin != nil else { return }
        continueDrag(at: mouse)
        guard let screen = dragScreen else {
            cancelDrag()
            return
        }
        screenNumber = displayID(screen)
        placement = nearestPlacement(on: screen)
        dragOrigin = nil
        targetsPanel.orderOut(nil)
        onPlacementChanged?(placement)
        onDraggingChanged?(false)
        placePanel(animated: true)
    }

    func cancelDrag() {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        targetsPanel.orderOut(nil)
        onDraggingChanged?(false)
        placePanel(animated: false)
    }

    private var dragScreen: NSScreen? {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? panel.screen ?? NSScreen.main
    }

    private func nearestPlacement(on screen: NSScreen) -> RecorderPlacement {
        RecorderPlacement.nearestPreset(
            to: NSPoint(x: panel.frame.midX, y: panel.frame.midY), size: panel.frame.size,
            in: availableFrame(on: screen), displayID: displayID(screen))
    }

    private func showTargets() {
        guard let screen = dragScreen else { return }
        targetsPanel.setFrame(screen.frame, display: true)
        let view = RecorderSnapTargets(
            screenFrame: screen.frame, available: availableFrame(on: screen), size: panel.frame.size,
            selected: nearestPlacement(on: screen))
        if let host = targetsPanel.contentView as? NSHostingView<RecorderSnapTargets> {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            targetsPanel.contentView = host
        }
        targetsPanel.order(.below, relativeTo: panel.windowNumber)
    }

    private func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func availableFrame(on screen: NSScreen) -> NSRect {
        var frame = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let safeTop = screen.frame.maxY - screen.safeAreaInsets.top - 8
        frame.size.height = max(0, min(frame.maxY, safeTop) - frame.minY)
        return frame
    }

    private func placePanel(animated: Bool) {
        guard isVisible, dragOrigin == nil else { return }
        let screen = NSScreen.screens.first { displayID($0) == screenNumber } ?? NSScreen.main
        guard let screen else { return }
        let frame = placement.frame(size: contentSize, in: availableFrame(on: screen))
        animation?.cancel()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, panel.frame != frame
        else {
            panel.setFrame(frame, display: true)
            return
        }
        let startFrame = panel.frame
        // Animate the actual window, so the material and hit region follow the same capsule edges.
        animation = Task { @MainActor [weak self] in
            let start = CACurrentMediaTime()
            while !Task.isCancelled {
                guard let self else { return }
                let progress = min((CACurrentMediaTime() - start) / 0.18, 1)
                let eased = progress * progress * (3 - 2 * progress)
                let next = NSRect(
                    x: startFrame.minX + (frame.minX - startFrame.minX) * eased,
                    y: startFrame.minY + (frame.minY - startFrame.minY) * eased,
                    width: startFrame.width + (frame.width - startFrame.width) * eased,
                    height: startFrame.height + (frame.height - startFrame.height) * eased)
                self.panel.setFrame(next, display: true)
                if progress == 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}

private struct RecorderSnapTargets: View {
    let screenFrame: NSRect
    let available: NSRect
    let size: NSSize
    let selected: RecorderPlacement

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(RecorderPlacement.presets.enumerated()), id: \.offset) { _, preset in
                let frame = preset.frame(size: size, in: available)
                let highlighted = preset.x == selected.x && preset.y == selected.y
                Capsule()
                    .fill(highlighted ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.1))
                    .overlay(
                        Capsule().strokeBorder(
                            highlighted ? Color.accentColor : Color.primary.opacity(0.3),
                            lineWidth: highlighted ? 2 : 1)
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX - screenFrame.minX, y: screenFrame.maxY - frame.midY)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .accessibilityHidden(true)
    }
}

private final class RecorderPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecorderHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
