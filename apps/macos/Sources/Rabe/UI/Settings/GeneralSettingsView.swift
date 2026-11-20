import RabeKit
import SwiftUI

/// General group: Darstellung, Mitteilungen, Lesen, Verfassen. Every control
/// writes through `SettingsStore` (N4: read-modify-write of the whole object).
struct GeneralSettingsView: View {
    let page: SettingsPage

    private var model: AppModel { AppModel.shared }
    private var s: SettingsStore { model.settings }

    private let accentKeys = ["violet", "blue", "teal", "green", "amber", "orange", "rose", "graphite"]
    private let accentNames = ["violet": "Theme-Standard", "blue": "Blau", "teal": "Petrol", "green": "Grün",
                               "amber": "Bernstein", "orange": "Orange", "rose": "Rosé", "graphite": "Graphit"]
    private let undoChoices = [5, 10, 20, 30]

    var body: some View {
        Form {
            if model.writeAccess.showsReadOnlyHint { WriteGateHint() }
            switch page {
            case .appearance: appearance
            case .notifications: notifications
            case .reading: reading
            case .compose: compose
            default: EmptyView()
            }
        }
        .formStyle(.grouped)
        .disabled(!s.loaded)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Darstellung

    @ViewBuilder
    private var appearance: some View {
        Section("Darstellung") {
            SettingPickerRow(title: "Design", hint: "Glas ist hell, Graphit ist dunkel.",
                             selection: Binding(get: { s.themeID }, set: { s.set("theme", $0.rawValue) })) {
                ForEach(ThemeID.allCases) { Text($0.title).tag($0) }
            }
            SettingPickerRow(title: "Akzentfarbe",
                             hint: "„Theme-Standard“ behält die Farbe des Designs.",
                             selection: Binding(get: { s.accentKey }, set: { s.set("accentColor", $0) })) {
                ForEach(accentKeys, id: \.self) { Text(accentNames[$0] ?? $0).tag($0) }
            }
            SettingPickerRow(title: "Sprache", hint: "„System“ übernimmt die Sprache deines Geräts. Weitere Sprachen folgen.",
                             selection: Binding(get: { s.languageChoice }, set: { s.setLanguage($0) })) {
                Text("System").tag(AILanguage.system)
                Text("Deutsch").tag("de")
            }
            SettingPickerRow(title: "Inbox-Ansicht", hint: "Lege fest, wie die E-Mail-Liste aussieht.",
                             selection: Binding(get: { s.inboxUI }, set: { s.set("inboxUi", $0) })) {
                Text("Klassisch").tag("classic")
                Text("Avatar").tag("avatar")
            }
            SettingToggleRow(title: "Fotos und Logos von Absendern zeigen",
                             hint: "Zeigt neben jedem Absender ein Foto oder Firmenlogo; sonst erscheinen Initialen.",
                             isOn: Binding(get: { s.showSenderPhotos }, set: { s.set("showSenderPhotos", $0) }))
            SettingToggleRow(title: "Nach Datum gruppieren",
                             hint: "Überschriften wie Heute, Gestern … zwischen den Unterhaltungen anzeigen.",
                             isOn: Binding(get: { s.groupByDate }, set: { s.set("groupByDate", $0) }))
        }
    }

    // MARK: Mitteilungen

    @ViewBuilder
    private var notifications: some View {
        Section("Mitteilungen") {
            SettingToggleRow(title: "Desktop-Benachrichtigungen",
                             hint: "Benachrichtigen, wenn neue E-Mails eintreffen, während das Fenster nicht im Vordergrund ist.",
                             isOn: Binding(get: { s.notificationsEnabled }, set: { s.set("notificationsEnabled", $0) }))
            SettingToggleRow(title: "Ton", hint: "Bei neuen E-Mails und beim Senden einen Ton abspielen.",
                             isOn: Binding(get: { s.soundEnabled }, set: { s.set("soundEnabled", $0) }))
            SettingToggleRow(title: "Bestätigungscodes kopieren",
                             hint: "Kommt ein Einmalcode an, wird er in die Zwischenablage kopiert und in der Benachrichtigung angezeigt.",
                             isOn: Binding(get: { s.copyVerificationCodes }, set: { s.set("copyVerificationCodes", $0) }))
            SettingToggleRow(title: "Dock-Badge", hint: "Anzahl ungelesener E-Mails auf dem App-Symbol anzeigen.",
                             isOn: Binding(get: { s.dockBadgeEnabled }, set: { s.set("dockBadgeEnabled", $0) }))
        }
    }

    // MARK: Lesen

    @ViewBuilder
    private var reading: some View {
        Section("Lesen") {
            SettingToggleRow(title: "Nach Auswahl weiter",
                             hint: "Nach dem Auswählen einer Unterhaltung mit X springt der Cursor zur nächsten Zeile. Aus: die Auswahl bleibt stehen (wie in Gmail).",
                             isOn: Binding(get: { s.selectAdvance }, set: { s.set("selectAdvance", $0) }))
            SettingToggleRow(title: "Externe Bilder laden",
                             hint: "Aus: Tracking-Pixel und externe Inhalte in HTML-E-Mails werden blockiert.",
                             isOn: Binding(get: { s.loadRemoteImages }, set: { s.set("loadRemoteImages", $0) }))
            SettingToggleRow(title: "Automatisch weiter",
                             hint: "Nach „Erledigt“ oder „Zurückstellen“ in einer Unterhaltung die nächste öffnen, statt zur Liste zurückzukehren.",
                             isOn: Binding(get: { s.autoAdvance }, set: { s.set("autoAdvance", $0) }))
        }
    }

    // MARK: Verfassen

    @ViewBuilder
    private var compose: some View {
        Section("Verfassen") {
            SettingPickerRow(title: "Zeitfenster für „Senden rückgängig“",
                             hint: "So lange lässt sich ein Versand mit Z abbrechen.",
                             selection: Binding(get: { s.undoSendSeconds }, set: { s.set("undoSendSeconds", $0) })) {
                ForEach(undoChoices, id: \.self) { Text("\($0) Sekunden").tag($0) }
            }
            SettingToggleRow(title: "Kontakte aus allen Konten vorschlagen",
                             hint: "Beim Verfassen werden Empfänger aus den Kontakten aller Konten vorgeschlagen. Aus: nur Kontakte des Kontos, von dem du sendest.",
                             isOn: Binding(get: { s.contactSuggestAllAccounts },
                                           set: { s.set("contactSuggestAllAccounts", $0) }))
        }
    }
}
