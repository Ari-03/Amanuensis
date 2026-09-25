import AppKit
import SwiftUI

@main
struct AmanuensisApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Amanuensis", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    model.refreshAccessibility()
                }
                .onReceive(NotificationCenter.default.publisher(for: .amanuensisStorageError)) { note in
                    model.errorMessage = note.object as? String
                }
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…", action: showSettings).keyboardShortcut(",")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    model.updater.checkForUpdates()
                    showSettings()
                }
            }
        }
        MenuBarExtra("Amanuensis", systemImage: model.phase == .recording ? "record.circle.fill" : "waveform")
        {
            MenuBarContent(model: model)
        }
    }

    private func showSettings() {
        model.selectedSection = .configuration
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
    }
}

private struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusMessage)
        Button(model.phase == .recording ? "Finish recording" : "Start recording") {
            model.toggleRecording()
        }.disabled(model.phase.isBusy && model.phase != .recording)
        if model.phase.isBusy {
            Button("Cancel", role: .destructive) { model.cancelRecording() }
        }
        Divider()
        ForEach(model.modes) { mode in
            Button {
                model.selectMode(mode.id)
            } label: {
                if mode.id == model.currentMode.id {
                    Label(mode.name, systemImage: "checkmark")
                } else {
                    Text(mode.name)
                }
            }.disabled(model.phase.isBusy)
        }
        Divider()
        if case .ready(let release) = model.updater.state {
            Button("Restart to update to \(release.version)") { model.updater.installAndRelaunch() }
                .disabled(model.phase.isBusy)
        }
        Button("Open Amanuensis") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Amanuensis") { ApplicationDelegate.requestTermination() }.keyboardShortcut("q")
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var waitingToQuit = false

    /// AppKit's delayed-quit modal loop must start after the calling Swift task returns,
    /// so main-actor cleanup tasks can run and reply to the termination request.
    static func requestTermination() {
        RunLoop.main.perform {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await SmokeLaunch.runIfRequested() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if !waitingToQuit {
            waitingToQuit = true
            Task {
                await model.preserveUnfinishedRecording()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
