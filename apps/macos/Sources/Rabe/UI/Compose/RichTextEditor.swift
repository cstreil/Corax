import AppKit
import Observation
import RabeKit
import SwiftUI

/// The rich body editor (M2.6): an `NSTextView` with native spell checking,
/// writing tools, undo and accessibility. No web view.
///
/// The text storage is the truth while typing; after every change the storage
/// is serialised into the HTML subset (`RichHTML`) and handed to the draft.
/// Changes that come from outside (AI text, snippet, quote, signature) bump
/// `revision`, and the editor reloads from HTML.
@Observable
@MainActor
final class RichEditorController {
    weak var textView: RichTextEditorView?
    /// Always called with the serialised body (may be empty).
    var onChange: ((String) -> Void)?
    /// Keys typed after an `@` (`nil` closes the suggestion list).
    var onMentionQuery: ((String?) -> Void)?
    /// The picked `@`-mention; the composer adds the recipient to "An".
    var onMentionPick: ((ContactSuggestion) -> Void)?
    /// Esc with no popup open (the composer discards the draft).
    var onEscape: (() -> Void)?
    /// Suggestions for the open `@query`, in list order.
    var mentionSuggestions: [ContactSuggestion] = [] {
        didSet { if mentionSuggestions != oldValue { mentionIndex = 0 } }
    }
    private(set) var mentionIndex = 0
    /// `⌘K`: the composer shows its link field.
    var onLinkRequest: (() -> Void)?
    /// The formatting at the caret, for the format bar.
    private(set) var state = RichFormatState()
    /// The revision the storage currently shows.
    private(set) var loadedRevision = -1
    /// Space before the caret holds an unresolved `@query`.
    private(set) var mentionStart: Int?

    var hasFocus: Bool { textView?.window?.firstResponder === textView }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Laden und Veröffentlichen

