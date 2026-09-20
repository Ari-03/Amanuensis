import AppKit
import SwiftUI

/// Shows recording controls without taking keyboard focus from the destination.
@MainActor
final class RecorderPanelController {
    private let panel: RecorderPanel
    private let hostingView: RecorderHostingView
    private var style: RecorderStyle = .mini
    private var screenNumber: NSNumber?
    private var screenObserver: NSObjectProtocol?
    private var layoutScheduled = false
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

    func show(content: AnyView, style: RecorderStyle) {
        self.style = style
        guard style != .hidden else {
            hide()
            return
        }
        if !isVisible {
            let screen =
                NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
            screenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
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
        guard isVisible else { return }
        let screen =
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenNumber
            } ?? NSScreen.main
        guard let screen else { return }

        let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let desiredWidth: CGFloat = style == .panel ? 440 : 360
        let width = min(desiredWidth, available.width)
        if abs(hostingView.frame.width - width) > 0.5 {
            hostingView.setFrameSize(NSSize(width: width, height: max(hostingView.frame.height, 72)))
        }
        hostingView.layoutSubtreeIfNeeded()
        let intrinsicHeight = hostingView.intrinsicContentSize.height
        let fittingHeight = intrinsicHeight > 0 ? intrinsicHeight : hostingView.fittingSize.height
        let height = min(max(ceil(fittingHeight), 72), available.height - 12)

        let x = screen.frame.midX - width / 2
        let y: CGFloat
        if style == .notch {
            // The physical camera cutout is never part of the interactive region.
            y = min(screen.frame.maxY - screen.safeAreaInsets.top - height - 8, available.maxY - height)
        } else {
            y = available.minY + 12
        }
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
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
