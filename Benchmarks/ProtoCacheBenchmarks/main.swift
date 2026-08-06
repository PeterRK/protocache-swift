import Dispatch
import Foundation
import ProtoCache
import ProtoCacheCore
import SwiftProtobuf

private let defaultLoops = 1_000_000

private struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct BenchConfig {
    let loops: Int
    let only: String?

    static func parse() throws -> BenchConfig? {
        var loops = defaultLoops
        var only: String?
        var index = 1
        let arguments = CommandLine.arguments

        while index < arguments.count {
            switch arguments[index] {
            case "--loops":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]),
                      value > 0 else {
                    throw BenchmarkError("--loops requires a positive integer")
                }
                loops = value
            case "--only":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError("--only requires a benchmark name")
                }
                only = arguments[index]
            case "--help", "-h":
                print("Usage: swift run -c release ProtoCacheBenchmarks [--loops N] [--only NAME]")
                return nil
            default:
                throw BenchmarkError("unknown argument: \(arguments[index])")
            }
            index += 1
        }
        return BenchConfig(loops: loops, only: only)
    }

    func shouldRun(_ name: String) -> Bool {
        only == nil || only == name
    }
}

private struct Junk {
    var u32Sum: UInt32 = 0
    var f32Sum: Float = 0
    var u64Sum: UInt64 = 0
    var f64Sum: Double = 0

    mutating func add(_ value: UInt32) { u32Sum &+= value }
    mutating func add(_ value: UInt64) { u64Sum &+= value }
    mutating func add(_ value: Float) { f32Sum += value }
    mutating func add(_ value: Double) { f64Sum += value }

    func fuse() -> UInt64 {
        (f64Sum + Double(f32Sum)).bitPattern ^ (u64Sum &+ UInt64(u32Sum))
    }
}

@inline(__always)
private func junkHash(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
    var result: UInt32 = 0
    var offset = 0
    while offset + 4 <= bytes.count {
        let word = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        result ^= word
        offset += 4
    }
    return result
}

@inline(__always)
private func junkHash(_ value: Data) -> UInt32 {
    value.withUnsafeBytes { junkHash($0) }
}

@inline(__always)
private func junkHash(_ value: [UInt8]) -> UInt32 {
    value.withUnsafeBytes { junkHash($0) }
}

@inline(__always)
private func junkHash(_ value: String) -> UInt32 {
    if let result = value.utf8.withContiguousStorageIfAvailable({
        junkHash(UnsafeRawBufferPointer($0))
    }) {
        return result
    }

    var result: UInt32 = 0
    var word: UInt32 = 0
    var shift: UInt32 = 0
    for byte in value.utf8 {
        word |= UInt32(byte) << shift
        shift += 8
        if shift == 32 {
            result ^= word
            word = 0
            shift = 0
        }
    }
    return result
}

@inline(__always)
private func junkHash(_ value: StringView) -> UInt32 {
    value.withUnsafeUTF8 { junkHash($0) }
}

@inline(__always)
private func junkHash(_ value: BytesView) -> UInt32 {
    value.withUnsafeBytes { junkHash($0) }
}

@inline(__always)
private func traverseProtobufSmall(_ root: Test_Small, _ junk: inout Junk) {
    junk.add(UInt32(bitPattern: root.i32))
    junk.add(UInt32(root.flag ? 1 : 0))
    junk.add(junkHash(root.str))
}

@inline(__always)
private func traverseProtobufArrMap(_ root: Test_ArrMap, _ junk: inout Junk) {
    for (key, value) in root.___ {
        junk.add(junkHash(key))
        for item in value.___ { junk.add(item) }
    }
}

