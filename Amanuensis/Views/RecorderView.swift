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
    @State private var controlsSize = CGSize(width: 64, height: 26)
    @State private var collapseTask: Task<Void, Never>?

    private var isOpen: Bool {
        revealControls || showingModes || showingPermission || model.phase.isBusy
            || model.pasteNeedsAccessibility
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
                Button(action: model.toggleRecording) {
                    Color.clear
                        .frame(width: RecorderLayout.idleSize.width, height: RecorderLayout.idleSize.height)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start recording")
                .help("Click to record. Drag to choose a screen position.")
                .opacity(isOpen ? 0 : 1)
                .allowsHitTesting(!isOpen)
                .accessibilityHidden(isOpen)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
            .clipped()
        }
        .contentShape(Capsule())
        .highPriorityGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { model.moveRecorder(translation: $0.translation) }
                .onEnded { _ in model.finishMovingRecorder() }
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
            }
        }
        .onDisappear {
            collapseTask?.cancel()
            model.cancelMovingRecorder()
        }
    }

    private func updateSize() {
        model.resizeRecorder(
            to: isOpen
                ? CGSize(width: ceil(controlsSize.width) + 8, height: ceil(controlsSize.height) + 8)
                : RecorderLayout.idleSize)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                showingPermission = false
                showingModes.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: model.currentMode.preset.symbol)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .frame(width: 32, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.phase.isBusy)
            .accessibilityLabel("Change mode, current mode: \(model.currentMode.name)")
            .help("Change mode")
            .popover(
                isPresented: $showingModes,
                arrowEdge: (model.settings.recorderPlacement ?? defaultPlacement).y > 0.5 ? .bottom : .top
            ) {
                modeMenu
            }

            Button(action: model.toggleRecording) {
                Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.phase == .recording ? .red : .primary)
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain).disabled(model.phase.isBusy && model.phase != .recording)
            .accessibilityLabel(model.phase == .recording ? "Finish recording" : "Start recording")
            .help(model.phase == .recording ? "Finish recording" : "Start recording")

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
                        AudioLevelView(level: model.recordingLevel, active: true).frame(width: 36)
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

    private var defaultPlacement: RecorderPlacement {
        model.settings.recorderStyle == .notch ? .top : .bottom
    }

    private var popoverEdge: Edge {
        (model.settings.recorderPlacement ?? defaultPlacement).y > 0.5 ? .bottom : .top
    }

    private var modeMenu: some View {
        VStack(spacing: 4) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.modes) { mode in
                        RecorderModeRow(
                            title: mode.name, symbol: mode.preset.symbol,
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
