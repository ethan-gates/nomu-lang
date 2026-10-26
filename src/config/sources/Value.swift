// Setting types and values (task 198, G8). A declared value keeps its YAML Core type (`42` is an integer,
// `"42"` a string, as the YAML decoder reads them), and a setting's type checks it.

// The type of a setting's value.
public indirect enum ValueType: Equatable {
    case bool
    // A signed integer, optionally limited to a range.
    case int(ClosedRange<Int64>?)
    // A byte count: a non-negative integer, or a string of digits with a binary suffix (`64K`, `64M`, `2G`,
    // `1T`, each a power of 1024).
    case size
    // One of a fixed set of names.
    case choice([String])
    case string
    // A list of scalar values.
    case list(ValueType)

    // Whether `value` is a value of this type.
    public func admits(_ value: Value) -> Bool {
        switch (self, value) {
        case (.bool, .bool), (.string, .string): return true
        case let (.int(range), .int(v)): return range?.contains(v) ?? true
        case let (.size, .size(v)): return v >= 0
        case let (.choice(cases), .choice(v)): return cases.contains(v)
        case let (.list(element), .list(items)): return items.allSatisfy(element.admits)
        default: return false
        }
    }

    // The type as a report or message names it: `int (0...300)`, `one of bake, broil, convect`.
    public var description: String {
        switch self {
        case .bool: return "bool"
        case .int(nil): return "int"
        case let .int(range?): return "int (\(range.lowerBound)...\(range.upperBound))"
        case .size: return "size"
        case let .choice(cases): return "one of " + cases.joined(separator: ", ")
        case .string: return "string"
        case let .list(element): return "list of \(element.description)"
        }
    }

    // Reads a declared value as this type.
    func read(_ raw: RawValue) -> Result<Value, ValueProblem> {
        switch (self, raw) {
        case (.bool, .boolean(let b)):
            return .success(.bool(b))

        case (.int(let range), .integer(let v)):
            return checkRange(v, range)

        case (.size, .integer(let v)):
            return v >= 0 ? .success(.size(v)) : .failure(ValueProblem("a size cannot be negative"))
        case (.size, .string(let t)):
            guard let v = ValueType.size(t) else {
                return .failure(ValueProblem("expected a size, found `\(t)`",
                                             fix: "write a byte count, or digits with K, M, G or T: `64M`"))
            }
            return .success(.size(v))

        case (.choice(let cases), .string(let t)):
            guard cases.contains(t) else {
                let fix = closest(t, cases).map { "did you mean `\($0)`?" }
                return .failure(ValueProblem("`\(t)` is not one of \(cases.joined(separator: ", "))", fix: fix))
            }
            return .success(.choice(t))

        case (.string, .string(let t)):
            return .success(.string(t))
        case (.string, .integer), (.string, .float), (.string, .boolean):
            return .failure(ValueProblem("expected a string, found \(raw.kindName)",
                                         fix: "quote it: \"\(raw.spelling)\""))

        case (.list(let element), .list(let items)):
            var values: [Value] = []
            for item in items {
                switch element.read(item) {
                case .success(let v): values.append(v)
                case .failure(let problem): return .failure(problem)
                }
            }
            return .success(.list(values))

        default:
            return .failure(ValueProblem("expected \(description), found \(raw.kindName)"))
        }
    }

    private func checkRange(_ v: Int64, _ range: ClosedRange<Int64>?) -> Result<Value, ValueProblem> {
        if let range, !range.contains(v) {
            return .failure(ValueProblem("\(v) is outside \(range.lowerBound)...\(range.upperBound)"))
        }
        return .success(.int(v))
    }

    // A size spelling: digits with an optional K, M, G or T suffix; nil when malformed or past signed 64-bit.
    static func size(_ t: String) -> Int64? {
        var digits = Substring(t)
        var shift: Int64 = 0
        switch t.last {
        case "K": shift = 10
        case "M": shift = 20
        case "G": shift = 30
        case "T": shift = 40
        default: break
        }
        if shift > 0 { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int64(digits) else {
            return nil
        }
        guard n <= Int64.max >> shift else { return nil }
        return n << shift
    }
}

// A setting's value, checked against its type.
public enum Value: Hashable {
    case bool(Bool)
    case int(Int64)
    // A byte count.
    case size(Int64)
    case choice(String)
    case string(String)
    case list([Value])

    // The value in canonical form, the spelling a job file writes and the cache key hashes (G2): one spelling
    // per value, so spellings that mean the same value hash alike (`64M` and `67108864`). Strings are quoted,
    // so the form never contains a line break.
    public var canonical: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .int(let v), .size(let v): return String(v)
        case .choice(let c): return c
        case .string(let s): return Value.quoted(s)
        case .list(let items): return "[" + items.map(\.canonical).joined(separator: ", ") + "]"
        }
    }

    // The value as a person reads it: a size in the largest unit that divides it (`64M`).
    public var description: String {
        switch self {
        case .size(let v):
            for (suffix, shift) in [("T", 40), ("G", 30), ("M", 20), ("K", 10)] where v != 0 && v & ((1 << shift) - 1) == 0 {
                return "\(v >> shift)\(suffix)"
            }
            return String(v)
        case .list(let items): return "[" + items.map(\.description).joined(separator: ", ") + "]"
        default: return canonical
        }
    }

    // The value as a declaration of it, which reads back as the same value.
    var raw: RawValue {
        switch self {
        case .bool(let b): return .boolean(b)
        case .int(let v), .size(let v): return .integer(v)
        case .choice(let s), .string(let s): return .string(s)
        case .list(let items): return .list(items.map(\.raw))
        }
    }

    // A double-quoted string: `"` and `\` escaped, control characters as `\u{…}`.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where u.value < 0x20 || u.value == 0x7F: out += "\\u{\(String(u.value, radix: 16))}"
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