@inline(__always)
private func traverseProtobuf(_ root: Test_Main, _ junk: inout Junk) {
    junk.add(UInt32(bitPattern: root.i32))
    junk.add(root.u32)
    junk.add(UInt32(root.flag ? 1 : 0))
    junk.add(UInt32(truncatingIfNeeded: root.mode.rawValue))
    junk.add(UInt32(bitPattern: root.tI32))
    junk.add(UInt32(bitPattern: root.tS32))
    junk.add(root.tU32)

    for value in root.i32V { junk.add(UInt32(bitPattern: value)) }
    for value in root.flags { junk.add(UInt32(value ? 1 : 0)) }
    junk.add(junkHash(root.str))
    junk.add(junkHash(root.data))
    for value in root.strv { junk.add(junkHash(value)) }
    for value in root.datav { junk.add(junkHash(value)) }

    junk.add(UInt64(bitPattern: root.i64))
    junk.add(root.u64)
    junk.add(UInt64(bitPattern: root.tI64))
    junk.add(UInt64(bitPattern: root.tS64))
    junk.add(root.tU64)
    for value in root.u64V { junk.add(value) }

    junk.add(root.f32)
    for value in root.f32V { junk.add(value) }
    junk.add(root.f64)
    for value in root.f64V { junk.add(value) }

    if root.hasObject { traverseProtobufSmall(root.object, &junk) }
    for value in root.objectv { traverseProtobufSmall(value, &junk) }

    for (key, value) in root.index {
        junk.add(junkHash(key))
        junk.add(UInt32(bitPattern: value))
    }
    for (key, value) in root.objects {
        junk.add(UInt32(bitPattern: key))
        traverseProtobufSmall(value, &junk)
    }

    if root.hasMatrix {
        for row in root.matrix.___ {
            for value in row.___ { junk.add(value) }
        }
    }
    for value in root.vector { traverseProtobufArrMap(value, &junk) }
    if root.hasArrays { traverseProtobufArrMap(root.arrays, &junk) }
}

@inline(__always)
private func traverseViewSmall(_ root: Test_SmallView, _ junk: inout Junk) {
    junk.add(UInt32(bitPattern: root.i32))
    junk.add(UInt32(root.flag ? 1 : 0))
    junk.add(junkHash(root.str))
}

@inline(__always)
private func traverseViewArrMap(_ root: Test_ArrMapView, _ junk: inout Junk) {
    for pair in root {
        junk.add(junkHash(pair.key))
        for item in pair.value { junk.add(item) }
    }
}

@inline(__always)
private func traverseView(_ root: Test_MainView, _ junk: inout Junk) {
    junk.add(UInt32(bitPattern: root.i32))
    junk.add(root.u32)
    junk.add(UInt32(root.flag ? 1 : 0))
    junk.add(UInt32(bitPattern: root.mode.rawValue))
    junk.add(UInt32(bitPattern: root.tI32))
    junk.add(UInt32(bitPattern: root.tS32))
    junk.add(root.tU32)

    for value in root.i32v { junk.add(UInt32(bitPattern: value)) }
    for value in root.flags { junk.add(UInt32(value ? 1 : 0)) }
    junk.add(junkHash(root.str))
    junk.add(junkHash(root.data))
    for value in root.strv { junk.add(junkHash(value)) }
    for value in root.datav { junk.add(junkHash(value)) }

    junk.add(UInt64(bitPattern: root.i64))
    junk.add(root.u64)
    junk.add(UInt64(bitPattern: root.tI64))
    junk.add(UInt64(bitPattern: root.tS64))
    junk.add(root.tU64)
    for value in root.u64v { junk.add(value) }

    junk.add(root.f32)
    for value in root.f32v { junk.add(value) }
    junk.add(root.f64)
    for value in root.f64v { junk.add(value) }

    traverseViewSmall(root.object, &junk)
    for value in root.objectv { traverseViewSmall(value, &junk) }

    for pair in root.index {
        junk.add(junkHash(pair.key))
        junk.add(UInt32(bitPattern: pair.value))
    }
    for pair in root.objects {
        junk.add(UInt32(bitPattern: pair.key))
        traverseViewSmall(pair.value, &junk)
    }

    for row in root.matrix {
        for value in row { junk.add(value) }
    }
    for value in root.vector { traverseViewArrMap(value, &junk) }
    traverseViewArrMap(root.arrays, &junk)
}

