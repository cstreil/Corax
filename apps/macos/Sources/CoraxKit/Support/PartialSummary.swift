import Foundation

/// Recovers what is already complete from an unfinished `ai_summarize` stream
/// (M2.4, requirement 4). The host streams the summary as JSON text; the card
/// shows the finished parts — timeline rows, key points, next action — while the
/// rest is still arriving.
///
/// Port of `parsePartialAiSummary` in `src/lib/summaryStream.ts`: an unfinished
/// string or object is held back until its closing token arrives, so the card
/// never flashes broken JSON.
public enum PartialSummary {
    public static func parse(_ raw: String) -> AIThreadSummary? {
        let chars = Array(raw)
        let timeline: [AITimelineEntry] = objectArray(chars, key: "timeline").compactMap { (object: String) -> AITimelineEntry? in
            guard let data = object.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AITimelineEntry.self, from: data)
        }.filter { (entry: AITimelineEntry) in
            !entry.actor.trimmingCharacters(in: .whitespaces).isEmpty || !entry.event.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let keyPoints = stringArray(chars, key: "keyPoints").filter { (point: String) in
            !point.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let nextAction = optionalString(chars, key: "nextAction")
        let proposedReply = optionalString(chars, key: "proposedReply")
        let suggestion = calendarSuggestion(chars)

        let hasContent = !timeline.isEmpty || !keyPoints.isEmpty
            || nextAction.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } == true
            || proposedReply.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } == true
            || suggestion != nil
        guard hasContent else { return nil }

        return AIThreadSummary(timeline: timeline, keyPoints: keyPoints,
                               nextAction: nextAction, proposedReply: proposedReply,
                               calendarSuggestion: suggestion)
    }

    // MARK: Scanning

    /// Index of the first character after `"key":`.
    private static func valueStart(_ chars: [Character], _ key: String) -> Int? {
        let marker = Array("\"\(key)\"")
        guard let keyAt = firstIndex(of: marker, in: chars) else { return nil }
        guard let colon = firstIndex(of: [":"], in: chars, from: keyAt + marker.count) else { return nil }
        var at = colon + 1
        while at < chars.count, chars[at].isWhitespace { at += 1 }
        return at
    }

    private static func firstIndex(of needle: [Character], in chars: [Character], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, chars.count >= needle.count else { return nil }
        for index in start...(chars.count - needle.count) where Array(chars[index..<(index + needle.count)]) == needle {
            return index
        }
        return nil
    }

    /// A complete JSON string starting at `start`, decoded.
    private static func readString(_ chars: [Character], at start: Int) -> (value: String, end: Int)? {
        guard start < chars.count, chars[start] == "\"" else { return nil }
        var escaped = false
        var index = start + 1
        while index < chars.count {
            let ch = chars[index]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                let literal = String(chars[start...index])
                guard let data = literal.data(using: .utf8),
                      let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }
                return (value, index + 1)
            }
            index += 1
        }
        return nil
    }

    /// A balanced `{…}` starting at `start`, as text.
    private static func readObject(_ chars: [Character], at start: Int) -> String? {
        guard start < chars.count, chars[start] == "{" else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < chars.count {
            let ch = chars[index]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(chars[start...index]) }
            }
            index += 1
        }
        return nil
    }

    private static func objectArray(_ chars: [Character], key: String) -> [String] {
        guard let start = valueStart(chars, key), start < chars.count, chars[start] == "[" else { return [] }
        var values: [String] = []
        var inString = false
        var escaped = false
        var depth = 0
        var objectAt = -1
        var index = start + 1
        while index < chars.count {
            let ch = chars[index]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { objectAt = index }
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0, objectAt >= 0 {
                    if let object = readObject(chars, at: objectAt) { values.append(object) }
                    objectAt = -1
                }
            } else if ch == "]", depth == 0 {
                break
            }
            index += 1
        }
        return values
    }

    private static func stringArray(_ chars: [Character], key: String) -> [String] {
        guard let start = valueStart(chars, key), start < chars.count, chars[start] == "[" else { return [] }
        var values: [String] = []
        var at = start + 1
        while at < chars.count {
            while at < chars.count, chars[at].isWhitespace || chars[at] == "," { at += 1 }
            guard at < chars.count, chars[at] != "]" else { break }
            guard let item = readString(chars, at: at) else { break }
            values.append(item.value)
            at = item.end
        }
        return values
    }

    private static func optionalString(_ chars: [Character], key: String) -> String? {
        guard let start = valueStart(chars, key) else { return nil }
        if String(chars[start...]).hasPrefix("null") { return nil }
        return readString(chars, at: start)?.value
    }

    private static func calendarSuggestion(_ chars: [Character]) -> AICalendarSuggestion? {
        guard let start = valueStart(chars, "calendarSuggestion") else { return nil }
        if String(chars[start...]).hasPrefix("null") { return nil }
        guard let object = readObject(chars, at: start), let data = object.data(using: .utf8),
              let suggestion = try? JSONDecoder().decode(AICalendarSuggestion.self, from: data),
              !suggestion.title.trimmingCharacters(in: .whitespaces).isEmpty,
              !suggestion.start.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return suggestion
    }
}
