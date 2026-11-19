import AppKit
import QuartzCore
import RabeKit
import SwiftUI

// MARK: - ⌘K command palette

struct CommandPalette: View {
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool
    private var model: AppModel { AppModel.shared }

    private var matches: [AppAction] {
        let all = ActionDispatcher.paletteActions
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) }
            .sorted { ($0.title.lowercased().hasPrefix(q) ? 0 : 1) < ($1.title.lowercased().hasPrefix(q) ? 0 : 1) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "command").foregroundStyle(theme.ink3.color)
                    TextField("Befehl oder Ansicht …", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { run() }
                        .onKeyPress(.downArrow) { index = min(index + 1, matches.count - 1); return .handled }
                        .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onChange(of: query) { _, _ in index = 0 }
                        .accessibilityLabel("Befehlspalette")
                }
                .padding(14)
                Divider().overlay(theme.line.color)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(matches.enumerated()), id: \.offset) { i, action in
                                Button { index = i; run() } label: {
                                    HStack {
                                        Text(action.title)
                                        Spacer()
                                        if !action.keyHint.isEmpty { KeyCap(action.keyHint) }
                                    }
                                    .padding(.horizontal, 10).frame(height: 30)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(i == index ? theme.sel.color : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(i)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: index) { _, i in proxy.scrollTo(i) }
                }
            }
            .foregroundStyle(theme.ink.color)
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.line.color, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
    }

    private func run() {
        guard matches.indices.contains(index) else { return }
        let action = matches[index]
        close()
        ActionDispatcher.perform(action)
    }

    private func close() {
        model.paletteOpen = false
        model.mailbox.focusList()
    }
}

// MARK: - `?` shortcut sheet (mockup `.sheet`)

struct ShortcutSheet: View {
    @Environment(\.theme) private var theme
    /// TASTATUR.md: list, open thread, draft, everywhere.
    private let sections: [(String, [(String, [String])])] = [
        ("Liste", [
            ("Nächster / voriger Thread", ["↓", "↑", "J", "K"]), ("Seite weiter / zurück", ["Bild↓", "Bild↑"]),
            ("Erster / letzter Thread", ["Pos1", "Ende"]), ("Aufklappen", ["↵", "O", "Space"]),
        ]),
        ("Thread aufgeklappt", [
            ("In der Nachricht / nächste", ["↓", "↑", "J", "K"]), ("Seitenweise", ["Bild↓", "Bild↑"]),
            ("Erste / letzte Nachricht", ["Pos1", "Ende"]), ("Zuklappen", ["↵", "Esc"]),
            ("Ersten Anhang öffnen", ["O"]), ("", []),
        ]),
        ("Antworten (auf die fokussierte Nachricht)", [
            ("Antworten", ["A", "R"]), ("Allen antworten", ["⇧A", "⇧R"]),
            ("Weiterleiten", ["W", "F"]), ("Senden", ["⌘", "↵"]),
            ("Entwurf verwerfen", ["Esc"]), ("Rückgängig", ["Z"]),
        ]),
        ("Thread", [
            ("Erledigt", ["E"]), ("Papierkorb", ["#", "⌫"]),
            ("Später (morgen 8:00)", ["H"]), ("Markieren", ["S"]),
            ("Gelesen / ungelesen", ["U"]), ("Neue E-Mail", ["C"]),
        ]),
        ("Überall", [
            ("Suchen", ["/"]), ("Tab wechseln", ["Tab", "⇧Tab"]),
            ("Befehlspalette", ["⌘", "K"]), ("Diese Übersicht", ["?"]),
        ]),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { AppModel.shared.shortcutsOpen = false }
            VStack(alignment: .leading, spacing: 10) {
                Text(Strings.shortcuts).font(.system(size: 16, weight: .semibold))
                ForEach(sections, id: \.0) { section in
                    Text(section.0.uppercased(with: Format.locale))
                        .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(theme.ink3.color)
                        .padding(.top, 4)
                    Grid(horizontalSpacing: 28, verticalSpacing: 0) {
                        ForEach(0..<(section.1.count / 2), id: \.self) { row in
                            GridRow {
                                cell(section.1[row * 2])
                                cell(section.1[row * 2 + 1])
                            }
                        }
                    }
                }
            }
            .foregroundStyle(theme.ink.color)
            .padding(EdgeInsets(top: 20, leading: 26, bottom: 20, trailing: 26))
            .frame(width: 620)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface.color))
            .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
            .onKeyPress(.escape) { AppModel.shared.shortcutsOpen = false; return .handled }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.shortcuts)
    }

    private func cell(_ item: (String, [String])) -> some View {
        HStack {
            Text(item.0)
            Spacer()
            HStack(spacing: 4) { ForEach(item.1, id: \.self) { KeyCap($0) } }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 0.5) }
    }
}

