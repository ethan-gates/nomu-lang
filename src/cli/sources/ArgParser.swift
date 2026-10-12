// A dependency-free, subcommand-aware argument parser for the `nomu` driver (task 186). Declarative:
// a command states its flags / options / positionals, and parsing, validation, and `--help` fall out of
// the declaration. The parser never prints or exits — it returns a `ParseOutcome` so the caller owns the
// I/O and the exit code (the CLI is the one exit boundary; frontend/README.md P0 no-crash spirit).

// MARK: - Specification

// A boolean, presence-only argument: `--verbose` / `-v`. Short flags compact: `-abc` ≡ `-a -b -c`.
public struct Flag {
    public let long: String
    public let short: Character?
    public let help: String
    public init(_ long: String, short: Character? = nil, help: String = "") {
        self.long = long; self.short = short; self.help = help
    }
}

// A value-taking argument: `--output path` / `--output=path` / `-o path` / `-o=path`. A value-option never
// joins a short cluster. `choices` validates the value against a fixed set; `isList` collects repeated
// occurrences; `commaSplit` additionally splits one occurrence on commas (`--x=a,b` → `[a, b]`).
public struct Opt {
    public let long: String
    public let short: Character?
    public let valueName: String
    public let help: String
    public let defaultValue: String?
    public let choices: [String]?
    public let isList: Bool
    public let commaSplit: Bool
    public let required: Bool
    public init(_ long: String, short: Character? = nil, valueName: String = "value", help: String = "",
                defaultValue: String? = nil, choices: [String]? = nil,
                isList: Bool = false, commaSplit: Bool = false, required: Bool = false) {
        self.long = long; self.short = short; self.valueName = valueName; self.help = help
        self.defaultValue = defaultValue; self.choices = choices
        self.isList = isList; self.commaSplit = commaSplit; self.required = required
    }
}

// A positional argument, in declaration order. A `variadic` positional sucks up the remaining positionals
// (the source-file list); at most one, and it must be last.
public struct Positional {
    public let name: String
    public let help: String
    public let variadic: Bool
    public let required: Bool
    public init(_ name: String, help: String = "", variadic: Bool = false, required: Bool = true) {
        self.name = name; self.help = help; self.variadic = variadic; self.required = required
    }
}

// A command (the root, or a subcommand). The root's `flags`/`options` are **global** — inherited by every
// subcommand (so `-O` / `--mono` are declared once). `passthrough` enables a trailing `--` tail the command
// interprets (`run` forwards it as the executed program's argv).
public struct Command {
    public let name: String
    public let summary: String
    public var flags: [Flag]
    public var options: [Opt]
    public var positionals: [Positional]
    public var subcommands: [Command]
    public var passthrough: Bool
    public init(_ name: String, summary: String = "", flags: [Flag] = [], options: [Opt] = [],
                positionals: [Positional] = [], subcommands: [Command] = [], passthrough: Bool = false) {
        self.name = name; self.summary = summary; self.flags = flags; self.options = options
        self.positionals = positionals; self.subcommands = subcommands; self.passthrough = passthrough
    }
}

// MARK: - Result

// The parse of one command invocation. Flags are present/absent; options and positionals map a name to the
// values seen (a list, so repeated/variadic reads uniformly). `commandPath` is the resolved subcommand chain.
public struct Parsed {
    public let commandPath: [String]
    let flags: Set<String>
    let options: [String: [String]]
    let positionals: [String: [String]]
    public let passthrough: [String]

    public func has(_ flag: String) -> Bool { flags.contains(flag) }
    public func value(_ opt: String) -> String? { options[opt]?.last }
    public func values(_ opt: String) -> [String] { options[opt] ?? [] }
    public func positional(_ name: String) -> String? { positionals[name]?.first }
    public func positionals(_ name: String) -> [String] { positionals[name] ?? [] }
}

public enum ParseOutcome {
    case run(Parsed)       // dispatch to `commandPath`
    case help(String)      // synthesized help text; caller prints to stdout, exits 0
    case version(String)   // caller prints, exits 0
    case error(String)     // message + relevant usage; caller prints to stderr, exits 1
}

// MARK: - Entry

