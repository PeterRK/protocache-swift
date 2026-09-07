import Dispatch
import Foundation
import ProtoCache
import ProtoCacheCore

/// Diagnostic workloads use the same public serialization boundary as the
/// comparison fixture. Construction and full output validation are not timed.
func runScale(_ config: BenchConfig) throws {
    let name = config.only!
    let count = config.count
    let suffix = String(repeating: "x", count: config.payload)
    if name == "scale-hash" {
        let keys = (0..<count).map { Array("key-\($0)-\(suffix)".utf8) }
        let check = try PerfectHash.build(keys)
        guard Set(check.positions).count == count,
              check.positions.allSatisfy({ (0..<count).contains($0) }) else {
            throw BenchError("PerfectHash positions are not a permutation")
        }
        try check.index.withUnsafeBytes { raw in
            let view = PerfectHashView(Span(unsafeBorrowing: raw))
            for index in keys.indices {
                guard keys[index].withUnsafeBytes({ view.locate($0) }) == check.positions[index] else {
                    throw BenchError("PerfectHash lookup mismatch at \(index)")
                }
            }
        }
        try measureScale(name, config: config, bytes: check.index.count) {
            let result = try PerfectHash.build(keys)
            return result.index.count + result.positions.count
        }
        return
    }

    var message = Test_Main()
    var owned = Test_MainMutable()
    var objects = MutableMap<Int32, Test_SmallMutable>()
    objects.reserveCapacity(count)
    for index in 0..<count {
        let key = Int32(index)
        let text = "value-\(index)-\(suffix)"
        var child = Test_Small()
        child.i32 = key
        child.str = text
        child.flag = index % 2 == 0
        message.objects[key] = child
        var mutable = Test_SmallMutable()
        mutable.i32 = child.i32
        mutable.str = text
        mutable.flag = child.flag
        objects[key] = mutable
    }
    owned.objects = objects
    let raw = try ProtoCache.serialize(message, as: Test_MainView.self)
    let full = try owned.serialized()
    for output in [raw, full] {
        try output.withView(Test_MainView.self) { root in
            guard root.objects.count == count else { throw BenchError("Map count mismatch") }
            for (key, expected) in message.objects {
                guard let actual = root.objects.value(for: key), actual.i32 == expected.i32,
                      actual.flag == expected.flag, actual.str.equalsUTF8(expected.str) else {
                    throw BenchError("Map value mismatch at \(key)")
                }
            }
        }
    }
    guard raw.count == full.count else { throw BenchError("Map encoded size mismatch") }
    if let path = ProcessInfo.processInfo.environment["PROTOCACHE_BENCH_OUTPUT"] {
        let output = name == "scale-dynamic" ? raw : full
        try output.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: path)) }
    }
    let buffer = SerializationBuffer()
    switch name {
    case "scale-map":
        try measureScale(name, config: config, bytes: full.count) {
            try owned.withSerializedSpan(using: buffer) { $0.count }
        }
    case "scale-dynamic":
        try measureScale(name, config: config, bytes: raw.count) {
            try ProtoCache.withSerializedSpan(message, using: buffer, as: Test_MainView.self) { $0.count }
        }
    default:
        throw BenchError("unknown scale case: \(name)")
    }
}

private func measureScale(
    _ name: String, config: BenchConfig, bytes: Int, _ body: () throws -> Int
) rethrows {
    var warmupChecksum = 0
    for _ in 0..<config.warmup { warmupChecksum &+= try body() }
    var checksum = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<config.loops { checksum &+= try body() }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    print("\(name): count=\(config.count) payload=\(config.payload) warmup_checksum=\(warmupChecksum)")
    BenchmarkMeasurement(name: name, loops: config.loops, elapsed_ns: elapsed,
                         checksum: String(checksum), raw_bytes: bytes).report()
}