// MARK: - ⌥⌘P hang overlay (NSView.displayLink)

@MainActor
@Observable
final class FrameMonitor {
    static let shared = FrameMonitor()
    private(set) var hangs = 0
    private(set) var longestMs: Double = 0
    private(set) var frames = 0
    private var last: CFTimeInterval = 0
    private var link: CADisplayLink?

    func attach(to view: NSView) {
        guard link == nil else { return }
        PerfLog.shared.write("frame_monitor attached")
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func reset() { hangs = 0; longestMs = 0; frames = 0; last = 0 }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else { return }
        let dt = (now - last) * 1000
        frames += 1
        // A frame longer than one refresh at 60 Hz plus a little slack counts as a hang.
        if dt > 16.7 * 1.5 { hangs += 1; PerfLog.shared.write(String(format: "hang ms=%.1f threads=%d loading=%@", dt, AppModel.shared.mailbox.threads.count, AppModel.shared.mailbox.isLoading ? "1" : "0")) }
        if dt > longestMs, dt < 2000 { longestMs = dt }
    }

    func logSummary(_ label: String) {
        PerfLog.shared.write("frames label=\(label) frames=\(frames) hangs=\(hangs) longest_ms=\(String(format: "%.1f", longestMs))")
    }
}

struct PerfOverlayView: View {
    private var monitor: FrameMonitor { FrameMonitor.shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Hänger: \(monitor.hangs)")
            Text("Längster Frame: \(String(format: "%.1f", monitor.longestMs)) ms")
            Text("Frames: \(monitor.frames)")
            if let ms = AppModel.shared.mailbox.firstListMs { Text("Erste Liste: \(ms) ms") }
            HStack {
                Button("Zurücksetzen") { monitor.reset() }
                Button("Loggen") { monitor.logSummary("overlay") }
            }
            .buttonStyle(.link)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.75)))
        .background(DisplayLinkHost())
        .allowsHitTesting(true)
    }
}

