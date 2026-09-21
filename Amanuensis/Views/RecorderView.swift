import AppKit
import SwiftUI

struct RecorderView: View {
    @Bindable var model: AppModel
    @State private var hovering = false
    @State private var showingModes = false
    @State private var dragging = false
    @State private var revealControls = false
    @State private var collapseTask: Task<Void, Never>?

    private var isOpen: Bool { revealControls || showingModes || dragging || model.phase.isBusy }

    var body: some View {
        VStack(spacing: 8) {
            if isOpen {
                controls
                if model.settings.recorderStyle == .panel {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.currentMode.name).font(.caption.weight(.medium))
                        Text(model.statusMessage).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 220, alignment: .leading)
                    .padding(.horizontal, 8).padding(.bottom, 6)
                }
            } else {
                Button(action: model.toggleRecording) {
                    HStack(spacing: 4) {
                        Circle().fill(.secondary).frame(width: 4, height: 4)
                        Capsule().fill(.secondary.opacity(0.6)).frame(width: 22, height: 3)
                    }
                    .frame(width: 58, height: 16).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start recording")
                .help("Start recording. Hover to choose a mode or move the bar.")
            }
        }
        .padding(isOpen ? 4 : 0)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.15)))
        .fixedSize()
        .onHover { inside in
            hovering = inside
            if inside {
                collapseTask?.cancel()
                revealControls = true
            } else {
                scheduleCollapse()
            }
        }
        .onChange(of: showingModes) { _, showing in
            if !showing { scheduleCollapse() }
        }
        .onChange(of: model.phase.isBusy) { _, busy in
            if busy { showingModes = false }
        }
        .onDisappear { collapseTask?.cancel() }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
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

            Image(systemName: "circle.grid.2x3.fill")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 16, height: 26)
                .overlay {
                    RecorderDragHandle { event in
                        dragging = true
                        collapseTask?.cancel()
                        model.moveRecorder(with: event)
                        dragging = false
                        scheduleCollapse()
                    }
                }
        }
    }

    private var defaultPlacement: RecorderPlacement {
        model.settings.recorderStyle == .notch ? .top : .bottom
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
            guard !Task.isCancelled, !hovering, !showingModes, !dragging else { return }
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