    /// Puts `html` into the editor. Selection goes to the start, as a reloaded
    /// draft starts at its first line.
    func load(html: String, revision: Int, theme: Theme) {
        guard let textView, revision != loadedRevision else { return }
        loadedRevision = revision
        let document = RichHTML.parse(html)
        let attributed = RichTextBridge.attributedString(from: document, theme: theme)
        textView.applyBaseAttributes(theme: theme)
        if let storage = textView.textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.replaceCharacters(in: full, with: attributed)
            storage.endEditing()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.typingAttributes = textView.baseAttributes()
        }
        textView.undoManager?.removeAllActions()
        refreshState()
    }

    /// Serialises the storage and reports it. Called after every edit.
    func publish() {
        guard let textView, let storage = textView.textStorage else { return }
        let html = RichHTML.html(from: RichTextBridge.document(from: storage))
        onChange?(html)
        refreshState()
        detectMention()
    }

    var html: String {
        guard let storage = textView?.textStorage else { return "" }
        return RichHTML.html(from: RichTextBridge.document(from: storage))
    }

    /// `true` when the body has neither text nor a picture (signature aside).
    var isEmpty: Bool {
        guard let storage = textView?.textStorage else { return true }
        return RichHTML.parse(html).withoutSignature.isEmpty
    }

    /// Reads one attribute at `location`, clamped into the storage. A caret at
    /// the very end of the text is a legal position but not a legal index —
    /// `attributesAtIndex:` raises `NSRangeException` there (found in the M2.6
    /// walkthrough: ⌘⇧X at the end of the body killed the app).
    private func attribute(_ key: NSAttributedString.Key, at location: Int) -> Any? {
        guard let storage = textView?.textStorage, storage.length > 0 else { return nil }
        return storage.attribute(key, at: min(max(0, location), storage.length - 1), effectiveRange: nil)
    }

    // MARK: Auswahl und Zustand

    func refreshState() {
        guard let textView else { return }
        var next = RichFormatState()
        let range = textView.selectedRange()
        let attributes = textView.effectiveAttributes(at: range.location, selection: range)
        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            next.bold = traits.contains(.bold)
            next.italic = traits.contains(.italic)
        }
        next.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        next.strike = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        if let raw = attributes[RichTextBridge.Key.list] as? String { next.listKind = RichListKind(rawValue: raw) }
        next.quote = (attributes[RichTextBridge.Key.quote] as? Int ?? 0) > 0
        if let url = attributes[.link] as? URL { next.link = url.absoluteString }
        if next != state { state = next }
    }

    // MARK: Formatieren

    func toggleBold() { toggleFontTrait(.boldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask) }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            var attributes = textView.typingAttributes
            let font = attributes[.font] as? NSFont ?? RichTextBridge.bodyFont()
            attributes[.font] = toggled(font, trait)
            textView.typingAttributes = attributes
            refreshState()
            return
        }
        mutateText(range) { storage in
            storage.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
                let font = value as? NSFont ?? RichTextBridge.bodyFont()
                storage.addAttribute(.font, value: toggled(font, trait), range: runRange)
            }
        }
    }

    /// The trait flips with the first character of the selection, so a mixed
    /// selection becomes wholly bold or wholly plain.
    private func toggled(_ font: NSFont, _ trait: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        return manager.traits(of: font).contains(trait)
            ? manager.convert(font, toNotHaveTrait: trait)
            : manager.convert(font, toHaveTrait: trait)
    }

    func toggleUnderline() { toggleDecoration(.underlineStyle) }
    func toggleStrike() { toggleDecoration(.strikethroughStyle) }

    private func toggleDecoration(_ key: NSAttributedString.Key) {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            var attributes = textView.typingAttributes
            let value = attributes[key] as? Int ?? 0
            if value == 0 { attributes[key] = NSUnderlineStyle.single.rawValue } else { attributes[key] = nil }
            textView.typingAttributes = attributes
            refreshState()
            return
        }
        let current = attribute(key, at: range.location) as? Int ?? 0
        mutateText(range) { storage in
            if current == 0 {
                storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                storage.removeAttribute(key, range: range)
            }
        }
    }

    func toggleList(_ kind: RichListKind) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let paragraphs = Self.paragraphs(in: range, of: storage.string)
        // An empty last line has no characters to style: the state to toggle
        // lives in the typing attributes.
        let existing = paragraphs.first
            .map { storage.attributes(at: $0.location, effectiveRange: nil)[RichTextBridge.Key.list] as? String } ?? nil
        let current = existing ?? (textView.typingAttributes[RichTextBridge.Key.list] as? String)
        let makeList = current != kind.rawValue
        if paragraphs.isEmpty {
            applyTypingParagraph(list: makeList ? kind : nil)
            refreshState()
            publish()
            return
        }
        mutateText(range) { storage in
            for paragraph in paragraphs {
                var attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
                if makeList {
                    attributes[RichTextBridge.Key.list] = kind.rawValue
                    attributes[RichTextBridge.Key.listDepth] = 1
                } else {
                    attributes[RichTextBridge.Key.list] = nil
                    attributes[RichTextBridge.Key.listDepth] = nil
                }
                Self.applyParagraph(attributes, to: paragraph, storage: storage)
            }
        }
        if range.length == 0 { syncTypingParagraph(list: makeList ? kind : nil) }
    }

    func toggleQuote() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let paragraphs = Self.paragraphs(in: range, of: storage.string)
        let existing = paragraphs.first
            .map { storage.attributes(at: $0.location, effectiveRange: nil)[RichTextBridge.Key.quote] as? Int ?? 0 } ?? nil
        let quoted = (existing ?? (textView.typingAttributes[RichTextBridge.Key.quote] as? Int ?? 0)) > 0
        if paragraphs.isEmpty {
            applyTypingParagraph(quote: quoted ? 0 : 1)
            refreshState()
            publish()
            return
        }
        mutateText(range) { storage in
            for paragraph in paragraphs {
                var attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
                attributes[RichTextBridge.Key.quote] = quoted ? nil : 1
                Self.applyParagraph(attributes, to: paragraph, storage: storage)
            }
        }
        if range.length == 0 { syncTypingParagraph(quote: quoted ? 0 : 1) }
    }

    /// Sets the paragraph style of the *next* line (an empty last line has no
    /// characters, so this is where a list or a quote actually starts).
    private func applyTypingParagraph(list: RichListKind? = nil, quote: Int? = nil) {
        guard let textView else { return }
        var attributes = textView.typingAttributes
        let quoteDepth = quote ?? (attributes[RichTextBridge.Key.quote] as? Int ?? 0)
        let listKind = list ?? (attributes[RichTextBridge.Key.list] as? String).flatMap(RichListKind.init(rawValue:))
        if let list { attributes[RichTextBridge.Key.list] = list.rawValue } else { attributes[RichTextBridge.Key.list] = nil }
        attributes[RichTextBridge.Key.listDepth] = listKind != nil ? 1 : nil
        if quoteDepth > 0 { attributes[RichTextBridge.Key.quote] = quoteDepth } else { attributes[RichTextBridge.Key.quote] = nil }
        attributes[.paragraphStyle] = RichTextBridge.paragraphStyle(quote: quoteDepth, list: listKind,
                                                                   depth: 1)
        textView.typingAttributes = attributes
    }

    /// After styling a paragraph, its style must carry over to what is typed
    /// next (and to the line a Return adds).
    private func syncTypingParagraph(list: RichListKind? = nil, quote: Int? = nil) {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
        var attributes = textView.typingAttributes
        var listKind = list
        var quoteDepth = quote ?? 0
        if list == nil, quote == nil {
            let caret = min(textView.selectedRange().location, storage.length - 1)
            let source = storage.attributes(at: caret, effectiveRange: nil)
            listKind = (source[RichTextBridge.Key.list] as? String).flatMap(RichListKind.init(rawValue:))
            quoteDepth = source[RichTextBridge.Key.quote] as? Int ?? 0
        }
        if let listKind, let raw = listKind.rawValue as String? { attributes[RichTextBridge.Key.list] = raw }
        else if listKind == nil { attributes[RichTextBridge.Key.list] = nil }
        attributes[RichTextBridge.Key.listDepth] = listKind != nil ? 1 : nil
        attributes[RichTextBridge.Key.quote] = quoteDepth > 0 ? quoteDepth : nil
        attributes[.paragraphStyle] = RichTextBridge.paragraphStyle(quote: quoteDepth, list: listKind, depth: 1)
        textView.typingAttributes = attributes
    }

    /// `⌘\`: drops inline and block formatting, keeps links, pictures and
    /// mention chips — they are content, as in Tauri.
    func clearFormatting() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let full = range.length > 0 ? range : NSRange(location: 0, length: storage.length)
        mutateText(full) { storage in
            storage.addAttribute(.font, value: RichTextBridge.bodyFont(), range: full)
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.strikethroughStyle, range: full)
            for paragraph in Self.paragraphs(in: full, of: storage.string) {
                var attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
                attributes[RichTextBridge.Key.list] = nil
                attributes[RichTextBridge.Key.listDepth] = nil
                attributes[RichTextBridge.Key.quote] = nil
                Self.applyParagraph(attributes, to: paragraph, storage: storage)
            }
        }
        // …and the next characters typed must not inherit the old formatting.
        textView.typingAttributes = textView.baseAttributes()
    }

    /// The first `@` suggestion (hook build: the walkthrough cannot click).
    /// Returns the address it took, nil when the list was empty.
    @discardableResult
    func pickFirstMention() -> String? {
        guard !mentionSuggestions.isEmpty else { return nil }
        let address = mentionSuggestions[0].email
        pickMention(mentionSuggestions[0])
        return address
    }

    /// The link field's result: `nil` removes the link.
    func applyLink(_ target: String?) {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard let target, let safe = RichHTML.linkTarget(fromInput: target), let url = URL(string: safe) else {
            if range.length > 0 {
                mutateText(range) { storage in storage.removeAttribute(.link, range: range) }
            }
            return
        }
        mutateText(range) { storage in
            if range.length > 0 {
                storage.addAttribute(.link, value: url, range: range)
            } else {
                var attributes = textView.typingAttributes
                attributes[.link] = url
                textView.typingAttributes = attributes
            }
        }
    }

    // MARK: Einfügen

    /// Inserts parsed HTML (snippet, quote) at the caret, as blocks of its own:
    /// a break before and after keeps the inserted text from running into the
    /// user's line.
    func insertHTML(_ html: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let document = RichHTML.parse(html)
        guard !document.blocks.isEmpty else { return }
        let theme = textView.theme
        let range = textView.selectedRange()
        let prefix = needsLeadingBreak(storage: storage, at: range.location) ? "\n" : ""
        var content = RichTextBridge.attributedString(from: document, theme: theme)
        if content.length > 0, (content.string as NSString).hasSuffix("\n") {
            content = content.attributedSubstring(from: NSRange(location: 0, length: content.length - 1))
        }
        let suffix = needsTrailingBreak(storage: storage, at: NSMaxRange(range)) ? "\n" : ""
        let insertion = NSMutableAttributedString()
        if !prefix.isEmpty {
            insertion.append(NSAttributedString(string: prefix, attributes: textView.baseAttributes()))
        }
        insertion.append(content)
        if !suffix.isEmpty {
            insertion.append(NSAttributedString(string: suffix, attributes: textView.baseAttributes()))
        }
        replace(range, with: insertion)
        textView.setSelectedRange(NSRange(location: range.location + prefix.count + content.length,
                                          length: 0))
        publish()
    }

    /// The `@Name` chip plus a space, replacing the typed `@query`.
    /// Takes the highlighted (or the given) suggestion.
    func pickMention(_ suggestion: ContactSuggestion? = nil) {
        let chosen = suggestion ?? (mentionSuggestions.indices.contains(mentionIndex)
                                    ? mentionSuggestions[mentionIndex] : nil)
        guard let chosen else { return }
        insertMention(text: chosen.name ?? chosen.email, email: chosen.email)
        mentionSuggestions = []
        mentionIndex = 0
        onMentionPick?(chosen)
    }

    func insertMention(text: String, email: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let caret = textView.selectedRange()
        let start = mentionStart ?? caret.location
        let range = NSRange(location: min(start, caret.location), length: max(0, caret.location - start))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textView.typingAttributes[.font] as? NSFont ?? RichTextBridge.bodyFont(),
            RichTextBridge.Key.mention: email,
            .backgroundColor: textView.theme.accent.ns.withAlphaComponent(0.13),
        ]
        // The chip is the name; the space after it is ordinary text, so the
        // HTML round trip does not move a space in or out of the span.
        let insertion = NSMutableAttributedString(string: "@" + text, attributes: attributes)
        insertion.append(NSAttributedString(string: " ", attributes: textView.baseAttributes()))
        _ = storage
        replace(range, with: insertion)
        textView.setSelectedRange(NSRange(location: range.location + insertion.length, length: 0))
        mentionStart = nil
        onMentionQuery?(nil)
        publish()
    }

    func insertImage(_ image: RichImage) {
        guard let textView, let storage = textView.textStorage else { return }
        let document = RichDocument(blocks: [RichBlock(runs: [.image(image)])])
        let content = RichTextBridge.attributedString(from: document, theme: textView.theme)
        let trimmed = content.length > 0
            ? content.attributedSubstring(from: NSRange(location: 0, length: content.length - 1))
            : content
        let range = textView.selectedRange()
        replace(range, with: trimmed)
        textView.setSelectedRange(NSRange(location: range.location + trimmed.length, length: 0))
        textView.typingAttributes = textView.baseAttributes()
        publish()
        _ = storage
    }

    // MARK: Kürzel, die der Editor selbst kennt

    /// Handles the formatting shortcuts. Returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        // The `@` list grabs the navigation keys first (as Tauri's editor does).
        if mentionStart != nil, !mentionSuggestions.isEmpty {
            switch event.keyCode {
            case 125: mentionIndex = min(mentionIndex + 1, mentionSuggestions.count - 1); return true
            case 126: mentionIndex = max(mentionIndex - 1, 0); return true
            case 36, 48: pickMention(); return true
            case 53: closeMention(); return true
            default: break
            }
        }
        if event.keyCode == 53, !event.modifierFlags.contains(.command) {
            closeMention()
            onEscape?()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = flags.contains(.shift)
        // ⇧⌘7/8/9 are layout dependent (`code`), so the physical key decides.
        let code = event.keyCode
        guard flags.contains(.command) else {
            // Tab nests a list item, ⇧Tab lifts it out again.
            if code == 48, let textView, textView.listDepth(atCaret: textView.selectedRange().location) > 0 {
                if shift { liftListItem() } else { nestListItem() }
                return true
            }
            return false
        }
        if !shift {
            switch key {
            case "b": logFormat("key", "bold"); toggleBold(); return true
            case "i": logFormat("key", "italic"); toggleItalic(); return true
            case "u": logFormat("key", "underline"); toggleUnderline(); return true
            case "k": onLinkRequest?(); return true
            case "\\": logFormat("key", "clear"); clearFormatting(); return true
            default: break
            }
            if code == 42 { clearFormatting(); return true }   // ⌘\ on the physical key
            return false
        }
        switch key {
        case "x": logFormat("key", "strike"); toggleStrike(); return true
        default: break
        }
        switch code {
        case 26: logFormat("key", "ordered"); toggleList(.ordered); return true    // ⇧⌘7
        case 28: logFormat("key", "bullet"); toggleList(.bullet); return true      // ⇧⌘8
        case 25: logFormat("key", "quote"); toggleQuote(); return true             // ⇧⌘9
        default: return false
        }
    }

    private func logFormat(_ source: String, _ kind: String) {
        PerfLog.shared.write("fmt \(source) kind=\(kind) active=\(state)")
    }

    private func nestListItem() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        mutateText(range) { storage in
            for paragraph in Self.paragraphs(in: range, of: storage.string) {
                var attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
                let depth = attributes[RichTextBridge.Key.listDepth] as? Int ?? 1
                guard depth < RichLimits.maxListDepth else { continue }
                attributes[RichTextBridge.Key.listDepth] = depth + 1
                Self.applyParagraph(attributes, to: paragraph, storage: storage)
            }
        }
    }

    private func liftListItem() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        mutateText(range) { storage in
            for paragraph in Self.paragraphs(in: range, of: storage.string) {
                var attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
                let depth = attributes[RichTextBridge.Key.listDepth] as? Int ?? 1
                if depth <= 1 {
                    attributes[RichTextBridge.Key.list] = nil
                    attributes[RichTextBridge.Key.listDepth] = nil
                } else {
                    attributes[RichTextBridge.Key.listDepth] = depth - 1
                }
                Self.applyParagraph(attributes, to: paragraph, storage: storage)
            }
        }
    }

    // MARK: Zusammenarbeit mit dem Text

    private func replace(_ range: NSRange, with insertion: NSAttributedString) {
        guard let textView, let storage = textView.textStorage else { return }
        guard textView.shouldChangeText(in: range, replacementString: insertion.string) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: insertion)
        storage.endEditing()
        textView.didChangeText()
    }

    /// Runs an attribute-only change with undo support.
    private func mutateText(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        let safe = NSRange(location: min(range.location, storage.length),
                           length: min(range.length, max(0, storage.length - min(range.location, storage.length))))
        if safe.length > 0 {
            guard textView.shouldChangeText(in: safe, replacementString: nil) else { return }
        }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        textView.didChangeText()
        refreshState()
        publish()
    }

    /// The paragraphs a range touches. A caret at the very end of the text is
    /// legal but has no paragraph of its own: `paragraphRange(for:)` answers
    /// `{length, 0}` there, and `attributes(at: length)` raises
    /// `NSRangeException` (found in the M2.6 walkthrough: ⌘⇧8 at the end of the
    /// body killed the app).
    private static func paragraphs(in range: NSRange, of string: String) -> [NSRange] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }
        if range.length == 0 {
            // A caret after the final newline is the empty last line: it has no
            // characters, so its style lives in the typing attributes.
            if range.location >= ns.length, ns.character(at: ns.length - 1) == 0x0A { return [] }
            let start = min(max(0, range.location), ns.length - 1)
            let paragraph = ns.paragraphRange(for: NSRange(location: start, length: 0))
            return paragraph.length > 0 ? [paragraph] : []
        }
        var result: [NSRange] = []
        var location = min(max(0, range.location), ns.length - 1)
        let end = min(NSMaxRange(range), ns.length)
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if paragraph.length > 0, paragraph.location < ns.length { result.append(paragraph) }
            let next = NSMaxRange(paragraph)
            if next <= location { break }
            location = next
            if location > end { break }
        }
        return result
    }

    /// Keeps the paragraph's block attributes and rebuilds the style from them.
    private static func applyParagraph(_ attributes: [NSAttributedString.Key: Any], to range: NSRange,
                                       storage: NSTextStorage) {
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard safe.length > 0 else { return }
        var attributes = attributes
        attributes[.paragraphStyle] = RichTextBridge.paragraphStyle(
            quote: attributes[RichTextBridge.Key.quote] as? Int ?? 0,
            list: (attributes[RichTextBridge.Key.list] as? String).flatMap(RichListKind.init(rawValue:)),
            depth: attributes[RichTextBridge.Key.listDepth] as? Int ?? 1)
        storage.setAttributes(attributes, range: safe)
    }

    // MARK: Prüf-Haken (Hook-Build)

    /// Types text the way the keyboard does (`insertText` → delegate → HTML).
    func typeForHook(_ text: String) {
        guard let textView else { return }
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func selectAllForHook() {
        textView?.selectAll(nil)
        refreshState()
    }

    /// The editor's HTML through the whole bridge again: what a saved draft
    /// looks like when it is reopened. Returns "ok" plus the byte counts.
    func roundTripReport() -> String {
        guard let storage = textView?.textStorage else { return "no_editor" }
        let first = RichHTML.html(from: RichTextBridge.document(from: storage))
        let reparsed = RichTextBridge.attributedString(from: RichHTML.parse(first), theme: textView?.theme ?? .graphite)
        let second = RichHTML.html(from: RichTextBridge.document(from: reparsed))
        var report = "equal=\(first == second ? 1 : 0) bytes=\(first.count)/\(second.count) "
            + "blocks=\(RichHTML.parse(first).blocks.count)"
        if first != second { report += " " + Self.diff(first, second) }
        return report
    }

    /// Where two HTML strings first differ, with a little context — enough to
    /// find a round-trip bug in the log of a walkthrough run.
    private static func diff(_ a: String, _ b: String) -> String {
        let left = Array(a), right = Array(b)
        var index = 0
        while index < min(left.count, right.count), left[index] == right[index] { index += 1 }
        let from = max(0, index - 30)
        let l = String(left[from..<min(left.count, index + 30)])
        let r = String(right[from..<min(right.count, index + 30)])
        return "at=\(index) a=\(l.debugDescription) b=\(r.debugDescription)"
    }

    // MARK: Erwähnungen

    /// Looks for an unresolved `@query` right before the caret and reports it.
    func detectMention() {
        guard let textView, let storage = textView.textStorage else { return }
        let caret = textView.selectedRange()
        guard caret.length == 0, let start = Self.mentionRange(in: storage.string, caret: caret.location) else {
            if mentionStart != nil { mentionStart = nil; onMentionQuery?(nil) }
            return
        }
        mentionStart = start
        let text = (storage.string as NSString).substring(with: NSRange(location: start,
                                                                        length: caret.location - start))
        onMentionQuery?(String(text.dropFirst()))
    }

    /// Start of an `@word` immediately before the caret, or nil.
    static func mentionRange(in string: String, caret: Int) -> Int? {
        guard caret > 0, caret <= string.count else { return nil }
        let prefix = String(string.prefix(caret))
        guard let at = prefix.lastIndex(of: "@") else { return nil }
        let query = prefix[prefix.index(after: at)...]
        guard query.count <= 30, !query.contains(where: { $0.isWhitespace }) else { return nil }
        let before = prefix[..<at].last
        guard before == nil || before?.isWhitespace == true || before == "\n" || before == "\u{2028}"
                || before == "(" || before == ">" else { return nil }
        return prefix.distance(from: prefix.startIndex, to: at)
    }

    private func closeMention() {
        mentionSuggestions = []
        guard mentionStart != nil else { return }
        mentionStart = nil
        onMentionQuery?(nil)
    }

    private func needsLeadingBreak(storage: NSTextStorage, at location: Int) -> Bool {
        guard location > 0, location <= storage.length else { return false }
        let string = storage.string as NSString
        let start = string.paragraphRange(for: NSRange(location: location, length: 0)).location
        return location > start
    }

    private func needsTrailingBreak(storage: NSTextStorage, at location: Int) -> Bool {
        guard location < storage.length else { return false }
        let string = storage.string as NSString
        return string.character(at: location) != 0x0A
    }
}

