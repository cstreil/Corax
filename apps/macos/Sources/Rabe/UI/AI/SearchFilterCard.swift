import RabeKit
import SwiftUI

/// The clarifying question `ai_search_filter` may answer with instead of a
/// query (`AiSearchFilter.ask`): a question plus selectable answers, and a free
/// text field in case none of them fits. Answering asks the model again with
/// the answer in `history`.
struct AISearchFilterCard: View {
    let question: AIFilterQuestion
    var onAnswer: (String) -> Void
    var onCancel: () -> Void
    @Environment(\.theme) private var theme
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AIBadge(label: "KI-Filter")
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.ink3.color)
                .help("Abbrechen")
            }
            Text(question.question)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(question.options) { option in
                        Button { onAnswer(option.value.isEmpty ? option.label : option.value) } label: {
                            HStack {
                                Text(option.label).font(.system(size: 12))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.hover.color))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Oder selbst formulieren …", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .focusWhenShown($focused)
                    .onSubmit { submitFreeText() }
                Button("Weiter") { submitFreeText() }
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line.color, lineWidth: 0.5))
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func submitFreeText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer(trimmed)
    }
}
