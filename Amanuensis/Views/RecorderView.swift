import AppKit
import SwiftUI

struct RecorderView: View {
    @Bindable var model: AppModel
    @State private var hovering = false
    @State private var showingModes = false
    @GestureState private var dragging = false
    @State private var revealControls = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlsSize = CGSize(width: 62, height: 26)
    @State private var activitySize = CGSize(width: 156, height: 26)
    @State private var outcomeSize = CGSize(width: 156, height: 26)
    @State private var collapseTask: Task<Void, Never>?

    /// `revealControls` starts the view in the state hovering produces. Native checks use it because
    /// events they post cannot trigger SwiftUI hover.
    init(model: AppModel, revealControls: Bool = false) {
        _model = Bindable(model)
        _revealControls = State(initialValue: revealControls)
    }

    /// A finished job's outcome replaces the hover controls until it closes. Cleaning keeps one layout,
    /// so Skip and cancel stay where the pointer found them.
    private var isOpen: Bool {
        model.isCancellationPending
            || (model.recorderOutcome == nil && model.phase != .cleaning
                && (revealControls || showingModes))
    }

    private var isMinimized: Bool { !isOpen && !model.phase.isBusy && model.recorderOutcome == nil }
    private var showsOutcome: Bool { !isOpen && model.recorderOutcome != nil }
    private var isCompact: Bool { !isOpen && !isMinimized && !showsOutcome }
    private var style: RecorderStyle {
        // Confirmation and failures need more room than the camera-side menu bar can guarantee.
        RecorderLayout.presentedStyle(
            saved: model.settings.recorderStyle, alwaysShow: model.settings.alwaysShowRecorder,
            busy: model.phase.isBusy, cancellationPending: model.isCancellationPending,
            outcome: model.recorderOutcome) ?? model.settings.recorderStyle
    }
    private var idleSize: CGSize { RecorderLayout.idleSize(for: style) }
    private var activeSize: CGSize { RecorderLayout.activeSize(for: style) }
    private var silhouette: RecorderSilhouette { RecorderSilhouette(style: style) }

    private var recordingLabel: String {
        model.phase == .recording ? "Finish recording" : "Start recording"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                expandedContents
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
                    .opacity(isCompact ? 1 : 0)
                    .allowsHitTesting(isCompact)
                    .accessibilityHidden(!isCompact)
                if let outcome = model.recorderOutcome {
                    outcomeContents(outcome)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(showsOutcome ? 1 : 0)
                        .allowsHitTesting(showsOutcome)
                        .accessibilityHidden(!showsOutcome)
                }
                minimizedContents
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(isMinimized ? 1 : 0)
                    .allowsHitTesting(isMinimized)
                    .accessibilityHidden(!isMinimized)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(.black, in: silhouette)
            .overlay {
                if showsOutcome && [.failure, .warning].contains(model.recorderOutcome?.kind) {
                    // The clip below keeps the inner half of this stroke.
                    silhouette.stroke(.orange.opacity(0.85), lineWidth: 2)
                }
            }
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
            model.setRecorderHovering(inside)
            if inside {
                model.refreshAccessibility()
                collapseTask?.cancel()
                // Hovering an outcome keeps it on screen instead of swapping in the controls.
                if model.recorderOutcome == nil { revealControls = true }
            } else {
                scheduleCollapse()
            }
        }
        .onAppear { updateSize() }
        .onChange(of: isOpen) { _, _ in updateSize() }
        .onChange(of: controlsSize) { _, _ in updateSize() }
        .onChange(of: activitySize) { _, _ in updateSize() }
        .onChange(of: outcomeSize) { _, _ in updateSize() }
        .onChange(of: model.recorderOutcome) { _, _ in updateSize() }
        .onChange(of: model.phase) { _, _ in updateSize() }
        .onChange(of: style) { _, _ in updateSize() }
        .onChange(of: showingModes) { _, showing in
            if !showing { scheduleCollapse() }
        }
        .onChange(of: model.isMovingRecorder) { _, moving in
            if moving {
                collapseTask?.cancel()
                showingModes = false
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
            let content = isOpen ? controlsSize : showsOutcome ? outcomeSize : activitySize
            model.resizeRecorder(
                to: CGSize(
                    width: max(
                        model.phase.isBusy || showsOutcome ? activeSize.width : idleSize.width,
                        ceil(content.width) + (isOpen ? 24 : 0)),
                    height: max(activeSize.height, ceil(content.height) + 12)))
        }
    }

