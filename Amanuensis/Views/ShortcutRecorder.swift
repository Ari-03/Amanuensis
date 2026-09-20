import AppKit
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var binding: ShortcutBinding
    var onChange: () -> Void
    var onEditing: (Bool) -> Void = { _ in }
    @State private var isEditing = false

    var body: some View {
        Button {
            isEditing = true
        } label: {
            Text(binding.display).font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 3)
        }
        .help("Click to record a different shortcut")
        .sheet(isPresented: $isEditing) {
            ShortcutCaptureSheet { result in
                if let result {
                    binding = result
                    onChange()
                }
                isEditing = false
            }
        }
        .onChange(of: isEditing) { _, value in onEditing(value) }
    }
}

struct OptionalShortcutRecorder: View {
    @Binding var binding: ShortcutBinding?
    var onChange: () -> Void
    var onEditing: (Bool) -> Void = { _ in }
    @State private var isEditing = false

    var body: some View {
        HStack {
            if binding != nil {
                Button {
                    binding = nil
                    onChange()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless).accessibilityLabel("Clear shortcut")
            }
            Button(binding?.display ?? "Record shortcut") { isEditing = true }
                .font(.system(.callout, design: .monospaced))
        }
        .sheet(isPresented: $isEditing) {
            ShortcutCaptureSheet { result in
                if let result {
                    binding = result
                    onChange()
                }
                isEditing = false
            }
        }
        .onChange(of: isEditing) { _, value in onEditing(value) }
    }
}

private struct ShortcutCaptureSheet: View {
    var onResult: (ShortcutBinding?) -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard").font(.system(size: 34)).foregroundStyle(.tint)
            Text("Press your shortcut").font(.title2.weight(.semibold))
            Text("Use Command, Option, or Control with a key.\nPress Escape to keep the current shortcut.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            KeyCapture(onResult: onResult).frame(height: 1)
            Button("Cancel") { onResult(nil) }.keyboardShortcut(.cancelAction)
        }.padding(32).frame(width: 380)
    }
}

private struct KeyCapture: NSViewRepresentable {
    let onResult: (ShortcutBinding?) -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onResult = onResult
        return view
    }
    func updateNSView(_ nsView: CaptureView, context: Context) { nsView.onResult = onResult }

    final class CaptureView: NSView {
        var onResult: ((ShortcutBinding?) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard event.keyCode != 53 else {
                onResult?(nil)
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return
            }
            var modifiers: UInt32 = 0
            var label = ""
            if flags.contains(.control) {
                modifiers |= 4096
                label += "⌃"
            }
            if flags.contains(.option) {
                modifiers |= 2048
                label += "⌥"
            }
            if flags.contains(.shift) {
                modifiers |= 512
                label += "⇧"
            }
            if flags.contains(.command) {
                modifiers |= 256
                label += "⌘"
            }
            let special: [UInt16: String] = [
                49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
            ]
            guard let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(),
                !key.isEmpty
            else { return }
            onResult?(
                ShortcutBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers, display: label + key))
        }
    }
}