@inline(__always)
private func materializeMutableSmall(_ root: inout Test_SmallMutable, _ junk: inout Junk) {
    let i32 = root.i32
    let flag = root.flag
    let str = root.str
    root.i32 = i32
    root.flag = flag
    root.str = str
    junk.add(UInt32(bitPattern: i32))
    junk.add(UInt32(flag ? 1 : 0))
    junk.add(junkHash(str))
}

private func materializeMutableArrMap(_ root: inout Test_ArrMapMutable, _ junk: inout Junk) {
    var entries = root.value
    for key in Array(entries.keys) {
        guard var array = entries[key] else { continue }
        let values = array.value
        array.value = values
        entries[key] = array
        junk.add(junkHash(key))
        for value in values { junk.add(value) }
    }
    root.value = entries
}

private func materializeAndTraverse(_ root: inout Test_MainMutable, _ junk: inout Junk) {
    let i32 = root.i32
    let u32 = root.u32
    let flag = root.flag
    let mode = root.mode
    let tI32 = root.tI32
    let tS32 = root.tS32
    let tU32 = root.tU32
    root.i32 = i32
    root.u32 = u32
    root.flag = flag
    root.mode = mode
    root.tI32 = tI32
    root.tS32 = tS32
    root.tU32 = tU32
    junk.add(UInt32(bitPattern: i32))
    junk.add(u32)
    junk.add(UInt32(flag ? 1 : 0))
    junk.add(UInt32(bitPattern: mode.rawValue))
    junk.add(UInt32(bitPattern: tI32))
    junk.add(UInt32(bitPattern: tS32))
    junk.add(tU32)

    let i32v = root.i32v
    let flags = root.flags
    let str = root.str
    let data = root.data
    let strv = root.strv
    let datav = root.datav
    root.i32v = i32v
    root.flags = flags
    root.str = str
    root.data = data
    root.strv = strv
    root.datav = datav
    for value in i32v { junk.add(UInt32(bitPattern: value)) }
    for value in flags { junk.add(UInt32(value ? 1 : 0)) }
    junk.add(junkHash(str))
    junk.add(junkHash(data))
    for value in strv { junk.add(junkHash(value)) }
    for value in datav { junk.add(junkHash(value)) }

    let i64 = root.i64
    let u64 = root.u64
    let tI64 = root.tI64
    let tS64 = root.tS64
    let tU64 = root.tU64
    let u64v = root.u64v
    root.i64 = i64
    root.u64 = u64
    root.tI64 = tI64
    root.tS64 = tS64
    root.tU64 = tU64
    root.u64v = u64v
    junk.add(UInt64(bitPattern: i64))
    junk.add(u64)
    junk.add(UInt64(bitPattern: tI64))
    junk.add(UInt64(bitPattern: tS64))
    junk.add(tU64)
    for value in u64v { junk.add(value) }

    let f32 = root.f32
    let f32v = root.f32v
    let f64 = root.f64
    let f64v = root.f64v
    root.f32 = f32
    root.f32v = f32v
    root.f64 = f64
    root.f64v = f64v
    junk.add(f32)
    for value in f32v { junk.add(value) }
    junk.add(f64)
    for value in f64v { junk.add(value) }

    var object = root.object
    materializeMutableSmall(&object, &junk)
    root.object = object

    var objectv = root.objectv
    for index in objectv.indices {
        materializeMutableSmall(&objectv[index], &junk)
    }
    root.objectv = objectv

    let index = root.index
    root.index = index
    for (key, value) in index {
        junk.add(junkHash(key))
        junk.add(UInt32(bitPattern: value))
    }

    var objects = root.objects
    for key in Array(objects.keys) {
        guard var value = objects[key] else { continue }
        junk.add(UInt32(bitPattern: key))
        materializeMutableSmall(&value, &junk)
        objects[key] = value
    }
    root.objects = objects

    var matrix = root.matrix
    var rows = matrix.value
    for index in rows.indices {
        let values = rows[index].value
        rows[index].value = values
        for value in values { junk.add(value) }
    }
    matrix.value = rows
    root.matrix = matrix

    var vector = root.vector
    for index in vector.indices {
        materializeMutableArrMap(&vector[index], &junk)
    }
    root.vector = vector

    var arrays = root.arrays
    materializeMutableArrMap(&arrays, &junk)
    root.arrays = arrays
}

