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

    /// M2.3: free text goes to `ai_command` (`lib/aiCommand.ts`). The row is
    /// offered below the matching commands, so a normal command still wins.
    private var aiRowVisible: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var rowCount: Int { matches.count + (aiRowVisible ? 1 : 0) }

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
                        .focusWhenShown($focused)
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
                            if aiRowVisible {
                                Button { index = matches.count; run() } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "sparkles").font(.system(size: 11))
                                            .foregroundStyle(theme.accent.color)
                                        Text("Mit KI ausführen: „\(query.trimmingCharacters(in: .whitespaces))“")
                                            .lineLimit(1)
                                        Spacer()
                                        Text("↵").font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(theme.ink3.color)
                                    }
                                    .padding(.horizontal, 10).frame(height: 30)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(index == matches.count ? theme.sel.color : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(matches.count)
                                .help("Den Text an die KI geben: Termin, Mail, Suche oder Ansicht")
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
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if aiRowVisible, index == matches.count, !trimmed.isEmpty {
            close()
            model.runAICommand(trimmed)
            return
        }
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

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { AppModel.shared.shortcutsOpen = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Strings.shortcuts).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("? oder ⌘/ schließt").font(.system(size: 11)).foregroundStyle(theme.ink3.color)
                }
                .padding(EdgeInsets(top: 18, leading: 26, bottom: 10, trailing: 26))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(ShortcutMap.sections.enumerated()), id: \.offset) { _, section in
                            Text(section.0.title.uppercased(with: Format.locale))
                                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                                .foregroundStyle(theme.ink3.color)
                                .padding(.top, 6)
                            ForEach(section.1) { shortcut in
                                HStack(alignment: .firstTextBaseline, spacing: 18) {
                                    Text(shortcut.action).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(ShortcutMap.keys(shortcut))
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(theme.ink2.color)
                                }
                                .padding(.vertical, 4)
                                .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 0.5) }
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 4, leading: 26, bottom: 22, trailing: 26))
                }
            }
            .foregroundStyle(theme.ink.color)
            .frame(width: min(760, geo.size.width - 48), height: min(620, geo.size.height - 48))
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface.color))
            .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
            .onKeyPress(.escape) { AppModel.shared.shortcutsOpen = false; return .handled }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.shortcuts)
        }
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

// MARK: - Account sheet (Google sign-in, IMAP with app password)

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
    /// M3.4: läuft gerade die Browser-Anmeldung? Dann steht dort „Warte auf
    /// Browser …“ mit „Abbrechen“ statt des Google-Knopfs.
    @State private var googleBusy = false
    @State private var googleStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Konto hinzufügen").font(.system(size: 17, weight: .semibold))
            Text("Mit Google anmelden, oder ein Konto per IMAP und App-Passwort hinzufügen.")
                .foregroundStyle(.secondary).font(.system(size: 12))
            googleSection
            Divider()
            Text("IMAP mit App-Passwort").font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
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

    // MARK: M3.4 — Google

    /// Die Client-ID aus den Einstellungen; `COMAIL_GOOGLE_CLIENT_ID` sticht sie
    /// aus, so wie im Kern (`GoogleOAuthSetup`).
    private var googleConfigured: Bool {
        GoogleOAuthSetup.isConfigured(
            stored: AppModel.shared.settings.raw[GoogleOAuthSetup.clientIDKey] as? String,
            environment: ProcessInfo.processInfo.environment)
    }

    private var googleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if googleBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Warte auf Browser …").font(.system(size: 12))
                    Spacer()
                    Button("Abbrechen") { Task { await cancelGoogle() } }
                }
            } else {
                Button {
                    Task { await startGoogle() }
                } label: {
                    Text("Mit Google anmelden").frame(maxWidth: .infinity)
                }
                .disabled(!googleConfigured)
                if !googleConfigured {
                    HStack(spacing: 6) {
                        Text(GoogleOAuthSetup.missingHint)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Einstellungen …") {
                            AppModel.shared.accountSheetOpen = false
                            SettingsNavigation.request(.accounts)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
            }
            if let googleStatus {
                Text(googleStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    /// Startet die Anmeldung. Die Zeilen im Log tragen nur Provider, Ergebnis,
    /// Dauer und einen Grund — nie Adresse, Code oder Token.
    private func startGoogle() async {
        guard let client = AppModel.shared.client else { return }
        googleBusy = true
        googleStatus = nil
        PerfLog.shared.write(OAuthLog.start(provider: OAuthProvider.gmail.rawValue))
        let started = Date()
        do {
            let account = try await client.startOAuth(provider: .gmail)
            PerfLog.shared.write(OAuthLog.done(ok: true, milliseconds: milliseconds(since: started)))
            googleStatus = "\(account.email) ist verbunden."
            AppModel.shared.toasts.show("\(account.email) verbunden")
            await AppModel.shared.mailbox.refreshAccounts()
            AppModel.shared.sync.refreshSoon()
            AppModel.shared.accountSheetOpen = false
        } catch {
            PerfLog.shared.write(OAuthLog.done(ok: false, milliseconds: milliseconds(since: started),
                                               reason: OAuthErrorText.reason(for: error)))
            googleStatus = OAuthErrorText.message(for: error)
        }
        googleBusy = false
    }

    private func cancelGoogle() async {
        PerfLog.shared.write(OAuthLog.cancel)
        if let client = AppModel.shared.client { try? await client.cancelOAuth() }
        // Den Text setzt der wartende `startGoogle`-Aufruf („sign-in cancelled“).
    }

    private func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
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
