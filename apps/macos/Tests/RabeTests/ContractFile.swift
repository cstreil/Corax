import Foundation

/// Reads the IPC contract (`src/ipc/types.ts`) at test time (R-W4).
///
/// The test used to compare against hand-copied key lists; a change in the
/// contract could not turn it red. This parser pulls the `Commands` interface
/// and every `export interface` out of the real file, so the Swift wrappers are
/// checked against what the frontend and the Rust dispatcher agree on.
///
/// A nullable type (`number | null`, `string | null`) counts as omittable, not
/// as required: the Rust DTOs declare those fields `Option<T>`, and serde
/// deserializes a missing `Option` as `None` — which is exactly what Swift's
/// `JSONEncoder` does with a `nil` optional.
enum ContractFile {
    struct TypeShape {
        var required: Set<String> = []
        var optional: Set<String> = []
        /// Property name → declared type text (for inline object lookups).
        var types: [String: String] = [:]

        var all: Set<String> { required.union(optional) }
    }

    struct Contract {
        let commands: [String: TypeShape]
        let interfaces: [String: TypeShape]

        /// `"save_draft"` (a command), `"SaveDraftArgs"` (an interface) or
        /// `"PerformActionArgs.params"` (an inline object of a property).
        func shape(_ key: String) throws -> TypeShape {
            if let dot = key.firstIndex(of: ".") {
                let parent = String(key[..<dot])
                let property = String(key[key.index(after: dot)...])
                guard let shape = commands[parent] ?? interfaces[parent], let type = shape.types[property] else {
                    throw ParseError.missing("\(parent).\(property)")
                }
                return ContractFile.shape(ofType: type, interfaces: interfaces)
            }
            if let command = commands[key] { return command }
            if let interface = interfaces[key] { return interface }
            throw ParseError.missing(key)
        }
    }

    enum ParseError: LocalizedError, CustomStringConvertible {
        case fileMissing(String)
        case missing(String)
        case malformed(String)

        var description: String {
            switch self {
            case .fileMissing(let path): "Datei fehlt: \(path)"
            case .missing(let key): "Nicht im Vertrag: \(key)"
            case .malformed(let detail): "Vertrag unlesbar: \(detail)"
            }
        }
    }

    // MARK: Entry points

    static func load() throws -> Contract {
        let url = try repositoryFile("src/ipc/types.ts")
        let text = try String(contentsOf: url, encoding: .utf8)
        let stripped = stripComments(text)
        let bodies = interfaceBodies(stripped)
        guard let commandBody = bodies["Commands"] else { throw ParseError.malformed("interface Commands fehlt") }

        var interfaces: [String: TypeShape] = [:]
        for (name, body) in bodies where name != "Commands" {
            interfaces[name] = shape(ofBody: body)
        }
        var commands: [String: TypeShape] = [:]
        for segment in memberSegments(commandBody) {
            guard let (name, annotation) = commandSegment(segment) else { continue }
            commands[name] = shape(ofType: annotation, interfaces: interfaces)
        }
        guard !commands.isEmpty else { throw ParseError.malformed("keine Befehle gefunden") }
        return Contract(commands: commands, interfaces: interfaces)
    }

