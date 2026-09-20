import SwiftUI

struct VocabularyView: View {
    @Bindable var model: AppModel
    @State private var word = ""
    @State private var replacement = ""
    @State private var search = ""
    @State private var replacementsOnly = false
    @FocusState private var entryFocused: Bool
    private var entries: [VocabularyEntry] {
        model.vocabulary.filter {
            (!replacementsOnly || $0.replacement != nil)
                && (search.isEmpty || $0.word.localizedCaseInsensitiveContains(search)
                    || ($0.replacement?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ScreenHeader(
                title: "Your words, understood.",
                subtitle: "Keep names and specialist terms close. Fix recurring mistakes once.")
            SettingsCard {
                HStack {
                    TextField("Word or phrase", text: $word).focused($entryFocused)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("Replacement, optional", text: $replacement)
                    Button("Add", action: add).buttonStyle(.borderedProminent)
                        .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.textFieldStyle(.roundedBorder).onSubmit(add)
                Text(
                    "Words guide supported API speech models. Local speech models do not use vocabulary hints yet. Replacements work with every model and match whole words and phrases."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Show", selection: $replacementsOnly) {
                    Text("All words").tag(false)
                    Text("Replacements").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                TextField("Find a word", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            if entries.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "A vocabulary of your own" : "No matching words",
                    systemImage: "text.book.closed",
                    description: Text(
                        search.isEmpty
                            ? "Add your name, a project, or a phrase you use often."
                            : "Try another word or phrase.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HStack(spacing: 14) {
                        Text(entry.word).textSelection(.enabled)
                        if let replacement = entry.replacement {
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(replacement).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            model.removeVocabulary(entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel(
                            "Remove \(entry.word)")
                    }.padding(.vertical, 7)
                }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }.padding(28)
    }

    private func add() {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousCount = model.vocabulary.count
        model.addVocabulary(word: trimmed, replacement: trimmedReplacement.isEmpty ? nil : trimmedReplacement)
        guard model.vocabulary.count > previousCount else { return }
        word = ""
        replacement = ""
        entryFocused = true
    }
}
