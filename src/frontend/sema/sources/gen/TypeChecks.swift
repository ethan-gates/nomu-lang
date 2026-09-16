import noir
import ast
import support
// Scalar operator typing: the result type (and operand-compatibility diagnostics) of the
// binary and unary operators, reached from expression checking.
//
//   • Arithmetic / bitwise / shift produce the operand type (both sides must match, no implicit
//     conversion); comparison / equality / logical produce Bool.
//   • Unary `-x` / `!x` / `~x` desugar to a binary form so no unary node reaches NOIR.
//   • A bare integer literal opposite a UInt8/UInt64 operand adopts that type (range-checked).
//
// A capability namespace over `Sema`. The pure classifier / literal-adoption helpers take no
// `Sema`; `binaryResult` and `checkComparison` read diagnostics (`borrowing Sema`); `checkUnary`
// checks its operand through the walk (`NOIRGen.checkExpr`), so it takes `inout Sema`.
enum TypeChecks {

    static func binaryResult(_ s: borrowing Sema, _ op: BinOp, _ lhs: NOIRExpr, _ rhs: NOIRExpr, at span: Span) -> Type {
        switch op {
        case .add, .sub, .mul, .div, .mod:
            // Arithmetic is Int, UInt8, or Double, with no implicit conversion between them: both
            // operands must be the same numeric type (use `.double`/`.int`/`.uint8` to convert).
            func numeric(_ t: Type, _ span: Span) -> Bool {
                if t == .int || t == .uint8 || t == .uint64 || t == .double { return true }
                if t != .error { s.diags.error("arithmetic requires Int, UInt8, UInt64, or Double, got '\(t)'", at: span) }
                return false
            }
            let lok = numeric(lhs.type, lhs.span), rok = numeric(rhs.type, rhs.span)
            if lok && rok && lhs.type != rhs.type {
                s.diags.error("arithmetic operands must match: '\(lhs.type)' and '\(rhs.type)' (no implicit conversion)", at: lhs.span)
                return lok ? lhs.type : .int
            }
            return lok ? lhs.type : (rok ? rhs.type : .int)
        case .bitAnd, .bitOr, .bitXor, .shl, .shr:
            // Bitwise and shift are integer-only (Int or UInt8), operands the same type. `>>` is an
            // arithmetic shift on the signed Int and a logical shift on the unsigned UInt8 (egress).
            func integral(_ t: Type, _ span: Span) -> Bool {
                if t == .int || t == .uint8 || t == .uint64 { return true }
                if t != .error { s.diags.error("bitwise and shift operators require Int, UInt8, or UInt64, got '\(t)'", at: span) }
                return false
            }
            let lok = integral(lhs.type, lhs.span), rok = integral(rhs.type, rhs.span)
            if lok && rok && lhs.type != rhs.type {
                s.diags.error("bitwise operands must match: '\(lhs.type)' and '\(rhs.type)' (no implicit conversion)", at: lhs.span)
                return lok ? lhs.type : .int
            }
            return lok ? lhs.type : (rok ? rhs.type : .int)
        case .lt, .gt, .lte, .gte:
            checkComparison(s, lhs, rhs, equality: false, at: span)
            return .bool
        case .eq, .neq:
            checkComparison(s, lhs, rhs, equality: true, at: span)
            return .bool
        case .and, .or:
            // Logical `&&` / `||`: both operands Bool, result Bool. Short-circuit lowering happens
            // in SSAIRgen; here it types like any Bool-producing operator.
            let sym = op == .and ? "&&" : "||"
            if lhs.type != .bool && lhs.type != .error {
                s.diags.error("logical '\(sym)' requires Bool, got '\(lhs.type)'", at: lhs.span)
            }
            if rhs.type != .bool && rhs.type != .error {
                s.diags.error("logical '\(sym)' requires Bool, got '\(rhs.type)'", at: rhs.span)
            }
            return .bool
        }
    }

    // A comparison / equality operator (result Bool), vs a value op (result = operand type).
    static func isComparisonOp(_ op: BinOp) -> Bool {
        switch op {
        case .eq, .neq, .lt, .gt, .lte, .gte: return true
        default:                              return false
        }
    }