    /// Walks up from this file until `relative` exists (works for any checkout).
    static func repositoryFile(_ relative: String) throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            url.deleteLastPathComponent()
        }
        throw ParseError.fileMissing(relative)
    }

    /// Names of the `COMMANDS` array in `rabe-host/src/dispatch.rs`.
    static func commandNames(inRustDispatch text: String) -> Set<String> {
        guard let start = text.range(of: "pub const COMMANDS"),
              let open = text[start.upperBound...].firstIndex(of: "["),
              let close = text.range(of: "\n];", range: open..<text.endIndex) else { return [] }
        var names: Set<String> = []
        var index = open
        while let first = text[index..<close.lowerBound].firstIndex(of: "\""),
              let second = text[text.index(after: first)..<close.lowerBound].firstIndex(of: "\"") {
            names.insert(String(text[text.index(after: first)..<second]))
            index = text.index(after: second)
        }
        return names
    }

    // MARK: Types

    private static func shape(ofType text: String, interfaces: [String: TypeShape]) -> TypeShape {
        let type = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if type.hasPrefix("{") {
            let chars = Array(type)
            guard let close = matchingBrace(chars, open: 0) else { return TypeShape() }
            return shape(ofBody: String(chars[1..<close]))
        }
        if type.hasPrefix("Record<") { return TypeShape() }
        if let merged = shapeOfOmitIntersection(type, interfaces: interfaces) { return merged }
        return interfaces[type] ?? TypeShape()
    }

    /// `Omit<Name, "a" | "b"> & { ... }` — the shape of `Name` without the
    /// omitted keys, merged with the inline object. The `save_*` commands use
    /// it because their payload is the row minus server-side fields.
    private static func shapeOfOmitIntersection(_ text: String, interfaces: [String: TypeShape]) -> TypeShape? {
        let type = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard type.hasPrefix("Omit<") else { return nil }
        let chars = Array(type)
        guard let open = chars.firstIndex(of: "<"), let close = matchingAngle(chars, open: open) else { return nil }
        let inner = String(chars[(open + 1)..<close])
        guard let comma = inner.firstIndex(of: ",") else { return nil }
        let baseName = String(inner[..<comma]).trimmingCharacters(in: .whitespaces)
        let omitted = Set(String(inner[inner.index(after: comma)...])
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\t")) })
        var merged = interfaces[baseName] ?? TypeShape()
        merged.required.subtract(omitted)
        merged.optional.subtract(omitted)
        for key in omitted { merged.types[key] = nil }

        let rest = Array(chars[(close + 1)...])
        if let brace = rest.firstIndex(of: "{"), let end = matchingBrace(rest, open: brace) {
            let inline = shape(ofBody: String(rest[(brace + 1)..<end]))
            merged.required.formUnion(inline.required)
            merged.optional.formUnion(inline.optional)
            merged.types.merge(inline.types) { _, new in new }
        }
        return merged
    }

    private static func shape(ofBody body: String) -> TypeShape {
        var shape = TypeShape()
        for segment in memberSegments(body) {
            guard let member = propertySegment(segment) else { continue }
            shape.types[member.name] = member.type
            if member.optional || member.type.contains("| null") {
                shape.optional.insert(member.name)
            } else {
                shape.required.insert(member.name)
            }
        }
        return shape
    }

    // MARK: Text helpers

    /// Removes `//` and `/* … */` comments, leaving string literals intact.
    static func stripComments(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var index = 0
        var inString = false
        while index < chars.count {
            let char = chars[index]
            let next: Character = index + 1 < chars.count ? chars[index + 1] : " "
            if inString {
                out.append(char)
                if char == "\\", index + 1 < chars.count {
                    out.append(chars[index + 1])
                    index += 2
                    continue
                }
                if char == "\"" { inString = false }
                index += 1
                continue
            }
            if char == "\"" {
                inString = true
                out.append(char)
                index += 1
                continue
            }
            if char == "/", next == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if char == "/", next == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                index += 2
                continue
            }
            out.append(char)
            index += 1
        }
        return String(out)
    }

    /// Every `export interface Name { … }` in the text.
    static func interfaceBodies(_ text: String) -> [String: String] {
        let chars = Array(text)
        let marker = Array("export interface ")
        var bodies: [String: String] = [:]
        var index = 0
        while index + marker.count < chars.count {
            if Array(chars[index..<index + marker.count]) == marker {
                var nameEnd = index + marker.count
                while nameEnd < chars.count, chars[nameEnd] != " ", chars[nameEnd] != "{" { nameEnd += 1 }
                let name = String(chars[(index + marker.count)..<nameEnd])
                guard let open = chars[nameEnd...].firstIndex(of: "{") else { break }
                if let close = matchingBrace(chars, open: open) {
                    bodies[name] = String(chars[(open + 1)..<close])
                    index = close + 1
                    continue
                }
            }
            index += 1
        }
        return bodies
    }

    /// Splits a body at top-level `;` and newlines (nested braces stay intact).
    static func memberSegments(_ body: String) -> [String] {
        let chars = Array(body)
        var segments: [String] = []
        var current: [Character] = []
        var depth = 0
        var inString = false
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if inString {
                current.append(char)
                if char == "\\", index + 1 < chars.count {
                    current.append(chars[index + 1])
                    index += 2
                    continue
                }
                if char == "\"" { inString = false }
                index += 1
                continue
            }
            switch char {
            case "\"": inString = true; current.append(char)
            case "{", "(", "[", "<": depth += 1; current.append(char)
            case "}", ")", "]", ">": depth -= 1; current.append(char)
            case ";", "\n":
                if depth == 0 {
                    segments.append(String(current))
                    current = []
                } else {
                    current.append(char)
                }
            default: current.append(char)
            }
            index += 1
        }
        if !current.isEmpty { segments.append(String(current)) }
        return segments
    }

    /// `name(args: TYPE): Promise<…>` → (name, TYPE).
    static func commandSegment(_ segment: String) -> (String, String)? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") || trimmed.contains("):") else { return nil }
        let name = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        let rest = trimmed[open...]
        guard let argsRange = rest.range(of: "args:") else { return nil }
        let chars = Array(rest[argsRange.upperBound...])
        guard let close = matchingParen(chars) else { return nil }
        let annotation = String(chars[0..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, annotation)
    }

    struct Member {
        let name: String
        let type: String
        let optional: Bool
    }

    /// `name?: type` → member.
    static func propertySegment(_ segment: String) -> Member? {
        var text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("readonly ") { text = String(text.dropFirst("readonly ".count)) }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        var name = text[..<colon].trimmingCharacters(in: .whitespaces)
        var optional = false
        if name.hasSuffix("?") {
            optional = true
            name = String(name.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) else { return nil }
        let type = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return Member(name: name, type: type, optional: optional)
    }

    /// Closing `>` of a generic argument list (`matchingBrace` counts braces).
    private static func matchingAngle(_ chars: [Character], open: Int) -> Int? {
        var depth = 0
        var inString = false
        var index = open
        while index < chars.count {
            let char = chars[index]
            if inString {
                if char == "\\" { index += 2; continue }
                if char == "\"" { inString = false }
                index += 1
                continue
            }
            if char == "\"" { inString = true; index += 1; continue }
            if char == "<" { depth += 1 }
            if char == ">" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func matchingBrace(_ chars: [Character], open: Int) -> Int? {
        var depth = 0
        var index = open
        var inString = false
        while index < chars.count {
            let char = chars[index]
            if inString {
                if char == "\\" { index += 2; continue }
                if char == "\"" { inString = false }
                index += 1
                continue
            }
            if char == "\"" { inString = true; index += 1; continue }
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// Closing `)` of the argument list whose content starts at index 0.
    private static func matchingParen(_ chars: [Character]) -> Int? {
        var depth = 0
        var index = 0
        var inString = false
        while index < chars.count {
            let char = chars[index]
            if inString {
                if char == "\\" { index += 2; continue }
                if char == "\"" { inString = false }
                index += 1
                continue
            }
            switch char {
            case "\"": inString = true
            case "(", "{", "[", "<": depth += 1
            case ")":
                if depth == 0 { return index }
                depth -= 1
            case "}", "]", ">": depth -= 1
            default: break
            }
            index += 1
        }
        return nil
    }
}
