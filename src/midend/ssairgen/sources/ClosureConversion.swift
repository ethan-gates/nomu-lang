import ast
import noir
import ssair
import support

// Closure conversion support: the per-module sink that collects lifted closure bodies and
// their synthesized environment layouts, and the free-variable collection that decides what
// each closure captures (respecting shadowing). Used by FunctionLowerer.lowerClosure.

// Shared across every `FunctionLowerer` in a module: closure conversion lifts each closure body to a
// top-level `SSAFunction` and synthesizes a struct layout for its captured environment. Both accumulate
// here (closures can appear in any function/method and can nest), collected after all bodies lower.
final class ClosureSink {
    var lifted: [SSAFunction] = []
    var envAggregates: [SSAAggregate] = []
    var nextId = 0
}