    private var minimizedContents: some View {
        Button(action: model.toggleRecording) {
            Capsule()
                .fill(.white.opacity(0.8))
                .frame(width: 24, height: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(silhouette)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start recording")
        .accessibilityHint("Hover or use actions to show recorder controls.")
        .accessibilityActions {
            Button("Show recorder controls") { revealControls = true }
        }
        .help("Click to record. Hover for controls.")
    }

    /// Recording shows the active recording's mode and elapsed time; processing shows its phase.
    /// Cleaning also holds Skip and cancel, since hover does not open the controls then.
    /// Only recording is clickable as a whole, to finish.
    private var compactContents: some View {
        Group {
            if model.phase == .recording {
                Button(action: model.toggleRecording) { compactRow.contentShape(silhouette) }
                    .buttonStyle(.plain)
            } else {
                compactRow.accessibilityElement(children: .ignore)
            }
        }
        .accessibilityLabel(model.phase == .recording ? recordingLabel : model.phase.rawValue)
        .accessibilityValue(
            model.phase == .recording
                ? "\(model.currentMode.name), \(durationLabel(model.recordingDuration))" : ""
        )
        .accessibilityHint(
            style == .mini
                ? "Use actions for more recorder controls. Drag to reposition."
                : "Use actions for more recorder controls."
        )
        .accessibilityActions {
            if model.phase == .cleaning {
                Button("Skip cleanup", action: model.skipCleanup)
            } else {
                Button("Show recorder controls") { revealControls = true }
            }
            if model.phase.isBusy && model.phase != .delivering {
                Button("Cancel recording", action: model.requestCancelRecording)
            }
        }
        .help(
            model.phase == .recording
                ? "Click to finish recording. Hover for controls." : "Hover for controls.")
    }

    private var compactRow: some View {
        HStack(spacing: 10) {
            if model.phase == .recording {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18)
                modeBadge
                RecorderWaveform(bands: model.recordingSpectrum, active: true)
                Text(durationLabel(model.recordingDuration))
                    .font(.system(size: 11)).monospacedDigit().fixedSize()
            } else {
                ProgressView().controlSize(.mini)
                Text(model.phase.rawValue).font(.system(size: 11)).fixedSize()
                if model.phase == .cleaning {
                    RecorderChipButton(title: "Skip", action: model.skipCleanup)
                        .help("Skip cleanup and use the original transcript")
                    Button(action: model.requestCancelRecording) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 18, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Cancel recording")
                }
            }
        }
        .padding(.leading, style == .notch ? 20 : 14)
        .padding(.trailing, style == .notch ? 20 : model.phase == .cleaning ? 8 : 14)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            activitySize = $0
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The mode of the active recording, which automatic app modes may have chosen.
    /// Notch has little room beside the camera, so it shows only the icon.
    private var modeBadge: some View {
        let mode = model.currentMode
        return HStack(spacing: 4) {
            Image(systemName: mode.symbol).font(.system(size: 11, weight: .medium))
            if style != .notch {
                Text(mode.name.count > 16 ? mode.name.prefix(15) + "…" : mode.name)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
            }
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    /// How the last job ended, with its one action. Failures also offer a dismiss control.
    private func outcomeContents(_ outcome: RecorderOutcome) -> some View {
        let (symbol, tint): (String, Color) =
            switch outcome.kind {
            case .success: ("checkmark", .green)
            case .notice: ("info.circle", .white.opacity(0.7))
            case .warning, .failure: ("exclamationmark.triangle.fill", .orange)
            }
        return HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(outcome.label).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
            if let action = outcome.action {
                RecorderChipButton(title: action.title, action: model.performOutcomeAction)
            }
            if outcome.kind == .failure {
                Button(action: model.dismissOutcome) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
        }
        .padding(.leading, style == .notch ? 20 : 14)
        .padding(.trailing, style == .notch ? 20 : outcome.kind == .failure ? 8 : 14)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            outcomeSize = $0
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(outcome.label)
    }

    @ViewBuilder
    private var expandedContents: some View {
        if model.isCancellationPending {
            HStack(spacing: 12) {
                Text("Cancel transcription? Press Esc again to discard.")
                    .font(.system(size: 12)).fixedSize()
                Button("Keep going", action: model.dismissCancellation)
                    .font(.system(size: 12, weight: .medium))
                Button(action: model.requestCancelRecording) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        .frame(width: 22, height: 26).contentShape(Rectangle())
                }
                .foregroundStyle(.orange)
                .accessibilityLabel("Discard transcription")
                .help("Discard transcription")
            }
            .buttonStyle(.plain)
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
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
                RecorderModeMenu(model: model) { showingModes = false }
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

            if !model.phase.isBusy && !model.accessibilityGranted && model.currentMode.autoPaste {
                Button {
                    showingModes = false
                    model.requestAccessibility()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .frame(width: 22, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Allow automatic paste in Accessibility settings")
                .help("Automatic paste needs Accessibility access. Click to open Accessibility settings.")
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
                Button(action: model.requestCancelRecording) {
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

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !hovering, !showingModes, !model.isMovingRecorder
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

/// A small outlined button for the pill's one action, such as Skip or Open Models.
private struct RecorderChipButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).frame(height: 20)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.4)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// The recorder's mode popover. A mode that cannot record yet stays selectable and names what it needs.
struct RecorderModeMenu: View {
    @Bindable var model: AppModel
    let dismiss: () -> Void

    var body: some View {
        let blockers = model.modeBlockers
        VStack(spacing: 4) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.modes) { mode in
                        RecorderModeRow(
                            title: mode.name, symbol: mode.symbol, reason: blockers[mode.id]?.shortReason,
                            selected: model.currentMode.id == mode.id
                        ) {
                            model.selectMode(mode.id)
                            dismiss()
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
                dismiss()
            }
        }
        .padding(6).frame(width: 240)
    }
}

private struct RecorderModeRow: View {
    let title: String
    let symbol: String
    var reason: String? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                // Both lines fit the row's fixed height, so rows with and without a reason line up.
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let reason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                    }
                }
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
        .accessibilityValue(reason ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
