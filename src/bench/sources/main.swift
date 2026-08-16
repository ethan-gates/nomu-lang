import parse
import ast
import support
// Frontend throughput benchmark.
//
// Generates a large synthetic Nomu program and times `Lexer.tokenize()` and `Parser.parse()`
// separately, reporting bytes/s, tokens/s, and lines/s for each. Isolated from Sema/codegen/GC so
// it measures the lexer and parser only — the surfaces of the parser-perf work.
//
//   bazel run //src/bench:parsebench -- [units] [iters]
//
// `units` scales the program size (default 3000); `iters` is the timed-run count (default 7, best
// reported to cut noise). A warm-up run precedes timing.


// One unit exercises a representative token mix: a struct with fields, an enum with cases, and a
// function with params, a loop, a branch, arithmetic, comparison, assignment, and a return.
func unit(_ i: Int) -> String {
    """
    struct S\(i) {
        var a: Int
        var b: Int
    }

    enum E\(i) {
        case red
        case green
        case blue
    }

    fun f\(i)(x: Int, y: Int) -> Int {
        var acc = 0
        var i = 0
        while i < x {
            acc = acc + x * y - i / 2
            if acc < 0 {
                acc = acc + 1
            }
            i = i + 1
        }
        return acc
    }

    """
}

func generate(_ units: Int) -> String {
    var s = ""
    s.reserveCapacity(units * 320)
    for i in 0..<units { s += unit(i) }
    return s
}

func nanos(_ d: Duration) -> Int64 {
    let c = d.components
    return c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000
}

func fmt(_ x: Double) -> String {
    // Two decimal places, no Foundation.
    let r = (x * 100).rounded() / 100
    return "\(r)"
}

let args = CommandLine.arguments
let units = args.count > 1 ? (Int(args[1]) ?? 3000) : 3000
let iters = args.count > 2 ? (Int(args[2]) ?? 7) : 7

let source = generate(units)
let byteCount = source.utf8.count
var lineCount = 0
for b in source.utf8 where b == 0x0A { lineCount += 1 }

// Warm-up (not timed): pays first-run costs and lets the generator's allocations settle.
do {
    var l = Lexer(source)
    var p = Parser(l.tokenize())
    _ = p.parse()
}

let clock = ContinuousClock()
var bestLex = Int64.max
var bestParse = Int64.max
var tokenCount = 0
var declCount = 0

for _ in 0..<iters {
    // Time the whole lexer, construction included: `Lexer(source)` runs the `Array(source)`
    // character conversion, which is part of lexing cost (and what a byte-lexer rewrite replaces).
    let t0 = clock.now
    var lexer = Lexer(source)
    let tokens = lexer.tokenize()
    let t1 = clock.now
    var parser = Parser(tokens)
    let program = parser.parse()
    let t2 = clock.now

    tokenCount = tokens.count
    declCount = program.decls.count
    bestLex = min(bestLex, nanos(t1 - t0))
    bestParse = min(bestParse, nanos(t2 - t1))
}

let lexS = Double(bestLex) / 1e9
let parseS = Double(bestParse) / 1e9
let mb = Double(byteCount) / 1e6

print("input:   \(units) units, \(byteCount) bytes, \(lineCount) lines, \(tokenCount) tokens, \(declCount) decls")
print("iters:   \(iters) (best reported)")
print("")
print("lex:     \(fmt(lexS * 1000)) ms   \(fmt(mb / lexS)) MB/s   \(fmt(Double(tokenCount) / lexS / 1e6)) Mtok/s   \(fmt(Double(lineCount) / lexS / 1e6)) Mline/s")
print("parse:   \(fmt(parseS * 1000)) ms   \(fmt(mb / parseS)) MB/s   \(fmt(Double(tokenCount) / parseS / 1e6)) Mtok/s   \(fmt(Double(lineCount) / parseS / 1e6)) Mline/s")
let totalS = lexS + parseS
print("total:   \(fmt(totalS * 1000)) ms   \(fmt(mb / totalS)) MB/s")