extension ValueType {
    // Reads a value's canonical form (`Value.canonical`) back as this type: the spelling a job file carries.
    // Nil when the text is not a canonical value of this type.
    public func value(canonical text: String) -> Value? {
        var scanner = CanonicalScanner(Array(text.unicodeScalars))
        guard let v = scanner.value(self), scanner.atEnd, admits(v) else { return nil }
        return v
    }
}

private struct CanonicalScanner {
    let text: [Unicode.Scalar]
    var i = 0
    init(_ text: [Unicode.Scalar]) { self.text = text }

    var atEnd: Bool { i == text.count }

    mutating func value(_ type: ValueType) -> Value? {
        switch type {
        case .bool:
            let w = word()
            return w == "true" ? .bool(true) : w == "false" ? .bool(false) : nil
        case .int: return Int64(word()).map(Value.int)
        case .size: return Int64(word()).map(Value.size)
        case .choice: return .choice(word())
        case .string: return quoted().map(Value.string)
        case .list(let element):
            guard take("[") else { return nil }
            var items: [Value] = []
            if take("]") { return .list(items) }
            while true {
                guard let v = value(element) else { return nil }
                items.append(v)
                if take("]") { return .list(items) }
                guard take(","), take(" ") else { return nil }
            }
        }
    }

    // Characters up to a list separator or the end.
    mutating func word() -> String {
        var out = String.UnicodeScalarView()
        while i < text.count, text[i] != ",", text[i] != "]" { out.append(text[i]); i += 1 }
        return String(out)
    }

    mutating func take(_ c: Unicode.Scalar) -> Bool {
        guard i < text.count, text[i] == c else { return false }
        i += 1
        return true
    }

    // A string as `Value.quoted` writes it.
    mutating func quoted() -> String? {
        guard take("\"") else { return nil }
        var out = String.UnicodeScalarView()
        while i < text.count {
            let c = text[i]
            i += 1
            if c == "\"" { return String(out) }
            guard c == "\\" else { out.append(c); continue }
            guard i < text.count else { return nil }
            let e = text[i]
            i += 1
            switch e {
            case "\"", "\\": out.append(e)
            case "u":
                guard take("{") else { return nil }
                var hex = ""
                while i < text.count, text[i] != "}" { hex.unicodeScalars.append(text[i]); i += 1 }
                guard take("}"), let n = UInt32(hex, radix: 16), let u = Unicode.Scalar(n) else { return nil }
                out.append(u)
            default: return nil
            }
        }
        return nil
    }
}

// A value as a source declares it, before it is checked against a setting's type.
public indirect enum RawValue: Equatable {
    // YAML scalars, with their Core types.
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case null
    case list([RawValue])

    var kindName: String {
        switch self {
        case .string: return "a string"
        case .integer: return "an integer"
        case .float: return "a float"
        case .boolean: return "a bool"
        case .null: return "null"
        case .list: return "a list"
        }
    }

    // A scalar's spelling, for a fix that quotes it.
    var spelling: String {
        switch self {
        case .string(let s): return s
        case .integer(let v): return String(v)
        case .float(let v): return String(v)
        case .boolean(let b): return b ? "true" : "false"
        case .null: return "null"
        case .list: return ""
        }
    }
}

// Why a declared value does not read as its setting's type.
struct ValueProblem: Error {
    let message: String
    let fix: String?
    init(_ message: String, fix: String? = nil) {
        self.message = message
        self.fix = fix
    }
}
