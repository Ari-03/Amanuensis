import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 30)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Amanuensis").font(.headline)
                        Text("A little room to speak.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 16)
                List(selection: $model.selectedSection) {
                    Section {
                        ForEach([AppSection.home, .modes, .vocabulary, .models, .history]) { section in
                            Label(section.rawValue, systemImage: section.symbol).tag(section)
                        }
                    }
                    Section {
                        ForEach([AppSection.sound, .configuration]) { section in
                            Label(section.rawValue, systemImage: section.symbol).tag(section)
                        }
                    }
                }
                .listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 7) {
                    Label(
                        model.settings.requireLocalProcessing
                            ? "Local processing only" : "API models enabled",
                        systemImage: model.settings.requireLocalProcessing ? "lock.shield" : "network"
                    )
                    .font(.caption.weight(.medium))
                    Text(
                        model.settings.requireLocalProcessing
                            ? "Your recordings stay on this Mac."
                            : "Each mode controls where audio is processed."
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            model.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                    }
                    .padding(12).background(.orange.opacity(0.08))
                }
                Group {
                    switch model.selectedSection {
                    case .home: HomeView(model: model)
                    case .modes: ModesView(model: model)
                    case .vocabulary: VocabularyView(model: model)
                    case .models: ModelsView(model: model)
                    case .history: HistoryView(model: model)
                    case .sound: SoundView(model: model)
                    case .configuration: ConfigurationView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Color(red: 0.27, green: 0.43, blue: 0.86))
        .preferredColorScheme(
            model.settings.appearance == .system ? nil : model.settings.appearance == .dark ? .dark : .light
        )
        .frame(minWidth: 820, minHeight: 600)
    }
}
