import AppKit
import SwiftUI

/// Shows recording controls without taking keyboard focus from the destination.
@MainActor
final class RecorderPanelController {
    private let panel: RecorderPanel
    private let hostingView: RecorderHostingView
    private var placement: RecorderPlacement = .bottom
    private var screenNumber: UInt32?
    private var screenObserver: NSObjectProtocol?
    private var layoutScheduled = false
    private var isDragging = false
    private(set) var isVisible = false

    init() {
        panel = RecorderPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = RecorderHostingView(rootView: AnyView(EmptyView()))
        hostingView.sizingOptions = .intrinsicContentSize
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.setAccessibilityLabel("Amanuensis recording controls")
        hostingView.onIntrinsicSizeChange = { [weak self] in self?.schedulePlacement() }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePanel() }
        }
    }

    isolated deinit {
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
            let screen =
                NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
            screenNumber = screen.map(displayID)
        }
        hostingView.rootView = content
        isVisible = true
        placePanel()
        panel.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        panel.orderOut(nil)
    }

    /// AppKit tracks the drag without activating the app or changing the insertion target.
    func drag(with event: NSEvent) -> RecorderPlacement? {
        guard isVisible else { return nil }
        isDragging = true
        panel.performDrag(with: event)
        isDragging = false
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? panel.screen ?? NSScreen.main
        else { return nil }
        screenNumber = displayID(screen)
        placement = RecorderPlacement(
            frame: panel.frame, in: availableFrame(on: screen), displayID: screenNumber)
        placePanel()
        return placement
    }

    private func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func availableFrame(on screen: NSScreen) -> NSRect {
        var frame = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        // Stay below the camera cutout even when the menu bar is hidden.
        let safeTop = screen.frame.maxY - screen.safeAreaInsets.top - 8
        frame.size.height = max(0, min(frame.maxY, safeTop) - frame.minY)
        return frame
    }

    private func schedulePlacement() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        // SwiftUI invalidates size during layout. Defer resizing until that pass finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutScheduled = false
            self.placePanel()
        }
    }

    private func placePanel() {
        guard isVisible, !isDragging else { return }
        let screen =
            NSScreen.screens.first {
                displayID($0) == screenNumber
            } ?? NSScreen.main
        guard let screen else { return }

        let available = availableFrame(on: screen)
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = NSSize(width: max(ceil(fitting.width), 1), height: max(ceil(fitting.height), 1))
        let frame = placement.frame(size: size, in: available)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

/// A dedicated handle keeps dragging separate from the recording and mode buttons.
struct RecorderDragHandle: NSViewRepresentable {
    var onDrag: (NSEvent) -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.onDrag = onDrag
        nsView.setAccessibilityLabel("Drag recording controls")
        nsView.toolTip = "Drag to move. Choose a screen position in Settings."
    }

    final class DragView: NSView {
        var onDrag: ((NSEvent) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onDrag?(event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

private final class RecorderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecorderHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
