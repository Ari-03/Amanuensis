import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var showOriginal = false
    @State private var pendingDeletion: RecordingEntry?
    @State private var pendingRetry: RecordingEntry?

    private var recordings: [RecordingEntry] {
        model.history.filter { entry in
            query.isEmpty || entry.preview.localizedCaseInsensitiveContains(query)
                || entry.rawText.localizedCaseInsensitiveContains(query)
                || entry.mode.name.localizedCaseInsensitiveContains(query)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private var selected: RecordingEntry? {
        recordings.first { $0.id == selectedID } ?? recordings.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScreenHeader(title: "History", subtitle: "Your words, whenever you need them.")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts or modes", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(11)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if model.history.isEmpty {
                ContentUnavailableView {
                    Label("Your first words go here", systemImage: "text.bubble")
                } description: {
                    Text(
                        "Start a recording and its transcript will be saved here. You can revisit the original words, copy the result, or try again."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if recordings.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    recordingList
                        .frame(minWidth: 210, idealWidth: 260, maxWidth: 300)
                    Divider()
                    if let entry = selected {
                        recordingDetail(entry)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(24)
        .alert(
            "Delete this recording?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let entry = pendingDeletion {
                    model.deleteRecording(entry.id)
                    if selectedID == entry.id { selectedID = nil }
                }
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the transcript and any saved audio. Your all-time usage totals are kept.")
        }
        .confirmationDialog(
            "Transcribe this recording again?",
            isPresented: Binding(
                get: { pendingRetry != nil },
                set: { if !$0 { pendingRetry = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Transcribe again") {
                guard let entry = pendingRetry else { return }
                pendingRetry = nil
                Task { await model.retryRecording(entry) }
            }
            Button("Cancel", role: .cancel) { pendingRetry = nil }
        } message: {
            Text(
                "The saved audio will use this recording's original model settings. API models send audio or transcript text to their provider. Your local-processing setting still applies. The new result stays in History and is not pasted."
            )
        }
    }

    private var recordingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text("\(recordings.count) recording\(recordings.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                ForEach(recordings) { entry in
                    Button {
                        selectedID = entry.id
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(
                                    entry.createdAt,
                                    format: .dateTime.month(.abbreviated).day().hour().minute()
                                )
                                .font(.caption)
                                Spacer(minLength: 4)
                                Image(systemName: entry.mode.preset.symbol)
                            }
                            .foregroundStyle(.secondary)
                            Text(entry.preview)
                                .font(.system(size: 13))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.mode.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(
                            selected?.id == entry.id ? Color.accentColor.opacity(0.11) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected?.id == entry.id ? .isSelected : [])
                    .contextMenu {
                        Button("Copy transcript") {
                            model.copyText(entry.finalText.isEmpty ? entry.rawText : entry.finalText)
                        }
                        .disabled(entry.finalText.isEmpty && entry.rawText.isEmpty)
                        Button("Delete recording", role: .destructive) { pendingDeletion = entry }
                    }
                }
            }
            .padding(10)
        }
    }

    private func recordingDetail(_ entry: RecordingEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.mode.name).font(.title3.weight(.semibold))
                    Text(
                        entry.createdAt,
                        format: .dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusLabel(entry.status))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            HStack(spacing: 14) {
                Label(durationLabel(entry.duration), systemImage: "waveform")
                Label(
                    "\(entry.finalText.split(whereSeparator: \.isWhitespace).count) words",
                    systemImage: "text.alignleft")
            }
            .font(.caption).foregroundStyle(.secondary)

            Picker("Transcript", selection: $showOriginal) {
                Text("Result").tag(false)
                Text("Original").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                let transcript = showOriginal ? entry.rawText : entry.finalText
                Text(
                    transcript.isEmpty
                        ? (entry.status == .empty && !showOriginal
                            ? "Nothing to insert. You can read the original transcript in Original."
                            : "No transcript available.")
                        : transcript
                )
                .font(.system(size: 15))
                .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let message = entry.deliveryMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Button {
                    model.copyText(showOriginal ? entry.rawText : entry.finalText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled((showOriginal ? entry.rawText : entry.finalText).isEmpty)
                Button {
                    pendingRetry = entry
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .disabled(entry.audioFileName == nil || model.phase.isBusy)
                .help(
                    entry.audioFileName == nil
                        ? "Saved audio is no longer available" : "Transcribe the saved audio again")
                Spacer()
                Button(role: .destructive) {
                    pendingDeletion = entry
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete recording")
                .accessibilityLabel("Delete recording")
            }
        }
        .padding(22)
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }

    private func statusLabel(_ status: RecordingStatus) -> String {
        switch status {
        case .noSpeech: "No speech"
        case .complete: "Saved"
        default: status.rawValue.capitalized
        }
    }
}
