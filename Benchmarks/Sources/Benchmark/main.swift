import Dispatch
import FlatBuffers
import Foundation
import ProtoCache
import ProtoCacheCore
import SwiftProtobuf

private let defaultLoops = 1_000_000

private struct BenchError: Error, CustomStringConvertible {
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
                    throw BenchError("--loops requires a positive integer")
                }
                loops = value
            case "--only":
                index += 1
                guard index < arguments.count else {
                    throw BenchError("--only requires a benchmark name")
                }
                only = arguments[index]
            case "--help", "-h":
                print("Usage: swift run --package-path Benchmarks -c release Benchmark [--loops N] [--only NAME]")
                return nil
            default:
                throw BenchError("unknown argument: \(arguments[index])")
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
private func junkHash(_ value: FlatbufferVector<Int8>) -> UInt32 {
    var result: UInt32 = 0
    var word: UInt32 = 0
    var shift: UInt32 = 0
    for byte in value {
        word |= UInt32(UInt8(bitPattern: byte)) << shift
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
private func readPB(_ root: Test_Small, _ junk: inout Junk) {
    junk.add(UInt32(bitPattern: root.i32))
    junk.add(UInt32(root.flag ? 1 : 0))
    junk.add(junkHash(root.str))
}

@inline(__always)
private func readPB(_ root: Test_ArrMap, _ junk: inout Junk) {
    for (key, value) in root.___ {
        junk.add(junkHash(key))
        for item in value.___ { junk.add(item) }
    }
}

@inline(__always)
private func readPB(_ root: Test_Main, _ junk: inout Junk) {
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

    if root.hasObject { readPB(root.object, &junk) }
    for value in root.objectv { readPB(value, &junk) }

    for (key, value) in root.index {
        junk.add(junkHash(key))
        junk.add(UInt32(bitPattern: value))
    }
    for (key, value) in root.objects {
        junk.add(UInt32(bitPattern: key))
        readPB(value, &junk)
    }

    if root.hasMatrix {
        for row in root.matrix.___ {
            for value in row.___ { junk.add(value) }
        }
    }
    for value in root.vector { readPB(value, &junk) }
    if root.hasArrays { readPB(root.arrays, &junk) }
}

@inline(__always)
private func readFB(_ root: test_Small, _ junk: inout Junk) {
    junk.add(UInt32(bitPattern: root.i32))
    junk.add(UInt32(root.flag ? 1 : 0))
    if let value = root.str { junk.add(junkHash(value)) }
}

@inline(__always)
private func readFB(_ root: test_Vec2D, _ junk: inout Junk) {
    for row in root._X_ {
        for value in row._X_ { junk.add(value) }
    }
}

@inline(__always)
private func readFB(_ root: test_ArrMap, _ junk: inout Junk) {
    for entry in root._X_ {
        junk.add(junkHash(entry.key))
        if let array = entry.value {
            for value in array._X_ { junk.add(value) }
        }
    }
}

@inline(__always)
private func readFB(_ root: test_Main, _ junk: inout Junk) {
    junk.add(UInt32(bitPattern: root.i32))
    junk.add(root.u32)
    junk.add(UInt32(root.flag ? 1 : 0))
    junk.add(UInt32(bitPattern: Int32(root.mode.rawValue)))
    junk.add(UInt32(bitPattern: root.tI32))
    junk.add(UInt32(bitPattern: root.tS32))
    junk.add(root.tU32)

    for value in root.i32v { junk.add(UInt32(bitPattern: value)) }
    for value in root.flags { junk.add(UInt32(value ? 1 : 0)) }
    if let value = root.str { junk.add(junkHash(value)) }
    junk.add(junkHash(root.data))
    for value in root.strv {
        if let value { junk.add(junkHash(value)) }
    }
    for value in root.datav { junk.add(junkHash(value._X_)) }

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

    if let object = root.object { readFB(object, &junk) }
    for value in root.objectv { readFB(value, &junk) }

    for entry in root.index {
        junk.add(junkHash(entry.key))
        junk.add(UInt32(bitPattern: entry.value))
    }
    for entry in root.objects {
        junk.add(UInt32(bitPattern: entry.key))
        if let value = entry.value { readFB(value, &junk) }
    }

    if let matrix = root.matrix { readFB(matrix, &junk) }
    for value in root.vector { readFB(value, &junk) }
    if let arrays = root.arrays { readFB(arrays, &junk) }
}

@inline(__always)
private func readPC(_ root: borrowing Test_SmallView, _ junk: inout Junk) {
    junk.add(UInt32(bitPattern: root.i32))
    junk.add(UInt32(root.flag ? 1 : 0))
    junk.add(junkHash(root.str))
}

@inline(__always)
private func readPC(_ root: borrowing Test_ArrMapView, _ junk: inout Junk) {
    root.forEach { key, value in
        junk.add(junkHash(key))
        value.forEach { junk.add($0) }
    }
}

@inline(__always)
private func readPC(_ root: borrowing Test_MainView, _ junk: inout Junk) {
    junk.add(UInt32(bitPattern: root.i32))
    junk.add(root.u32)
    junk.add(UInt32(root.flag ? 1 : 0))
    junk.add(UInt32(bitPattern: root.mode.rawValue))
    junk.add(UInt32(bitPattern: root.tI32))
    junk.add(UInt32(bitPattern: root.tS32))
    junk.add(root.tU32)

    root.i32v.forEach { junk.add(UInt32(bitPattern: $0)) }
    root.flags.forEach { junk.add(UInt32($0 ? 1 : 0)) }
    junk.add(junkHash(root.str))
    junk.add(junkHash(root.data))
    root.strv.forEach { junk.add(junkHash($0)) }
    root.datav.forEach { junk.add(junkHash($0)) }

    junk.add(UInt64(bitPattern: root.i64))
    junk.add(root.u64)
    junk.add(UInt64(bitPattern: root.tI64))
    junk.add(UInt64(bitPattern: root.tS64))
    junk.add(root.tU64)
    root.u64v.forEach { junk.add($0) }

    junk.add(root.f32)
    root.f32v.forEach { junk.add($0) }
    junk.add(root.f64)
    root.f64v.forEach { junk.add($0) }

    readPC(root.object, &junk)
    root.objectv.forEach { readPC($0, &junk) }

    root.index.forEach { key, value in
        junk.add(junkHash(key))
        junk.add(UInt32(bitPattern: value))
    }
    root.objects.forEach { key, value in
        junk.add(UInt32(bitPattern: key))
        readPC(value, &junk)
    }

    root.matrix.forEach { row in row.forEach { junk.add($0) } }
    root.vector.forEach { readPC($0, &junk) }
    readPC(root.arrays, &junk)
}

@inline(__always)
private func readMutable(_ root: inout Test_SmallMutable, _ junk: inout Junk) {
    let i32 = root.i32
    let flag = root.flag
    let str = root.str
    junk.add(UInt32(bitPattern: i32))
    junk.add(UInt32(flag ? 1 : 0))
    junk.add(junkHash(str))
}

private func readMutable(_ root: inout Test_ArrMapMutable, _ junk: inout Junk) {
    root.value.forEachMutable { key, array in
        let values = array.value
        junk.add(junkHash(key))
        for value in values { junk.add(value) }
    }
}

private func readMutable(_ values: inout [Test_SmallMutable], _ junk: inout Junk) {
    for index in values.indices { readMutable(&values[index], &junk) }
}

private func readMutable(_ values: inout MutableMap<Int32, Test_SmallMutable>, _ junk: inout Junk) {
    values.forEachMutable { key, value in
        junk.add(UInt32(bitPattern: key))
        readMutable(&value, &junk)
    }
}

private func readMutable(_ root: inout Test_Vec2DMutable, _ junk: inout Junk) {
    for index in root.value.indices {
        let values = root.value[index].value
        for value in values { junk.add(value) }
    }
}

private func readMutable(_ values: inout [Test_ArrMapMutable], _ junk: inout Junk) {
    for index in values.indices { readMutable(&values[index], &junk) }
}

private func readMutable(_ root: inout Test_MainMutable, _ junk: inout Junk) {
    let i32 = root.i32
    let u32 = root.u32
    let flag = root.flag
    let mode = root.mode
    let tI32 = root.tI32
    let tS32 = root.tS32
    let tU32 = root.tU32
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
    junk.add(f32)
    for value in f32v { junk.add(value) }
    junk.add(f64)
    for value in f64v { junk.add(value) }

    readMutable(&root.object, &junk)
    readMutable(&root.objectv, &junk)

    let index = root.index
    for (key, value) in index {
        junk.add(junkHash(key))
        junk.add(UInt32(bitPattern: value))
    }

    readMutable(&root.objects, &junk)
    readMutable(&root.matrix, &junk)
    readMutable(&root.vector, &junk)
    readMutable(&root.arrays, &junk)
}

private func readPartly(_ root: inout Test_MainMutable) {
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
    _ = (i32, u32, i64, u64, flag, mode, str, data, f32, f64)
}

@inline(__always)
private func elapsedMS(since start: UInt64) -> Int {
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return Int((Double(elapsed) / 1_000_000).rounded())
}

private func benchRead(
    _ name: String,
    bytes: Int,
    loops: Int,
    _ body: (inout Junk) throws -> Void
) rethrows {
    var junk = Junk()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<loops { try body(&junk) }
    let ms = elapsedMS(since: start)
    print("\(name): \(bytes)B \(ms)ms \(String(format: "%016llx", junk.fuse()))")
}

private func benchWrite(
    _ name: String,
    loops: Int,
    _ body: () throws -> Int
) rethrows {
    var total = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<loops { total &+= try body() }
    let ms = elapsedMS(since: start)
    print("\(name): \(ms)ms \(String(total, radix: 16))")
}

private func benchCompression(
    _ name: String,
    raw: UnsafeRawBufferPointer,
    loops: Int
) throws {
    var compressed: [UInt8] = []
    let compressStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<loops {
        Compression.compress(raw, into: &compressed)
    }
    print("\(name)-compress: \(compressed.count)B \(elapsedMS(since: compressStart))ms")

    var restored: [UInt8] = []
    let decompressStart = DispatchTime.now().uptimeNanoseconds
    try compressed.withUnsafeBytes { input in
        for _ in 0..<loops {
            try Compression.decompress(input, into: &restored)
        }
    }
    guard restored.elementsEqual(raw) else {
        throw BenchError("\(name) decompression roundtrip mismatch")
    }
    print("\(name)-decompress: \(elapsedMS(since: decompressStart))ms")
}

private func run(_ config: BenchConfig) throws {
    let jsonURL = Bundle.module.url(
        forResource: "test",
        withExtension: "json",
        subdirectory: "Fixtures"
    ) ?? Bundle.module.url(forResource: "test", withExtension: "json")
    guard let jsonURL else { throw BenchError("missing Fixtures/test.json") }

    let json = try Data(contentsOf: jsonURL)
    let message = try Test_Main(jsonUTF8Data: json)
    let pbData = try message.serializedData()
    let pcBytes = try ProtoCache.serialize(message, as: Test_MainView.self)
    let fbURL = Bundle.module.url(
        forResource: "test-fb",
        withExtension: "bin",
        subdirectory: "Fixtures"
    ) ?? Bundle.module.url(forResource: "test-fb", withExtension: "bin")
    guard let fbURL else {
        throw BenchError(
            "missing Fixtures/test-fb.bin; generate it directly with flatc 25.12.19 as documented in Benchmarks/README.md"
        )
    }
    let fbData = try Data(contentsOf: fbURL)

    guard pbData.count == 574 else {
        throw BenchError("unexpected protobuf fixture size: \(pbData.count), expected 574")
    }
    guard pcBytes.count == 780 else {
        throw BenchError("unexpected protocache fixture size: \(pcBytes.count), expected 780")
    }
    guard fbData.count == 1296 else {
        throw BenchError("unexpected FlatBuffers fixture size: \(fbData.count), expected 1296")
    }

    var expected = Junk()
    pcBytes.withView(Test_MainView.self) { readPC($0, &expected) }
    let checksum = expected.fuse()

    var fbBuffer = ByteBuffer(data: fbData)
    let fbRoot: test_Main = getRoot(byteBuffer: &fbBuffer)
    var fbJunk = Junk()
    readFB(fbRoot, &fbJunk)
    guard fbJunk.fuse() == checksum else {
        throw BenchError(
            "FlatBuffers semantic checksum mismatch: "
                + String(format: "%016llx", fbJunk.fuse())
                + ", expected "
                + String(format: "%016llx", checksum)
        )
    }

    func validate(_ name: String, _ bytes: Bytes) throws {
        var junk = Junk()
        bytes.withView(Test_MainView.self) { readPC($0, &junk) }
        guard junk.fuse() == checksum else {
            throw BenchError(
                "\(name) semantic checksum mismatch: "
                    + String(format: "%016llx", junk.fuse())
                    + ", expected "
                    + String(format: "%016llx", checksum)
            )
        }
    }

    var full = Test_MainMutable(pcBytes)
    var fullJunk = Junk()
    readMutable(&full, &fullJunk)
    let fullBytes = try full.serialized()
    try validate("protocache-fully", fullBytes)

    var partial = Test_MainMutable(pcBytes)
    readPartly(&partial)
    let partialBytes = try partial.serialized()
    try validate("protocache-partly", partialBytes)

    if let output = ProcessInfo.processInfo.environment["PROTOCACHE_BENCH_OUTPUT"] {
        let data = pcBytes.withUnsafeBytes {
            Data(bytes: $0.baseAddress!, count: $0.count)
        }
        try data.write(to: URL(fileURLWithPath: output))
    }

    print("ProtoCache Swift benchmark (Rust-aligned common cases)")
    print(
        "loops=\(config.loops) protobuf=\(pbData.count)B "
            + "protocache=\(pcBytes.count)B flatbuffers=\(fbData.count)B"
    )
    print("ProtoCache readonly hashes borrowed UTF-8/bytes; stock Swift FlatBuffers accessors decode strings")
    print("ProtoCache serialize cases reuse public buffer output, matching C++/Rust")
    print("serialize total_size unit matches Rust: protobuf bytes, ProtoCache words")
    print("validated EX output: fully=\(fullBytes.count)B partly=\(partialBytes.count)B")

    if config.shouldRun("protobuf") {
        try benchRead("protobuf", bytes: pbData.count, loops: config.loops) { junk in
            let root = try Test_Main(serializedBytes: pbData)
            readPB(root, &junk)
        }
    }

    if config.shouldRun("protocache") {
        benchRead("protocache", bytes: pcBytes.count, loops: config.loops) { junk in
            pcBytes.withView(Test_MainView.self) { readPC($0, &junk) }
        }
    }

    if config.shouldRun("flatbuffers") {
        benchRead("flatbuffers", bytes: fbData.count, loops: config.loops) { junk in
            let root: test_Main = getRoot(byteBuffer: &fbBuffer)
            readFB(root, &junk)
        }
    }

    if config.shouldRun("protocache-ex") {
        benchRead("protocache-ex", bytes: pcBytes.count, loops: config.loops) { junk in
            var root = Test_MainMutable(pcBytes)
            readMutable(&root, &junk)
        }
    }

    let writeCases: Set<String> = [
        "protobuf-serialize",
        "protocache-serialize",
        "protocache-fully",
        "protocache-partly",
    ]
    if config.only == nil || config.only.map(writeCases.contains) == true {
        print("========serialize========")
    }

    if config.shouldRun("protobuf-serialize") {
        try benchWrite("protobuf-serialize", loops: config.loops) {
            try message.serializedData().count
        }
    }

    if config.shouldRun("protocache-serialize") {
        let buffer = SerializationBuffer()
        try benchWrite("protocache-serialize", loops: config.loops) {
            try ProtoCache.withSerializedSpan(
                message,
                using: buffer,
                as: Test_MainView.self
            ) { $0.count / 4 }
        }
    }

    if config.shouldRun("protocache-fully") {
        var root = Test_MainMutable(pcBytes)
        var junk = Junk()
        readMutable(&root, &junk)
        let buffer = SerializationBuffer()
        try benchWrite("protocache-fully", loops: config.loops) {
            try root.withSerializedSpan(using: buffer) { $0.count / 4 }
        }
    }

    if config.shouldRun("protocache-partly") {
        var root = Test_MainMutable(pcBytes)
        readPartly(&root)
        let buffer = SerializationBuffer()
        try benchWrite("protocache-partly", loops: config.loops) {
            try root.withSerializedSpan(using: buffer) { $0.count / 4 }
        }
    }

    let compressionCases: Set<String> = ["pb-compress", "pc-compress", "fb-compress"]
    if config.only == nil || config.only.map(compressionCases.contains) == true {
        print("========compress========")
    }

    if config.shouldRun("pb-compress") {
        let bytes = [UInt8](pbData)
        try bytes.withUnsafeBytes {
            try benchCompression("pb", raw: $0, loops: config.loops)
        }
    }

    if config.shouldRun("pc-compress") {
        try pcBytes.withUnsafeBytes {
            try benchCompression("pc", raw: $0, loops: config.loops)
        }
    }

    if config.shouldRun("fb-compress") {
        try fbData.withUnsafeBytes {
            try benchCompression("fb", raw: $0, loops: config.loops)
        }
    }
}

if let config = try BenchConfig.parse() {
    try run(config)
}
