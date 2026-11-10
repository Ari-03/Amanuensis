import SwiftUI

/// One downloadable model: its name and size, a Download button, byte progress with Cancel, and the
/// last error. Callers pass `ModelLibrary`'s progress and error for the model, so every row showing
/// the same model shows the same download. Cancel sits beside the byte count, away from where Download
/// was, so a double-click on Download cannot cancel the download it just started.
struct ModelDownloadRow: View {
    let descriptor: ModelDescriptor
    let progress: DownloadProgress?
    let error: String?
    var downloadTitle = "Download"
    /// Extra context under the name, such as what happens when the download finishes.
    var note: String? = nil
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(descriptor.name).fontWeight(.medium)
                    if let size = descriptor.sizeLabel, !size.isEmpty {
                        Text(size).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let progress {
                    ProgressView(value: progress.fraction).progressViewStyle(.linear)
                        .accessibilityLabel("Downloading \(descriptor.name)")
                        .accessibilityValue(progress.label)
                    HStack(spacing: 10) {
                        Text(progress.label).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button("Cancel", action: onCancel).controlSize(.small)
                    }
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if progress == nil { Button(downloadTitle, action: onDownload) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
