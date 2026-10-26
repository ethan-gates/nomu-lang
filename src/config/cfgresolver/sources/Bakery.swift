import config

// The test schema: a made-up bakery, so tests read like real configuration and never change with the
// compiler's settings. Its settings cover every type, both merge rules and all three granularities.
public enum Bakery {
    public static let schema = Schema(
        settings: [
            Setting("oven.mode", .choice(["bake", "broil", "convect"]), default: .choice("bake"),
                    doc: "How the oven heats.", targets: [.compile], granularity: .module),
            Setting("oven.temp", .int(0...300), default: .int(180),
                    doc: "Oven temperature in degrees.", targets: [.compile], granularity: .module,
                    configValues: [.init(["release"], .int(220))]),
            Setting("dough.proof", .bool, default: .bool(true),
                    doc: "Whether dough rises before baking.", targets: [.compile], granularity: .module,
                    configValues: [.init(["test"], .bool(false))]),
            Setting("dough.flours", .list(.string), default: .list([.string("wheat")]),
                    doc: "Flours mixed into the dough.", targets: [.compile], granularity: .module, merge: .append),
            Setting("pantry.capacity", .size, default: .size(64 << 20),
                    doc: "Pantry space.", targets: [.compile, .run], granularity: .program),
            Setting("shop.name", .string, default: .string("corner"),
                    doc: "The shop's sign.", targets: [.run], granularity: .program),
            Setting("shop.ledger", .string, default: .string("ledger"),
                    doc: "Where sales are written.", targets: [.build], granularity: .build),
        ],
        configs: [("debug", nil), ("release", nil), ("test", "debug")])
}