public func parse(_ root: Command, _ argv: [String], version: String? = nil) -> ParseOutcome {
    var cmd = root
    var path = [root.name]
    var globalFlags: [Flag] = []     // flags inherited from ancestor commands (the root's, once descended)
    var globalOptions: [Opt] = []
    var i = 0

    // Descend subcommands: a leading non-dash token that names a subcommand selects it. `--help`/`--version`
    // at any level short-circuit. The root's flags/options accumulate as globals for the chosen subcommand.
    while i < argv.count {
        let tok = argv[i]
        if tok == "--help" || tok == "-h" {
            return .help(helpText(cmd, path: path, version: version,
                                  flags: globalFlags + cmd.flags, options: globalOptions + cmd.options))
        }
        if tok == "--version", let v = version { return .version(v) }
        if !cmd.subcommands.isEmpty, !tok.hasPrefix("-") {
            guard let sub = cmd.subcommands.first(where: { $0.name == tok }) else {
                return .error("unknown subcommand '\(tok)'\n\n"
                    + helpText(cmd, path: path, version: version,
                               flags: globalFlags + cmd.flags, options: globalOptions + cmd.options))
            }
            globalFlags += cmd.flags
            globalOptions += cmd.options
            cmd = sub
            path.append(sub.name)
            i += 1
            continue
        }
        break
    }

    // A command that only groups subcommands, invoked bare, shows its help rather than an empty parse.
    if !cmd.subcommands.isEmpty && i >= argv.count && cmd.positionals.isEmpty {
        return .help(helpText(cmd, path: path, version: version,
                              flags: globalFlags + cmd.flags, options: globalOptions + cmd.options))
    }

    let flags = globalFlags + cmd.flags
    let options = globalOptions + cmd.options
    func flagByLong(_ s: String) -> Flag? { flags.first { $0.long == s } }
    func optByLong(_ s: String) -> Opt? { options.first { $0.long == s } }
    func flagByShort(_ c: Character) -> Flag? { flags.first { $0.short == c } }
    func optByShort(_ c: Character) -> Opt? { options.first { $0.short == c } }

    var seenFlags = Set<String>()
    var optValues = [String: [String]]()
    var positionalTokens = [String]()
    var passthrough = [String]()
    func usage() -> String { helpText(cmd, path: path, version: version, flags: flags, options: options) }
    func fail(_ msg: String) -> ParseOutcome { .error("\(msg)\n\n" + usage()) }

    func record(_ opt: Opt, _ raw: String) -> ParseOutcome? {
        let vals = opt.commaSplit ? raw.split(separator: ",").map(String.init) : [raw]
        for v in vals {
            if let choices = opt.choices, !choices.contains(v) {
                return fail("invalid value '\(v)' for --\(opt.long) (expected: \(choices.joined(separator: ", ")))")
            }
            optValues[opt.long, default: []].append(v)
        }
        if !opt.isList && (optValues[opt.long]?.count ?? 0) > 1 {
            // A non-list option given twice keeps the last; harmless, so no error.
        }
        return nil
    }

    while i < argv.count {
        let tok = argv[i]
        i += 1
        if tok == "--" {
            if cmd.passthrough { passthrough = Array(argv[i...]) }
            else { positionalTokens += argv[i...] }
            break
        }
        if tok == "--help" || tok == "-h" { return .help(usage()) }
        if tok == "--version", let v = version { return .version(v) }

        if tok.hasPrefix("--") {
            let body = String(tok.dropFirst(2))
            let (name, attached) = splitEquals(body)
            if let f = flagByLong(name) {
                if attached != nil { return fail("flag --\(f.long) takes no value") }
                seenFlags.insert(f.long)
            } else if let o = optByLong(name) {
                let v: String
                if let a = attached { v = a }
                else if i < argv.count { v = argv[i]; i += 1 }
                else { return fail("option --\(o.long) requires a value") }
                if let e = record(o, v) { return e }
            } else {
                return fail("unknown option '--\(name)'")
            }
        } else if tok.hasPrefix("-") && tok.count > 1 {
            let body = String(tok.dropFirst())
            let (chars, attached) = splitEquals(body)
            // `-o=value` / `-o value`: a single short char that is a value-option.
            if attached != nil || chars.count == 1 {
                guard let c = chars.first else { return fail("malformed option '\(tok)'") }
                if let o = optByShort(c) {
                    if chars.count != 1 { return fail("cannot attach a value to a short cluster in '\(tok)'") }
                    let v: String
                    if let a = attached { v = a }
                    else if i < argv.count { v = argv[i]; i += 1 }
                    else { return fail("option -\(c) requires a value") }
                    if let e = record(o, v) { return e }
                } else if let f = flagByShort(c) {
                    if attached != nil { return fail("flag -\(f.long) takes no value") }
                    seenFlags.insert(f.long)
                } else {
                    return fail("unknown option '-\(c)'")
                }
            } else {
                // A cluster of short flags: every member must be a value-less flag.
                for c in chars {
                    if let f = flagByShort(c) { seenFlags.insert(f.long) }
                    else if optByShort(c) != nil {
                        return fail("option -\(c) takes a value and cannot be combined in '\(tok)'")
                    } else {
                        return fail("unknown option '-\(c)' in '\(tok)'")
                    }
                }
            }
        } else {
            positionalTokens.append(tok)
        }
    }

    // Defaults for options not seen.
    for o in options where optValues[o.long] == nil {
        if let d = o.defaultValue { optValues[o.long] = [d] }
    }
    // Required options.
    for o in options where o.required && optValues[o.long] == nil {
        return fail("missing required option --\(o.long)")
    }

    // Bind positionals in declaration order; a variadic positional takes the remaining tokens.
    var positionalValues = [String: [String]]()
    var p = 0
    for spec in cmd.positionals {
        if spec.variadic {
            positionalValues[spec.name] = Array(positionalTokens[p...])
            p = positionalTokens.count
        } else if p < positionalTokens.count {
            positionalValues[spec.name] = [positionalTokens[p]]
            p += 1
        } else if spec.required {
            return fail("missing required argument <\(spec.name)>")
        }
    }
    if p < positionalTokens.count {
        return fail("unexpected argument '\(positionalTokens[p])'")
    }
    for spec in cmd.positionals where spec.variadic && spec.required {
        if (positionalValues[spec.name]?.isEmpty ?? true) {
            return fail("missing required argument <\(spec.name)>")
        }
    }

    return .run(Parsed(commandPath: path, flags: seenFlags, options: optValues,
                       positionals: positionalValues, passthrough: passthrough))
}

