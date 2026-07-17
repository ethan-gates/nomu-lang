import Foundation
import driver

var emit = EmitMode.binary
var file: String? = nil

for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--emit-ast": emit = .ast
    case "--emit-c":   emit = .c
    default:
        guard arg.hasPrefix("--") == false else {
            fputs("error: unknown flag '\(arg)'\n", stderr)
            exit(1)
        }
        file = arg
    }
}

guard let path = file else {
    fputs("usage: nomuc [--emit-ast | --emit-c] <file.nomu>\n", stderr)
    exit(1)
}

compile(path: path, emit: emit)