    // `-x` / `!x` / `~x` desugar to a binary form so no unary node reaches NOIR (or the egress):
    // `-x` → `0 - x`, `!x` → `x == false`, `~x` → `x ^ allOnes`. `expected` flows into the operand
    // for the value ops (`-`, `~`) so a UInt8 context reaches its literal.
    static func checkUnary(_ s: inout Sema, _ op: UnaryOp, _ operand: Expr, at span: Span, expected: Type?) -> NOIRExpr {
        let x = NOIRGen.checkExpr(&s, operand, expected: expected)
        switch op {
        case .neg:
            switch x.type {
            case .int, .uint8, .uint64:
                let zero = NOIRExpr(type: x.type, span: span, kind: .intLit(0))
                return NOIRExpr(type: x.type, span: span, kind: .binary(.sub, zero, x))
            case .double:
                let zero = NOIRExpr(type: .double, span: span, kind: .doubleLit(0))
                return NOIRExpr(type: .double, span: span, kind: .binary(.sub, zero, x))
            default:
                if x.type != .error { s.diags.error("unary '-' requires Int, UInt8, or Double, got '\(x.type)'", at: span) }
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
        case .not:
            guard x.type == .bool || x.type == .error else {
                s.diags.error("unary '!' requires Bool, got '\(x.type)'", at: span)
                return NOIRExpr(type: .bool, span: span, kind: .boolLit(false))
            }
            let f = NOIRExpr(type: .bool, span: span, kind: .boolLit(false))
            return NOIRExpr(type: .bool, span: span, kind: .binary(.eq, x, f))
        case .bitNot:
            switch x.type {
            case .int:
                let ones = NOIRExpr(type: .int, span: span, kind: .intLit(-1))
                return NOIRExpr(type: .int, span: span, kind: .binary(.bitXor, x, ones))
            case .uint8:
                let ones = NOIRExpr(type: .uint8, span: span, kind: .intLit(255))
                return NOIRExpr(type: .uint8, span: span, kind: .binary(.bitXor, x, ones))
            case .uint64:
                let ones = NOIRExpr(type: .uint64, span: span, kind: .intLit(-1))
                return NOIRExpr(type: .uint64, span: span, kind: .binary(.bitXor, x, ones))
            default:
                if x.type != .error { s.diags.error("unary '~' requires Int, UInt8, or UInt64, got '\(x.type)'", at: span) }
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
        }
    }

    // Let an integer literal opposite a UInt8 operand adopt UInt8 (range-checked), so `b + 1` and
    // `b & 240` typecheck without an explicit conversion. Only a literal moves — a non-literal Int
    // never silently becomes UInt8.
    static func adoptUInt8Literal(_ op: BinOp, _ lhs: NOIRExpr, _ rhs: NOIRExpr) -> (NOIRExpr, NOIRExpr) {
        func asType(_ e: NOIRExpr, _ target: Type, range: ClosedRange<Int>? = nil) -> NOIRExpr? {
            guard case .intLit(let v) = e.kind, e.type == .int, v >= 0 else { return nil }
            if let r = range, !r.contains(v) { return nil }
            return NOIRExpr(type: target, span: e.span, kind: .intLit(v))
        }
        if lhs.type == .uint8, let r = asType(rhs, .uint8, range: 0...255) { return (lhs, r) }
        if rhs.type == .uint8, let l = asType(lhs, .uint8, range: 0...255) { return (l, rhs) }
        // A bare nonnegative Int literal adopts UInt64 against a UInt64 operand (`w << 8`, `w & 255`).
        if lhs.type == .uint64, let r = asType(rhs, .uint64) { return (lhs, r) }
        if rhs.type == .uint64, let l = asType(lhs, .uint64) { return (l, rhs) }
        return (lhs, rhs)
    }

    // Comparison operators are numeric-only for now (a holistic operator design comes later).
    // Relational (`< > <= >=`) allows Int/Double; equality (`== !=`) also allows Bool. Both sides
    // must be the same type. Strings compare with `.eq`, not `==`; aggregates have no operator yet.
    static func checkComparison(_ s: borrowing Sema, _ lhs: NOIRExpr, _ rhs: NOIRExpr, equality: Bool, at span: Span) {
        if lhs.type == .error || rhs.type == .error { return }
        let allowed: [Type] = equality ? [.int, .uint8, .uint64, .double, .bool] : [.int, .uint8, .uint64, .double]
        if lhs.type != rhs.type {
            s.diags.error("cannot compare '\(lhs.type)' and '\(rhs.type)'", at: span)
            return
        }
        guard allowed.contains(lhs.type) else {
            if lhs.type == .string && equality {
                s.diags.error("String has no '==' / '!=' operator yet — use '.eq(...)'", at: span)
            } else {
                s.diags.error("type '\(lhs.type)' does not support comparison", at: span)
            }
            return
        }
    }
}
