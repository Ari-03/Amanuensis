import SwiftUI

/// One downloadable model: its name and size, a Download button, and `ModelDownloadStatus` under the
/// name and any note. Callers pass `ModelLibrary`'s progress, kept bytes and error for the model, so every row
/// showing the same model shows the same download. The button says Retry only when a stopped download
/// kept bytes on disk to continue from; after any other failure, such as an import, it says Download.
struct ModelDownloadRow: View {
    let descriptor: ModelDescriptor
    let progress: DownloadProgress?
    var resumable: DownloadProgress? = nil
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
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ModelDownloadStatus(
                    name: descriptor.name, progress: progress, resumable: resumable, error: error,
                    onCancel: onCancel)
            }
            Spacer(minLength: 8)
            if progress == nil {
                Button(resumable != nil ? "Retry" : downloadTitle, action: onDownload)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A download's state under a model's name: byte progress with Cancel while it runs, or what a failed
/// download kept with Discard. Both buttons sit beside the byte count, away from where Download was,
/// so a double-click on Download cannot cancel the download it just started.
struct ModelDownloadStatus: View {
    let name: String
    let progress: DownloadProgress?
    let resumable: DownloadProgress?
    let error: String?
    let onCancel: () -> Void

    var body: some View {
        if let progress {
            ProgressView(value: progress.fraction).progressViewStyle(.linear)
                .accessibilityLabel("Downloading \(name)")
                .accessibilityValue(progress.label)
            HStack(spacing: 10) {
                Text(progress.label).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel", action: onCancel).controlSize(.small)
            }
        } else if let resumable {
            HStack(spacing: 10) {
                Text("\(resumable.label) kept. Retry continues from there.")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button("Discard", action: onCancel).controlSize(.small)
                    .help("Delete the partly downloaded files")
            }
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}
