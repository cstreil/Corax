import RabeKit
import SwiftUI

/// System group → Intelligenz (M2.3, requirement 6): status, keys, model,
/// usage, voice, semantic index and the decision provider. The two key fields
/// are `SecureField`s: the value is passed straight to `set_ai_key` /
/// `set_decision_key`, never read back and never shown again.
struct IntelligenceSettingsView: View {
    private var model: AppModel { AppModel.shared }
    private var s: SettingsStore { model.settings }
    private var ai: AIStore { model.ai }
    private var assistant: AIAssistStore { model.assistant }

    @State private var apiKey = ""
    @State private var decisionKey = ""
    @State private var decisionProvider = "openrouter"
    @State private var baseURL = ""
    @State private var modelID = ""
    @State private var savingKey = false
    @State private var savingDecisionKey = false

    /// Providers the chat client speaks (`AI_PROVIDER_PRESETS` in the Tauri panel).
    private let providers: [(id: String, label: String, baseURL: String, model: String)] = [
        ("apple", "Apple Intelligence (auf dem Gerät)", "apple://intelligence", "apple-intelligence"),
        ("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "openai/gpt-6-luna"),
        ("commandcode", "Command Code", "https://api.commandcode.ai/provider/v1", "deepseek/deepseek-v4.1-flash"),
        ("custom", "Eigener OpenAI-kompatibler Endpunkt", "", ""),
    ]

    /// Decision providers `set_decision_key` accepts (`DecisionProvider` in the host).
    private let decisionProviders: [(id: String, label: String)] = [
        ("openrouter", "OpenRouter (TypeSafe Jev)"),
        ("openai", "OpenAI Decisions API"),
        ("commandcode", "Command Code System One"),
        ("custom", "Eigener Endpunkt"),
    ]

    private var onDevice: Bool { AIStatus.isAppleBaseURL(baseURL) }
    private var currentProvider: String {
        providers.first { $0.baseURL == baseURL && !$0.baseURL.isEmpty }?.id ?? "custom"
    }

    var body: some View {
        Form {

            statusSection
            keySection
            voiceSection
            usageSection
            embeddingSection
            decisionSection
        }
        .formStyle(.grouped)
        .disabled(!s.loaded)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            baseURL = s.aiBaseUrl
            modelID = s.aiModel
            decisionProvider = s.decisionProvider == "off" ? "openrouter" : s.decisionProvider
            await ai.refresh()
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section("Status") {
            SettingRow(title: "KI",
                       hint: "Modelle, Zusammenfassungen, Entwürfe, Ask und die Suche mit KI brauchen einen eingerichteten Anbieter.") {
                HStack(spacing: 7) {
                    Circle()
                        .fill(ai.isConfigured ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(ai.isConfigured ? .primary : .secondary)
                }
            }
            if let failure = ai.lastFailure {
                Text(failure.text).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            SettingHintRow(title: "Kein echter Aufruf beim Öffnen",
                           hint: "Diese Seite liest nur den Status. Ein Modellaufruf passiert erst, wenn du eine KI-Funktion auslöst.")
        }
    }

    private var statusText: String {
        guard let status = ai.status else {
            return ai.loadingStatus ? "Wird geprüft …" : "Unbekannt"
        }
        if status.usesAppleIntelligence {
            return status.configured ? "Apple Intelligence bereit" : appleState(status.appleIntelligence)
        }
        return status.configured ? "Eingerichtet – \(status.model)" : "Nicht eingerichtet"
    }

    private func appleState(_ raw: String) -> String {
        switch raw {
        case "available": "Apple Intelligence bereit"
        case "deviceNotEligible": "Dieser Mac kann Apple Intelligence nicht"
        case "notEnabled": "Apple Intelligence ist in den Systemeinstellungen aus"
        case "modelNotReady": "Apple-Modell lädt noch"
        case "osTooOld": "macOS ist zu alt für Apple Intelligence"
        default: "Apple Intelligence nicht verfügbar"
        }
    }

    // MARK: Key and model

    private var keySection: some View {
        Section("Zugang") {
            SettingRow(title: "API-Schlüssel",
                       hint: "Wird im Schlüsselbund gespeichert und nie wieder angezeigt. Ein leeres Feld löscht den Schlüssel.") {
                HStack(spacing: 8) {
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .disabled(onDevice)
                    Button("Speichern") {
                        Task {
                            savingKey = true
                            await ai.saveKey(apiKey)
                            apiKey = ""
                            savingKey = false
                        }
                    }
                    .disabled(savingKey || onDevice)
                    .fixedSize()
                }
            }
            SettingPickerRow(title: "Anbieter",
                             hint: "Der Chat-Anbieter für alle Textfunktionen.",
                             selection: Binding(
                                get: { currentProvider },
                                set: { id in
                                    guard let preset = providers.first(where: { $0.id == id }) else { return }
                                    baseURL = preset.baseURL
                                    s.set("aiBaseUrl", preset.baseURL)
                                    if !preset.model.isEmpty {
                                        modelID = preset.model
                                        s.set("aiModel", preset.model)
                                    }
                                    Task { await ai.refreshStatus(); await ai.refreshModels() }
                                })) {
                ForEach(providers, id: \.id) { provider in
                    Text(provider.label).tag(provider.id)
                }
            }
            if !onDevice {
                SettingRow(title: "Endpunkt", hint: "OpenAI-kompatible Basis-URL.") {
                    TextField("https://…", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        // Committed on submit and when the page goes away, not
                        // per keystroke: one settings write per edit is enough.
                        .onSubmit { commitBaseURL() }
                        .onDisappear { commitBaseURL() }
                }
                SettingRow(title: "Modell", hint: modelHint) {
                    HStack(spacing: 8) {
                        TextField("modell-id", text: $modelID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit { s.set("aiModel", modelID.trimmingCharacters(in: .whitespaces)) }
                        Menu {
                            if ai.models.isEmpty {
                                Text("Noch keine Modellliste geladen")
                            } else {
                                ForEach(ai.models, id: \.self) { id in
                                    Button(id) {
                                        modelID = id
                                        s.set("aiModel", id)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .help("Modelle vom Endpunkt laden")
                        Button("Laden") { Task { await ai.refreshModels() } }
                            .fixedSize()
                    }
                }
            }
            SettingRow(title: "Schnellantworten",
                       hint: "Vorschläge für kurze Antworten im Entwurf.") {
                Toggle("", isOn: Binding(
                    get: { s.aiQuickReplies },
                    set: { s.set("aiQuickReplies", $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var modelHint: String {
        if !ai.models.isEmpty { return "\(ai.models.count) Modelle am Endpunkt." }
        if let error = ai.decisionTestError { return error }
        return "Modellliste laden, um Vorschläge zu bekommen; freie Eingabe bleibt möglich."
    }

    private func commitBaseURL() {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard trimmed != s.aiBaseUrl else { return }
        s.set("aiBaseUrl", trimmed)
        Task { await ai.refreshStatus() }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section("Schreibstil") {
            SettingRow(title: "In meinem Stil schreiben",
                       hint: "Entwürfe folgen dem gelernten Stil, wenn ein Profil vorhanden ist.") {
                Toggle("", isOn: Binding(
                    get: { s.voiceDrafting },
                    set: { s.set("voiceDrafting", $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingRow(title: "Stil lernen",
                       hint: "Liest gesendete Mails und destilliert daraus ein Stilprofil (ein Modellaufruf).") {
                Button(ai.learningVoice ? "Lerne …" : "Jetzt lernen") {
                    Task {
                        if let profile = await ai.learnVoice() {
                            s.set("voiceProfile", profile)
                            s.set("voiceLearnedAt", Int64(Date().timeIntervalSince1970 * 1000))
                        }
                    }
                }
                .disabled(ai.learningVoice)
            }
            let profile = s.voiceProfile
            if profile.isEmpty {
                Text("Noch kein Profil gelernt.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(profile)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Usage

    private var usageSection: some View {
        Section("Nutzung") {
            if let usage = ai.usage {
                SettingRow(title: "Heute", hint: "Token und Anfragen der letzten 30 Tage.") {
                    Text("\(usage.todayTokens) Token · \(usage.totalRequests) Anfragen gesamt")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !usage.days.isEmpty {
                    let peak = max(1, usage.days.map(\.totalTokens).max() ?? 1)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(usage.days.suffix(30)) { day in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.accentColor.opacity(0.15 + 0.75 * Double(day.totalTokens) / Double(peak)))
                                .frame(width: 6, height: 6 + 22 * CGFloat(day.totalTokens) / CGFloat(peak))
                                .help("\(day.date): \(day.totalTokens) Token")
                        }
                    }
                    .frame(height: 30, alignment: .bottom)
                }
            } else {
                Text(ai.loadingUsage ? "Wird geladen …" : "Noch keine Nutzung erfasst.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            SettingRow(title: "Aktualisieren", hint: nil) {
                Button("Aktualisieren") { Task { await ai.refreshUsage() } }
            }
        }
    }

    // MARK: Semantic index

    private var embeddingSection: some View {
        Section("Semantischer Index") {
            if let embedding = ai.embedding {
                SettingRow(title: embedding.enabled ? "Aktiv" : "Aus",
                           hint: "Grundlage für „Fragen an das Postfach“. Lokal gerechnet, ohne Netz.") {
                    Text("\(embedding.embedded)/\(embedding.total) eingebettet"
                         + (embedding.pending > 0 ? " · \(embedding.pending) offen" : ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if embedding.total > 0 {
                    ProgressView(value: Double(embedding.embedded), total: Double(max(1, embedding.total)))
                        .frame(width: 260)
                }
            } else {
                Text(ai.loadingEmbedding ? "Wird geladen …" : "Status nicht verfügbar.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            SettingRow(title: "Neu indizieren",
                       hint: "Stellt das ganze Postfach neu in die Warteschlange. Kann je nach Größe einige Minuten dauern.") {
                Button(ai.reindexing ? "Läuft …" : "Neu indizieren") {
                    Task { await ai.reindex() }
                }
                .disabled(ai.reindexing || ai.embedding?.enabled != true)
            }
        }
    }

    // MARK: Decision provider

    private var decisionSection: some View {
        Section("Entscheidungen") {
            SettingHintRow(title: "Wofür",
                           hint: "Kategorien, Regel-Prüfungen und Split-Bedingungen. Ohne Entscheidungsmodell entscheidet das Chat-Modell.")
            SettingPickerRow(title: "Anbieter", hint: nil, selection: Binding(
                get: { decisionProvider },
                set: {
                    decisionProvider = $0
                    s.set("decisionProvider", $0)
                    Task { await ai.refreshStatus() }
                })) {
                ForEach(decisionProviders, id: \.id) { provider in
                    Text(provider.label).tag(provider.id)
                }
                Text("Aus").tag("off")
            }
            SettingRow(title: "Modell", hint: "Leer lassen für den Standard des Anbieters.") {
                TextField(s.decisionModel, text: Binding(
                    get: { s.decisionModel },
                    set: { s.set("decisionModel", $0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .disabled(s.decisionProvider == "off")
            }
            SettingRow(title: "Schlüssel", hint: "Eigener Schlüssel für den Entscheidungsanbieter (Schlüsselbund).") {
                HStack(spacing: 8) {
                    SecureField("sk-…", text: $decisionKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button("Speichern") {
                        Task {
                            savingDecisionKey = true
                            await ai.saveDecisionKey(provider: decisionProvider, key: decisionKey)
                            decisionKey = ""
                            savingDecisionKey = false
                        }
                    }
                    .disabled(savingDecisionKey || decisionProvider == "off")
                    .fixedSize()
                }
            }
            SettingRow(title: "Test",
                       hint: "Fragt jeden Anbieter der Kette einmal ab (Netz, ein Modellaufruf je Anbieter).") {
                Button(ai.testingDecision ? "Teste …" : "Anbieter testen") {
                    Task { await ai.testDecisionProviders() }
                }
                .disabled(ai.testingDecision || s.decisionProvider == "off")
            }
            if let error = ai.decisionTestError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            ForEach(ai.decisionResults ?? []) { result in
                HStack(spacing: 8) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                    Text("\(result.provider) · \(result.model)")
                    Spacer()
                    Text(result.ok ? "\(result.latencyMs) ms" : result.error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
            }
            SettingRow(title: "Chat-Modell als Rückfall",
                       hint: "Wenn kein Entscheidungsanbieter antwortet, entscheidet das Chat-Modell.") {
                Toggle("", isOn: Binding(
                    get: { s.decisionChatFallback },
                    set: { s.set("decisionChatFallback", $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingRow(title: "Regeln mit KI prüfen",
                       hint: "Erlaubt die KI-Prüfung im Regel-Editor (Bedingung in Worten).") {
                Toggle("", isOn: Binding(
                    get: { s.decisionUseRules },
                    set: { s.set("decisionUseRules", $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}
