import AppKit
import SwiftUI

struct RecorderView: View {
    @Bindable var model: AppModel
    @State private var hovering = false
    @State private var showingModes = false
    @State private var showingPermission = false
    @GestureState private var dragging = false
    @State private var revealControls = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlsSize = CGSize(width: 62, height: 26)
    @State private var activitySize = CGSize(width: 156, height: 26)
    @State private var collapseTask: Task<Void, Never>?

    private var isOpen: Bool {
        revealControls || showingModes || showingPermission
    }

    private var isMinimized: Bool { !isOpen && !model.phase.isBusy }
    private var style: RecorderStyle { model.settings.recorderStyle }
    private var idleSize: CGSize { RecorderLayout.idleSize(for: style) }
    private var activeSize: CGSize { RecorderLayout.activeSize(for: style) }
    private var silhouette: RecorderSilhouette { RecorderSilhouette(style: style) }

    private var recordingLabel: String {
        model.phase == .recording ? "Finish recording" : "Start recording"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                controls
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) {
                        $0.size
                    } action: {
                        controlsSize = $0
                    }
                    .opacity(isOpen ? 1 : 0)
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(!isOpen)
                compactContents
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(!isOpen && !isMinimized ? 1 : 0)
                    .allowsHitTesting(!isOpen && !isMinimized)
                    .accessibilityHidden(isOpen || isMinimized)
                minimizedContents
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(isMinimized ? 1 : 0)
                    .allowsHitTesting(isMinimized)
                    .accessibilityHidden(!isMinimized)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(.black, in: silhouette)
            .clipShape(silhouette)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .contentShape(silhouette)
        .highPriorityGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { model.moveRecorder(translation: $0.translation) }
                .onEnded { _ in model.finishMovingRecorder() },
            including: style == .mini ? .all : .subviews
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isOpen)
        .onHover { inside in
            hovering = inside
            if inside {
                model.refreshAccessibility()
                collapseTask?.cancel()
                revealControls = true
            } else {
                scheduleCollapse()
            }
        }
        .onAppear { updateSize() }
        .onChange(of: isOpen) { _, _ in updateSize() }
        .onChange(of: controlsSize) { _, _ in updateSize() }
        .onChange(of: activitySize) { _, _ in updateSize() }
        .onChange(of: model.phase) { _, _ in updateSize() }
        .onChange(of: style) { _, _ in updateSize() }
        .onChange(of: showingModes) { _, showing in
            if !showing { scheduleCollapse() }
        }
        .onChange(of: showingPermission) { _, showing in
            if !showing { scheduleCollapse() }
        }
        .onChange(of: model.accessibilityGranted) { _, granted in
            if granted { showingPermission = false }
        }
        .onChange(of: model.isMovingRecorder) { _, moving in
            if moving {
                collapseTask?.cancel()
                showingModes = false
                showingPermission = false
            } else {
                scheduleCollapse()
            }
        }
        .onChange(of: dragging) { _, active in
            if !active && model.isMovingRecorder { model.cancelMovingRecorder() }
        }
        .onChange(of: model.phase.isBusy) { _, busy in
            if busy {
                showingModes = false
                showingPermission = false
            } else {
                scheduleCollapse()
            }
        }
        .onDisappear {
            collapseTask?.cancel()
            model.cancelMovingRecorder()
        }
    }

    private func updateSize() {
        if isMinimized {
            model.resizeRecorder(to: idleSize)
        } else {
            let content = isOpen ? controlsSize : activitySize
            model.resizeRecorder(
                to: CGSize(
                    width: max(
                        model.phase.isBusy ? activeSize.width : idleSize.width,
                        ceil(content.width) + (isOpen ? 24 : 0)),
                    height: max(activeSize.height, ceil(content.height) + 12)))
        }
    }

    private var minimizedContents: some View {
        Button(action: model.toggleRecording) {
            Capsule()
                .fill(model.pasteNeedsAccessibility ? Color.orange : .white.opacity(0.8))
                .frame(width: 24, height: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(silhouette)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start recording")
        .accessibilityHint(
            model.pasteNeedsAccessibility
                ? "Automatic paste needs Accessibility access. Show recorder controls for options."
                : "Hover or use actions to show recorder controls."
        )
        .accessibilityActions {
            Button("Show recorder controls") { revealControls = true }
        }
        .help("Click to record. Hover for controls.")
    }

    private var compactContents: some View {
        Button(action: model.toggleRecording) {
            HStack(spacing: 12) {
                Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 24)
                Spacer(minLength: 4)
                if model.phase.isBusy && model.phase != .recording {
                    ProgressView().controlSize(.mini)
                    Text(model.phase.rawValue).font(.system(size: 11)).fixedSize()
                } else {
                    RecorderWaveform(bands: model.recordingSpectrum, active: model.phase == .recording)
                }
            }
            .padding(.horizontal, style == .notch ? 20 : 16)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                activitySize = $0
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(silhouette)
        }
        .buttonStyle(.plain)
        .disabled(model.phase.isBusy && model.phase != .recording)
        .accessibilityLabel(
            model.phase.isBusy && model.phase != .recording ? model.phase.rawValue : recordingLabel
        )
        .accessibilityValue(model.phase == .recording ? durationLabel(model.recordingDuration) : "")
        .accessibilityHint(
            style == .mini
                ? "Use actions for more recorder controls. Drag to reposition."
                : "Use actions for more recorder controls."
        )
        .accessibilityActions {
            Button("Show recorder controls") { revealControls = true }
            if model.phase.isBusy && model.phase != .delivering {
                Button("Cancel recording", action: model.cancelRecording)
            }
        }
        .help(
            model.phase == .recording
                ? "Click to finish recording. Hover for controls."
                : style == .mini
                    ? "Click to record. Hover for controls. Drag to reposition."
                    : "Click to record. Hover for controls.")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                showingPermission = false
                showingModes.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: model.currentMode.symbol)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.phase.isBusy)
            .accessibilityLabel("Change mode, current mode: \(model.currentMode.name)")
            .help("Change mode")
            .popover(isPresented: $showingModes, arrowEdge: popoverEdge) {
                modeMenu
            }

            Button(action: model.toggleRecording) {
                Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: model.phase == .recording ? 12 : 17, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.phase.isBusy && model.phase != .recording)
            .accessibilityLabel(recordingLabel)
            .help(recordingLabel)

            if !model.phase.isBusy
                && (model.pasteNeedsAccessibility
                    || (!model.accessibilityGranted && model.currentMode.autoPaste))
            {
                Button {
                    showingModes = false
                    showingPermission.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .frame(width: 22, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Allow Accessibility access for automatic paste")
                .help("Automatic paste needs Accessibility access")
                .popover(isPresented: $showingPermission, arrowEdge: popoverEdge) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Allow automatic paste").font(.headline)
                        Text(
                            "Enable Amanuensis in System Settings → Privacy & Security → Accessibility. Then return to your text field and record again."
                        )
                        .font(.callout)
                        Button("Open Accessibility Settings") {
                            showingPermission = false
                            model.requestAccessibility()
                        }
                        if model.pasteNeedsAccessibility, let entry = model.history.first {
                            Button("Copy last transcript") {
                                model.copyText(entry.finalText)
                                model.pasteNeedsAccessibility = false
                                showingPermission = false
                            }
                        }
                        Button("Not now") {
                            model.pasteNeedsAccessibility = false
                            showingPermission = false
                        }.buttonStyle(.link)
                    }
                    .padding(16).frame(width: 290)
                }
            }

            if model.phase.isBusy {
                HStack(spacing: 6) {
                    if model.phase == .recording {
                        RecorderWaveform(bands: model.recordingSpectrum, active: true)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(
                        model.phase == .recording
                            ? durationLabel(model.recordingDuration) : model.phase.rawValue
                    )
                    .font(.caption2).monospacedDigit().fixedSize()
                }
                Button(action: model.cancelRecording) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        .frame(width: 22, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Cancel recording")
                .accessibilityLabel("Cancel recording")
                .disabled(model.phase == .delivering)
            }

        }
    }

    private var popoverEdge: Edge {
        style == .notch || (model.settings.recorderPlacement ?? .bottom).y > 0.5 ? .bottom : .top
    }

    private var modeMenu: some View {
        VStack(spacing: 4) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.modes) { mode in
                        RecorderModeRow(
                            title: mode.name, symbol: mode.symbol,
                            selected: model.currentMode.id == mode.id
                        ) {
                            model.selectMode(mode.id)
                            showingModes = false
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(model.modes.count) * 36, 288))
            Divider().padding(.vertical, 3)
            RecorderModeRow(
                title: "Automatic app modes", symbol: "arrow.triangle.branch",
                selected: model.settings.automaticModeSelection
            ) {
                model.settings.automaticModeSelection.toggle()
                showingModes = false
            }
        }
        .padding(6).frame(width: 240)
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !hovering, !showingModes, !showingPermission, !model.isMovingRecorder
            else { return }
            revealControls = false
        }
    }
}

/// The notch's shoulders meet the screen edge; the mini recorder floats with rounded ends.
struct RecorderSilhouette: Shape {
    var style: RecorderStyle

    func path(in rect: CGRect) -> Path {
        guard style == .notch else {
            return RoundedRectangle(cornerRadius: 14, style: .continuous).path(in: rect)
        }
        let shoulder: CGFloat = min(5, rect.height / 4)
        let radius: CGFloat = min(17, rect.height / 2)
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.minY + shoulder),
            control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: right - radius, y: rect.maxY),
            control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.maxY - radius),
            control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Each bar shows measured energy in one frequency band, from low to high.
struct RecorderWaveform: View {
    var bands: [Double]
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<AudioSpectrum.bandCount, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 4 + 17 * intensity(at: index))
            }
        }
        .frame(height: 22)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: bands)
        .accessibilityHidden(true)
    }

    private func intensity(at index: Int) -> Double {
        guard active, bands.indices.contains(index), bands[index].isFinite else { return 0 }
        return min(1, max(0, bands[index]))
    }
}

private struct RecorderModeRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10).frame(height: 34)
            .background(
                .primary.opacity(hovering ? 0.12 : selected ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
