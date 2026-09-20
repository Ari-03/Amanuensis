import AppKit
import SwiftUI

struct RecorderView: View {
    @Bindable var model: AppModel
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 15) {
                Menu {
                    Button("Automatic app modes", systemImage: "arrow.triangle.branch") {
                        model.settings.automaticModeSelection = true
                    }
                    Divider()
                    ForEach(model.modes) { mode in
                        Button(mode.name, systemImage: mode.preset.symbol) { model.selectMode(mode.id) }
                    }
                } label: {
                    Image(systemName: model.currentMode.preset.symbol).font(
                        .system(size: 16, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.phase.isBusy)
                .help("Change mode")
                Button(action: model.toggleRecording) {
                    Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(model.phase == .recording ? .red : .primary)
                        .frame(width: 42, height: 42)
                        .background(.primary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain).disabled(model.phase.isBusy && model.phase != .recording)
                .help(model.phase == .recording ? "Finish recording" : "Start recording")
                if model.phase.isBusy {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(
                            model.phase == .recording
                                ? durationLabel(model.recordingDuration) : model.phase.rawValue
                        )
                        .font(.caption).monospacedDigit()
                        AudioLevelView(level: model.recordingLevel, active: model.phase == .recording)
                    }.frame(width: 76)
                    Button(action: model.cancelRecording) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Cancel recording")
                        .disabled(model.phase == .delivering)
                }
                Button {
                    expanded.toggle()
                } label: {
                    Image(
                        systemName: expanded
                            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }.buttonStyle(.plain).help(expanded ? "Collapse recorder" : "Expand recorder")
            }
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.currentMode.name).font(.headline)
                    Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
                    Label(
                        model.microphoneName,
                        systemImage: "mic"
                    ).font(.caption2).foregroundStyle(
                        .secondary)
                    if let entry = model.history.first, !entry.finalText.isEmpty, !model.phase.isBusy {
                        Text(entry.finalText).font(.callout).lineLimit(5).frame(
                            maxWidth: .infinity, alignment: .leading)
                        Button("Copy result", systemImage: "doc.on.doc") { model.copyText(entry.finalText) }
                    }
                    Button("Open app") {
                        model.selectedSection = .home
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first { !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
                    }.buttonStyle(.link)
                }.frame(width: 270, alignment: .leading)
            }
        }
        .padding(.horizontal, 17).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: expanded ? 22 : 40))
        .overlay(RoundedRectangle(cornerRadius: expanded ? 22 : 40).strokeBorder(.primary.opacity(0.12)))
        .fixedSize()
        .onAppear { expanded = model.settings.recorderStyle == .panel }
        .onChange(of: model.settings.recorderStyle) { _, style in expanded = style == .panel }
    }
}