extension RichEditorController: ComposeEditorHost {
    func focusEditor() { focus() }
    var isEditorFocused: Bool { hasFocus }
}

// MARK: - NSTextView

final class RichTextEditorView: NSTextView {
    weak var controller: RichEditorController?
    var theme: Theme = .graphite
    /// Set by `paste` so ⌘⇧V inserts plain text.
    private var pastePlain = false

    /// TextKit 2 is what the briefing asks for; `false` falls back to TextKit 1
    /// (the list markers are the part to watch, see BERICHT-M2.6).
    static let usesTextKit2 = true

    static func make(theme: Theme) -> RichTextEditorView {
        let view: RichTextEditorView
        if usesTextKit2 {
            view = RichTextEditorView(usingTextLayoutManager: true)
        } else {
            view = RichTextEditorView(frame: .zero)
        }
        view.theme = theme
        view.setup()
        return view
    }

    private func setup() {
        isRichText = true
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        usesFindPanel = true
        isIncrementalSearchingEnabled = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = NSSize(width: 0, height: 4)
        textContainer?.lineFragmentPadding = 0
        font = RichTextBridge.bodyFont()
        textColor = theme.ink.ns
        insertionPointColor = theme.accent.ns
        applyBaseAttributes(theme: theme)
        typingAttributes = baseAttributes()
        linkTextAttributes = [
            .foregroundColor: theme.accent.ns,
            .underlineStyle: 0,
        ]
        autoresizingMask = [.width]
        registerForDraggedTypes([.fileURL, .tiff, NSPasteboard.PasteboardType("public.png")])
    }