/// Attaches the display link to a view in the window.
struct DisplayLinkHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { FrameMonitor.shared.attach(to: v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Account sheet (IMAP with app password)

struct AccountSheet: View {
    @Environment(\.theme) private var theme
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "587"
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Konto hinzufügen").font(.system(size: 17, weight: .semibold))
            Text("IMAP mit App-Passwort. Gmail und Microsoft per Anmeldung folgen später.")
                .foregroundStyle(.secondary).font(.system(size: 12))
            Form {
                TextField("E-Mail-Adresse", text: $email).onChange(of: email) { _, v in guess(v) }
                TextField("Name (optional)", text: $name)
                SecureField("App-Passwort", text: $password)
                TextField("IMAP-Server", text: $imapHost)
                TextField("IMAP-Port", text: $imapPort)
                TextField("SMTP-Server", text: $smtpHost)
                TextField("SMTP-Port", text: $smtpPort)
            }
            .formStyle(.grouped)
            if let status { Text(status).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Button("Abbrechen") { AppModel.shared.accountSheetOpen = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Verbindung testen") { Task { await test() } }.disabled(busy || !valid)
                Button("Hinzufügen") { Task { await add() } }.keyboardShortcut(.defaultAction).disabled(busy || !valid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var valid: Bool { email.contains("@") && !password.isEmpty && !imapHost.isEmpty && !smtpHost.isEmpty }

    private var args: AddPasswordAccountArgs {
        AddPasswordAccountArgs(email: email, displayName: name.isEmpty ? nil : name, username: email, password: password,
                               imapHost: imapHost, imapPort: Int(imapPort) ?? 993, smtpHost: smtpHost, smtpPort: Int(smtpPort) ?? 587)
    }

    /// Common hosts for the domain (iCloud, Gmail, Outlook, GMX, web.de, posteo).
    private func guess(_ address: String) {
        guard let domain = address.split(separator: "@").last?.lowercased(), imapHost.isEmpty || smtpHost.isEmpty else { return }
        let known: [String: (String, String)] = [
            "icloud.com": ("imap.mail.me.com", "smtp.mail.me.com"), "me.com": ("imap.mail.me.com", "smtp.mail.me.com"),
            "gmail.com": ("imap.gmail.com", "smtp.gmail.com"), "outlook.com": ("outlook.office365.com", "smtp.office365.com"),
            "gmx.de": ("imap.gmx.net", "mail.gmx.net"), "web.de": ("imap.web.de", "smtp.web.de"), "posteo.de": ("posteo.de", "posteo.de"),
        ]
        if let (i, s) = known[domain] { imapHost = i; smtpHost = s }
    }

    private func test() async {
        guard let client = AppModel.shared.client else { return }
        busy = true; defer { busy = false }
        status = "Teste Verbindung …"
        do {
            let result = try await client.testConnection(args)
            status = result.ok ? "Verbindung klappt." : "Verbindung fehlgeschlagen: \(result.error ?? "")"
        } catch { status = RabeClientError.from(error).errorDescription }
    }

    private func add() async {
        guard let client = AppModel.shared.client else { return }
        busy = true; defer { busy = false }
        do {
            try await client.addAccount(args)
            AppModel.shared.accountSheetOpen = false
            await AppModel.shared.mailbox.bootstrap()
        } catch { status = RabeClientError.from(error).errorDescription }
    }
}

// MARK: - Settings window (⌘,), M1 items only

struct SettingsView: View {
    private var model: AppModel { AppModel.shared }
    private let accents = ["violet", "blue", "teal", "green", "amber", "orange", "rose", "graphite"]
    private let accentNames = ["violet": "Theme-Standard", "blue": "Blau", "teal": "Petrol", "green": "Grün", "amber": "Bernstein",
                               "orange": "Orange", "rose": "Rosé", "graphite": "Graphit"]

    var body: some View {
        let s = model.settings
        Form {
            Picker("Darstellung", selection: Binding(get: { s.themeID }, set: { s.set("theme", $0.rawValue) })) {
                ForEach(ThemeID.allCases) { Text($0.title).tag($0) }
            }
            Picker("Akzentfarbe", selection: Binding(get: { s.accentKey }, set: { s.set("accentColor", $0) })) {
                ForEach(accents, id: \.self) { Text(accentNames[$0] ?? $0).tag($0) }
            }
            Picker("Senden rückgängig machen", selection: Binding(get: { s.undoSendSeconds }, set: { s.set("undoSendSeconds", $0) })) {
                ForEach([5, 10, 20, 30], id: \.self) { Text("\($0) Sekunden").tag($0) }
            }
            Toggle("Bilder aus dem Internet automatisch laden", isOn: Binding(get: { s.loadRemoteImages }, set: { s.set("loadRemoteImages", $0) }))
            Toggle("Mitteilungen bei neuer E-Mail", isOn: Binding(get: { s.notificationsEnabled }, set: { s.set("notificationsEnabled", $0) }))
            if model.writeAccess.showsReadOnlyHint {
                Text("Nur-Lesen-Modus: Einstellungen lassen sich nicht ändern.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .disabled(!s.loaded)
    }
}
