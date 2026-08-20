// A timing sink threaded through the pipeline so a stage measured deep in a module (an SSAIR pass,
// an LLVM sub-stage) reports up to the driver's `Timings` without the lower module depending on it.
// `phase` is the pipeline phase the stage belongs to (parse / noir / ssair / llvm / …), `name` the
// stage within it, `seconds` its wall time. See `driver/Timings` (the recorder) and its producers
// (`llvmgen/LLVMBridge.emitObject`, `ssairpasses/PassPipeline.run`).
public typealias StageSink = (_ phase: String, _ name: String, _ seconds: Double) -> Void