    func applyBaseAttributes(theme: Theme) {
        self.theme = theme
        font = RichTextBridge.bodyFont()
        textColor = theme.ink.ns
        insertionPointColor = theme.accent.ns
        backgroundColor = .clear
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: RichTextBridge.bodyFont(),
            .foregroundColor: theme.ink.ns,
            .paragraphStyle: RichTextBridge.paragraphStyle(quote: 0, list: nil, depth: 1),
        ]
    }

    /// The attributes the bar should show: the first character of the
    /// selection, or the typing attributes at a collapsed caret.
    func effectiveAttributes(at location: Int, selection: NSRange) -> [NSAttributedString.Key: Any] {
        guard let storage = textStorage else { return typingAttributes }
        if selection.length == 0 {
            var attributes = typingAttributes
            if location > 0, location <= storage.length {
                let previous = storage.attributes(at: location - 1, effectiveRange: nil)
                // A caret right after a formatted word shows that formatting.
                if attributes[.font] == nil { attributes = previous }
                if let font = attributes[.font] as? NSFont, font.pointSize == 0 { attributes = previous }
                for key in [RichTextBridge.Key.list, RichTextBridge.Key.listDepth, RichTextBridge.Key.quote] {
                    if attributes[key] == nil, previous[key] != nil { attributes[key] = previous[key] }
                }
            }
            return attributes
        }
        guard storage.length > 0 else { return typingAttributes }
        return storage.attributes(at: min(location, storage.length - 1), effectiveRange: nil)
    }

    func listDepth(atCaret location: Int) -> Int {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        return storage.attribute(RichTextBridge.Key.listDepth, at: min(location, storage.length - 1),
                                 effectiveRange: nil) as? Int ?? 0
    }

    // MARK: Tastatur

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘K must win over the menu bar (which opens the command palette), so
        // it is taken here before the window looks at its menu items.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
            controller?.onLinkRequest?()
            return true
        }
        if controller?.handleKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Einfügen und Ziehen

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let image = RichTextBridge.image(from: pasteboard), !pasteboardHasText(pasteboard) {
            if let encoded = RichTextBridge.encode(image) {
                controller?.insertImage(encoded)
            } else {
                NSSound.beep()
            }
            return
        }
        if pastePlain {
            pastePlain = false
            if let text = pasteboard.string(forType: .string) {
                insertText(text, replacementRange: selectedRange())
                return
            }
        }
        super.paste(sender)
    }

    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        // ⌘⇧V: the keystroke sets the flag, the paste call reads it.
        if NSEvent.modifierFlags.contains([.command, .shift]),
           let text = pasteboard.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pasteboard)
    }

    private func pasteboardHasText(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.string(forType: .string)?.isEmpty == false)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let image = RichTextBridge.image(from: sender.draggingPasteboard), let encoded = RichTextBridge.encode(image) {
            controller?.insertImage(encoded)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func insertNewline(_ sender: Any?) {
        // An empty list item ends the list (Word/Gmail behaviour): the marker
        // must not be continued forever.
        if let storage = textStorage, storage.length > 0 {
            let paragraph = (storage.string as NSString).paragraphRange(for: selectedRange())
            let text = (storage.string as NSString).substring(with: paragraph)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, listDepth(atCaret: selectedRange().location) > 0 {
                controller?.toggleList(.bullet)
                super.insertNewline(sender)
                return
            }
        }
        super.insertNewline(sender)
    }
}