// MARK: - Helpers

// Split `name=value` into (name, value); no `=` yields (whole, nil).
private func splitEquals(_ s: String) -> (String, String?) {
    guard let eq = s.firstIndex(of: "=") else { return (s, nil) }
    return (String(s[s.startIndex..<eq]), String(s[s.index(after: eq)...]))
}

// MARK: - Help synthesis

// `flags`/`options` are the command's **effective** set (inherited globals + own), so a subcommand's help
// lists the flags it actually accepts.
func helpText(_ cmd: Command, path: [String], version: String?, flags: [Flag], options: [Opt]) -> String {
    var out = ""
    let prog = path.joined(separator: " ")
    if !cmd.summary.isEmpty { out += cmd.summary + "\n\n" }

    // Usage line.
    var usage = "usage: \(prog)"
    if !cmd.subcommands.isEmpty { usage += " <command>" }
    if !flags.isEmpty || !options.isEmpty { usage += " [options]" }
    for pos in cmd.positionals {
        let base = pos.variadic ? "\(pos.name)..." : pos.name
        usage += pos.required ? " <\(base)>" : " [\(base)]"
    }
    if cmd.passthrough { usage += " [-- args...]" }
    out += usage + "\n"

    if !cmd.subcommands.isEmpty {
        out += "\ncommands:\n"
        let w = cmd.subcommands.map { $0.name.count }.max() ?? 0
        for s in cmd.subcommands {
            out += "  \(pad(s.name, w))  \(s.summary)\n"
        }
    }

    if !options.isEmpty || !flags.isEmpty {
        out += "\noptions:\n"
        var rows = [(String, String)]()
        for f in flags { rows.append((flagInvocation(f), f.help)) }
        for o in options { rows.append((optInvocation(o), optHelp(o))) }
        let w = rows.map { $0.0.count }.max() ?? 0
        for (inv, help) in rows {
            out += "  \(pad(inv, w))  \(help)\n"
        }
    }
    return out
}

// Right-pad to `width` with spaces (stdlib-only; avoids Foundation's NSString `padding`).
private func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

private func flagInvocation(_ f: Flag) -> String {
    (f.short.map { "-\($0), " } ?? "") + "--\(f.long)"
}
private func optInvocation(_ o: Opt) -> String {
    (o.short.map { "-\($0), " } ?? "") + "--\(o.long) <\(o.valueName)>"
}
private func optHelp(_ o: Opt) -> String {
    var h = o.help
    if let c = o.choices { h += (h.isEmpty ? "" : " ") + "(\(c.joined(separator: " | ")))" }
    if let d = o.defaultValue { h += (h.isEmpty ? "" : " ") + "[default: \(d)]" }
    return h
}
