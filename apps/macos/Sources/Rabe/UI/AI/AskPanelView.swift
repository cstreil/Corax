import RabeKit
import SwiftUI

/// "Fragen an das Postfach" (`ai_ask`, Tauri's Ask mode in the search): a
/// question, the answer, and the source threads it cites. The citations open
/// the thread; the answer is not editable, because it is a read of the mailbox.
struct AskPanelView: View {
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var question = ""
    /// Height of the answer content, so the card is only as tall as it needs.
    @State private var contentHeight: CGFloat = 0

    private var model: AppModel { AppModel.shared }
    private var assistant: AIAssistStore { model.assistant }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { close() }
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(theme.line.color)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        answer
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        if abs(height - contentHeight) > 0.5 { contentHeight = height }
                    }
                }
                .frame(height: min(max(contentHeight, 70), 380))
            }
            .foregroundStyle(theme.ink.color)
            .frame(width: 620)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.line.color, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
            .padding(.top, 90)
        }
        .onAppear {
            focused = true
            if assistant.askStatus == .idle, !assistant.askQuestion.isEmpty { question = assistant.askQuestion }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AIBadge(label: Strings.aiAskTitle)
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.ink3.color)
                .help("Schließen (Esc)")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.ink3.color)
                TextField(Strings.aiAskPlaceholder, text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { run() }
                    .onKeyPress(.escape) { close(); return .handled }
                    .accessibilityLabel(Strings.aiAskPlaceholder)
                if assistant.askStatus == .pending || assistant.askStatus == .streaming {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Fragen") { run() }
                        .controlSize(.small)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.hover.color))
        }
        .padding(14)
    }

    @ViewBuilder private var answer: some View {
        switch assistant.askStatus {
        case .idle:
            Text("Frag nach etwas, das in deinen Mails steht – z. B. „Wann war der Termin mit dem Steuerberater?“ Antworten kommen mit Quellen.")
                .font(.system(size: 12))
                .foregroundStyle(theme.ink3.color)
        case .pending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sucht in den Mails …").foregroundStyle(theme.ink3.color)
            }
            .font(.system(size: 12))
        case .error:
            VStack(alignment: .leading, spacing: 10) {
                Text(assistant.askFailure?.text ?? "Die Frage konnte nicht beantwortet werden.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink2.color)
                if assistant.askFailure == .notConfigured {
                    Button(Strings.aiNeedsSetup) {
                        close()
                        SettingsNavigation.request(.intelligence)
                    }
                    .controlSize(.small)
                } else {
                    Button(Strings.aiRetry) { run() }.controlSize(.small)
                }
            }
        // M2.4: `.streaming` shows the answer while it is written; the final
        // response from `ai_ask` replaces it (same layout, one extra hint).
        case .done, .streaming:
            VStack(alignment: .leading, spacing: 14) {
                // M2.5: the answer is rendered as Markdown (`AttributedString`,
                // no network, no HTML) — Tauri runs its model output through the
                // same small subset (`src/components/common/Markdown.tsx`).
                MarkdownText(markdown: assistant.askAnswer, fontSize: 13, theme: theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if assistant.askStatus == .streaming {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Die Antwort entsteht …")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.ink3.color)
                }
                if !assistant.askCitations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Strings.aiSourcesTitle.uppercased(with: Format.locale))
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(theme.ink3.color)
                        ForEach(assistant.askCitations) { citation in
                            Button { open(citation) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(citation.subject.isEmpty ? "(kein Betreff)" : citation.subject)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(citation.from) · \(Format.messageTime(Date(timeIntervalSince1970: Double(citation.date) / 1000)))")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(theme.ink3.color)
                                        .lineLimit(1)
                                }
                                .padding(7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 7).fill(theme.hover.color))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Diesen Thread öffnen")
                            .accessibilityLabel("Quelle: \(citation.subject)")
                        }
                    }
                }
            }
        }
    }

    private func run() {
        let text = question
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await assistant.ask(text, accountId: model.mailbox.accountId) }
    }

    private func open(_ citation: AskCitation) {
        close()
        if model.calendarOpen { model.calendarOpen = false }
        model.mailbox.setView(.all)
        model.mailbox.select(citation.threadId)
        model.mailbox.expand(citation.threadId)
    }

    private func close() {
        model.askOpen = false
        assistant.resetAsk()
        model.mailbox.focusList()
    }
}
