import Foundation
import XCTest
import cfgresolver

// Every case under `tests/cases/<case>/`: `args` holds the arguments (one line, split on spaces, paths relative to
// the case directory), the rest is the fixture tree, and `expected` is what the tool prints. To accept a change,
// rewrite the expectations in the source tree (unsandboxed, so the test can write there):
//
//     bazel test //src/config/cfgresolver:cfgresolver_tests --spawn_strategy=local \
//         --test_env=NOMU_UPDATE_GOLDENS=$PWD/src/config/cfgresolver/tests/cases
//
// On a mismatch under `bazel test`, the actual output is written to the test's undeclared outputs.
final class GoldenTests: XCTestCase {
    func testCases() throws {
        let env = ProcessInfo.processInfo.environment
        guard let srcdir = env["TEST_SRCDIR"] else { throw XCTSkip("not under bazel") }
        let root = srcdir + "/_main/src/config/cfgresolver/tests/cases"
        let cases = try FileManager.default.contentsOfDirectory(atPath: root).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertFalse(cases.isEmpty)
        for name in cases {
            let dir = root + "/" + name
            let line = try String(contentsOfFile: dir + "/args", encoding: .utf8)
            let args = line.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            let outcome = cfgresolver.run(args, cwd: dir)
            let actual = outcome.status == 0 ? outcome.text : "exit \(outcome.status)\n" + outcome.text
            if let update = env["NOMU_UPDATE_GOLDENS"] {
                try actual.write(toFile: update + "/\(name)/expected", atomically: true, encoding: .utf8)
                continue
            }
            let expected = (try? String(contentsOfFile: dir + "/expected", encoding: .utf8)) ?? ""
            if actual != expected {
                if let outs = env["TEST_UNDECLARED_OUTPUTS_DIR"] {
                    try? actual.write(toFile: outs + "/\(name).expected", atomically: true, encoding: .utf8)
                }
                XCTFail("case '\(name)' differs from its expected output:\n\(actual)")
            }
        }
    }
}
