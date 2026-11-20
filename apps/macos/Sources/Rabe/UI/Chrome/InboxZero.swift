import RabeKit
import SwiftUI

/// Empty list state (M2.5, `InboxZero` in Tauri): a check mark in the accent
/// colour, what is empty, and the three keys that get you out of it.
struct InboxZeroView: View {
    let viewTitle: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.accent.color.opacity(0.8))
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            Text("Alles erledigt")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text("Nichts Neues in \(viewTitle) — Stand \(Format.relative(Date())).")
                .font(.system(size: 13))
                .foregroundStyle(theme.ink2.color)
            HStack(spacing: 14) {
                hint("Tab", "nächster Tab")
                hint("C", "neue Mail")
                hint("?", "alle Kürzel")
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .combine)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(key)
            Text(text)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(theme.ink3.color)
    }
}