private func materializePartly(_ root: inout Test_MainMutable) {
    let i32 = root.i32
    let u32 = root.u32
    let i64 = root.i64
    let u64 = root.u64
    let flag = root.flag
    let mode = root.mode
    let str = root.str
    let data = root.data
    let f32 = root.f32
    let f64 = root.f64
    root.i32 = i32
    root.u32 = u32
    root.i64 = i64
    root.u64 = u64
    root.flag = flag
    root.mode = mode
    root.str = str
    root.data = data
    root.f32 = f32
    root.f64 = f64
}

@inline(__always)
private func elapsedMilliseconds(since start: UInt64) -> Int {
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return Int((Double(elapsed) / 1_000_000).rounded())
}

private func benchmarkAccess(
    _ name: String,
    bytes: Int,
    loops: Int,
    _ body: (inout Junk) throws -> Void
) rethrows {
    var junk = Junk()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<loops { try body(&junk) }
    let milliseconds = elapsedMilliseconds(since: start)
    print("\(name): \(bytes)B \(milliseconds)ms \(String(format: "%016llx", junk.fuse()))")
}

private func benchmarkSerialize(
    _ name: String,
    loops: Int,
    _ body: () throws -> Int
) rethrows {
    var totalSize = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<loops { totalSize &+= try body() }
    let milliseconds = elapsedMilliseconds(since: start)
    print("\(name): \(milliseconds)ms \(String(totalSize, radix: 16))")
}

private func benchmarkCompression(
    _ name: String,
    raw: UnsafeRawBufferPointer,
    loops: Int
) throws {
    var compressed: [UInt8] = []
    let compressStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<loops {
        ProtoCacheCompression.compress(raw, into: &compressed)
    }
    print("\(name)-compress: \(compressed.count)B \(elapsedMilliseconds(since: compressStart))ms")

    var restored: [UInt8] = []
    let decompressStart = DispatchTime.now().uptimeNanoseconds
    try compressed.withUnsafeBytes { compressedRaw in
        for _ in 0..<loops {
            try ProtoCacheCompression.decompress(compressedRaw, into: &restored)
        }
    }
    guard restored.elementsEqual(raw) else {
        throw BenchmarkError("\(name) decompression roundtrip mismatch")
    }
    print("\(name)-decompress: \(elapsedMilliseconds(since: decompressStart))ms")
}