// MARK: - SwiftUI

/// `NSTextView` in SwiftUI: one view, no web content.
struct RichTextEditor: NSViewRepresentable {
    let html: String
    let revision: Int
    let theme: Theme
    let controller: RichEditorController
    var minHeight: CGFloat = 120
    var onChange: (String) -> Void
    var onMention: (String?) -> Void
    var onLink: () -> Void
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        let textView = RichTextEditorView.make(theme: theme)
        textView.controller = controller
        textView.delegate = context.coordinator
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        controller.textView = textView
        controller.onChange = onChange
        controller.onMentionQuery = onMention
        controller.onLinkRequest = onLink
        controller.load(html: html, revision: revision, theme: theme)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? RichTextEditorView else { return }
        controller.onChange = onChange
        controller.onMentionQuery = onMention
        controller.onLinkRequest = onLink
        if textView.theme != theme {
            textView.applyBaseAttributes(theme: theme)
            controller.load(html: html, revision: -2, theme: theme)
        }
        textView.minSize = NSSize(width: 0, height: minHeight)
        if revision != controller.loadedRevision {
            controller.load(html: html, revision: revision, theme: theme)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            parent.controller.publish()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard notification.object as? RichTextEditorView === parent.controller.textView else { return }
            parent.controller.refreshState()
            parent.controller.detectMention()
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }

        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool { false }
    }
}
