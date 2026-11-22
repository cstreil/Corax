import CoraxKit
import SwiftUI

/// The AI marker: sparkle plus label in the accent colour. Every AI surface
/// uses it, so the feature reads as one system (`components/ui/Ai.tsx`).
struct AIBadge: View {
    var label = "KI"
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(theme.accent.color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("KI, \(label)")
    }
}

/// `ai_summarize` in the thread (`AiThreadSummary` in Tauri's
/// `ConversationScreen`): key points, the next action, the timeline and the
/// proposed reply. Loading, "not set up" and error states are distinct.
struct AISummaryBlock: View {
    let threadId: Int64
    var onUseReply: (String) -> Void
    var onCreateEvent: (AICalendarSuggestion) -> Void
    @Environment(\.theme) private var theme
    @State private var collapsed = false

    private var assistant: AIAssistStore { AppModel.shared.assistant }

    var body: some View {
        if let state = assistant.summaryState(threadId) {
            VStack(alignment: .leading, spacing: 0) {
                header(state)
                if !collapsed {
                    Divider().overlay(theme.line.color)
                    content(state)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.color.opacity(0.35), lineWidth: 0.8))
            .padding(.leading, 40)
            .padding(.top, 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("KI-Zusammenfassung")
        }
    }

    private func header(_ state: ThreadSummaryState) -> some View {
        HStack(spacing: 8) {
            Button { withAnimation(Motion.animation) { collapsed.toggle() } } label: {
                HStack(spacing: 8) {
                    AIBadge(label: Strings.aiSummaryTitle)
                    if state.pending { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Zusammenfassung ausklappen" : "Zusammenfassung einklappen")
            Button {
                withAnimation(Motion.animation) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink3.color)
            Button { assistant.dismissSummary(threadId) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink3.color)
            .help("Zusammenfassung schließen")
            .accessibilityLabel("Zusammenfassung schließen")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder private func content(_ state: ThreadSummaryState) -> some View {
        // M2.4: while the model writes, the finished parts already show — the
        // streamed JSON is read incrementally (`PartialSummary`).
        if let summary = state.summary ?? state.partial {
            VStack(alignment: .leading, spacing: 14) {
                if state.pending {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Die Zusammenfassung entsteht …").font(.system(size: 11)).foregroundStyle(theme.ink3.color)
                    }
                }
                summaryBody(summary)
            }
            .padding(12)
        } else if state.pending {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Strings.aiPending).foregroundStyle(theme.ink3.color)
            }
            .font(.system(size: 12))
            .padding(12)
        } else if let failure = state.failure {
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.text).font(.system(size: 12)).foregroundStyle(theme.ink2.color)
                HStack(spacing: 10) {
                    if state.needsSetup {
                        Button(Strings.aiNeedsSetup) { SettingsNavigation.request(.intelligence) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else {
                        Button(Strings.aiRetry) { Task { await assistant.summarize(threadId) } }
                            .controlSize(.small)
                    }
                }
            }
            .padding(12)
        }
    }

    /// Key points, next action, timeline, proposed reply and the event
    /// suggestion — the same drawing for the finished answer and for the
    /// streamed part.
    @ViewBuilder private func summaryBody(_ summary: AIThreadSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
                if !summary.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(theme.ink3.color).frame(width: 4, height: 4).padding(.top, 6)
                                Text(point).font(.system(size: 13)).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let next = summary.nextAction {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionTitle("Nächster Schritt")
                        Text(next)
                            .font(.system(size: 13))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.color.opacity(0.10)))
                    }
                }
                if !summary.timeline.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("Verlauf")
                        ForEach(Array(summary.timeline.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(theme.accent.color).frame(width: 5, height: 5).padding(.top, 5)
                                (Text(entry.actor).fontWeight(.medium) + Text(" " + entry.event))
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.ink2.color)
                            }
                        }
                    }
                }
                if let reply = summary.proposedReply {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("Vorgeschlagene Antwort")
                        Text(reply)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.ink2.color)
                            .lineLimit(6)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(theme.hover.color))
                        Button("In den Entwurf übernehmen") { onUseReply(reply) }
                            .controlSize(.small)
                    }
                }
                if let suggestion = summary.calendarSuggestion, summary.suggestedStart != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("Terminvorschlag")
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).font(.system(size: 12, weight: .medium))
                                Text(humanDate(suggestion))
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.ink3.color)
                            }
                            Spacer()
                            Button("Termin prüfen") { onCreateEvent(suggestion) }
                                .controlSize(.small)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line.color, lineWidth: 0.5))
                    }
                }
                if summary.isEmpty {
                    Text("Die KI hat nichts zusammenzufassen gefunden.")
                        .font(.system(size: 12)).foregroundStyle(theme.ink3.color)
                }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased(with: Format.locale))
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(theme.ink3.color)
    }

    private func humanDate(_ suggestion: AICalendarSuggestion) -> String {
        guard let start = AIDateParser.milliseconds(suggestion.start) else { return suggestion.start }
        return Format.messageTime(Date(timeIntervalSince1970: Double(start) / 1000))
    }
}