private func run(_ config: BenchConfig) throws {
    let resource = Bundle.module.url(
        forResource: "test",
        withExtension: "json",
        subdirectory: "Fixtures"
    ) ?? Bundle.module.url(forResource: "test", withExtension: "json")
    guard let resource else { throw BenchmarkError("missing Fixtures/test.json") }

    let json = try Data(contentsOf: resource)
    let protobuf = try Test_Main(jsonUTF8Data: json)
    let protobufRaw = try protobuf.serializedData()
    let protocacheRaw = try ProtoCache.serialize(protobuf, as: Test_MainView.self)

    guard protobufRaw.count == 574 else {
        throw BenchmarkError("unexpected protobuf fixture size: \(protobufRaw.count), expected 574")
    }
    guard protocacheRaw.count == 780 else {
        throw BenchmarkError("unexpected protocache fixture size: \(protocacheRaw.count), expected 780")
    }

    var expectedJunk = Junk()
    traverseView(Test_MainView(protocacheRaw), &expectedJunk)
    let expectedFuse = expectedJunk.fuse()

    func validate(_ name: String, _ bytes: ProtoCacheBytes) throws {
        var junk = Junk()
        let view = Test_MainView(bytes)
        traverseView(view, &junk)
        guard junk.fuse() == expectedFuse else {
            throw BenchmarkError(
                "\(name) semantic checksum mismatch: "
                    + String(format: "%016llx", junk.fuse())
                    + ", expected "
                    + String(format: "%016llx", expectedFuse)
            )
        }
    }

    var fullyValidationRoot = Test_MainMutable(protocacheRaw)
    var fullyValidationJunk = Junk()
    materializeAndTraverse(&fullyValidationRoot, &fullyValidationJunk)
    let fullyValidationBytes = try fullyValidationRoot.serialized()
    try validate("protocache-fully", fullyValidationBytes)

    var partlyValidationRoot = Test_MainMutable(protocacheRaw)
    materializePartly(&partlyValidationRoot)
    let partlyValidationBytes = try partlyValidationRoot.serialized()
    try validate("protocache-partly", partlyValidationBytes)

    if let output = ProcessInfo.processInfo.environment["PROTOCACHE_BENCH_OUTPUT"] {
        let data = protocacheRaw.withUnsafeBytes {
            Data(bytes: $0.baseAddress!, count: $0.count)
        }
        try data.write(to: URL(fileURLWithPath: output))
    }

    print("ProtoCache Swift benchmark (Rust-aligned common cases)")
    print("loops=\(config.loops) protobuf=\(protobufRaw.count)B protocache=\(protocacheRaw.count)B")
    print("readonly traversal hashes UTF-8/bytes without String decoding")
    print("serialize cases use allocating Swift APIs; Rust reference reuses its Buffer")
    print("serialize total_size unit matches Rust: protobuf bytes, ProtoCache words")
    print("validated EX output: fully=\(fullyValidationBytes.count)B partly=\(partlyValidationBytes.count)B")

    if config.shouldRun("protobuf") {
        try benchmarkAccess("protobuf", bytes: protobufRaw.count, loops: config.loops) { junk in
            let root = try Test_Main(serializedBytes: protobufRaw)
            traverseProtobuf(root, &junk)
        }
    }

    if config.shouldRun("protocache") {
        benchmarkAccess("protocache", bytes: protocacheRaw.count, loops: config.loops) { junk in
            traverseView(Test_MainView(protocacheRaw), &junk)
        }
    }

    if config.shouldRun("protocache-ex") {
        benchmarkAccess("protocache-ex", bytes: protocacheRaw.count, loops: config.loops) { junk in
            var root = Test_MainMutable(protocacheRaw)
            materializeAndTraverse(&root, &junk)
        }
    }

    let serializeNames: Set<String> = [
        "protobuf-serialize",
        "protocache-serialize",
        "protocache-fully",
        "protocache-partly",
    ]
    if config.only == nil || config.only.map(serializeNames.contains) == true {
        print("========serialize========")
    }

    if config.shouldRun("protobuf-serialize") {
        try benchmarkSerialize("protobuf-serialize", loops: config.loops) {
            try protobuf.serializedData().count
        }
    }

    if config.shouldRun("protocache-serialize") {
        try benchmarkSerialize("protocache-serialize", loops: config.loops) {
            (try ProtoCache.serialize(protobuf, as: Test_MainView.self)).count / 4
        }
    }

    if config.shouldRun("protocache-fully") {
        var root = Test_MainMutable(protocacheRaw)
        var junk = Junk()
        materializeAndTraverse(&root, &junk)
        try benchmarkSerialize("protocache-fully", loops: config.loops) {
            (try root.serialized()).count / 4
        }
    }

    if config.shouldRun("protocache-partly") {
        var root = Test_MainMutable(protocacheRaw)
        materializePartly(&root)
        try benchmarkSerialize("protocache-partly", loops: config.loops) {
            (try root.serialized()).count / 4
        }
    }

    let compressionNames: Set<String> = ["pb-compress", "pc-compress"]
    if config.only == nil || config.only.map(compressionNames.contains) == true {
        print("========compress========")
    }

    if config.shouldRun("pb-compress") {
        let bytes = [UInt8](protobufRaw)
        try bytes.withUnsafeBytes {
            try benchmarkCompression("pb", raw: $0, loops: config.loops)
        }
    }

    if config.shouldRun("pc-compress") {
        try protocacheRaw.withUnsafeBytes {
            try benchmarkCompression("pc", raw: $0, loops: config.loops)
        }
    }
}

if let config = try BenchConfig.parse() {
    try run(config)
}
