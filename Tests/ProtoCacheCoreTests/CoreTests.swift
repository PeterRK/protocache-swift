import Testing
@testable import ProtoCacheCore

@Test func readsInlineScalarAndString() {
    let words: [UInt32] = [
        (1 << 8) | (1 << 10),
        42,
        8,
    ]
    let bytes = words.withUnsafeBytes { Bytes(copying: $0) }
    bytes.withBorrowedSpan { span in
        let message = MessageView(span)
        #expect(message.scalar(0, as: Int32.self) == 42)
        let count = message.string(1).count
        #expect(count == 2)
    }
}

@Test func omittedFieldsUseCanonicalDefaults() {
    let view = MessageView(.empty)
    #expect(view.scalar(0, as: Int64.self) == 0)
    let stringIsEmpty = view.string(1).isEmpty
    let bytesAreEmpty = view.bytes(2).isEmpty
    let arrayIsEmpty = view.array(3, of: Int32.self).isEmpty
    #expect(stringIsEmpty)
    #expect(bytesAreEmpty)
    #expect(arrayIsEmpty)
    #expect(view.message(4).scalar(0, as: UInt32.self) == 0)
}

@Test func hashMatchesKnownPrefixVectors() {
    let expected: [(UInt32, UInt32, UInt32, UInt32)] = [
        (0x6bf50919, 0x232706fc, 0xb4e851c7, 0x8b72ee65),
        (0xd54ec67e, 0x50209687, 0x8df1cf6d, 0x62fe8510),
        (0x68f3fb4f, 0xfbe67d83, 0x706d5a5a, 0xb54a5a89),
    ]
    let source = Array("01".utf8)
    for length in 0...2 {
        #expect(Hash.hash128(Array(source.prefix(length))) == expected[length])
    }
}

@Test func hashMatchesCppForFullWidthPerfectHashSeeds() {
    let source = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
    let expected: [(UInt32, (UInt32, UInt32, UInt32, UInt32))] = [
        (0x0000_0000, (0x07c32f38, 0xb7c97db8, 0x0adef63d, 0x51072323)),
        (0x0000_0001, (0xe567ecee, 0x21b05c30, 0x6862909e, 0x74f0901a)),
        (0x7fff_ffff, (0x3860391a, 0xc1f8f90a, 0xc66f911e, 0x704c62e1)),
        (0x8000_0000, (0x0d9a5cf0, 0x711fb208, 0xbbb87a01, 0xe55fadb4)),
        (0xffff_ffff, (0xc7ebc1a2, 0xeeaa9231, 0x25fc3e60, 0x642a504d)),
    ]
    for (seed, hash) in expected {
        #expect(Hash.hash128(source, seed: UInt64(seed)) == hash)
    }
}

@Test func compressionRoundTripAndLimits() throws {
    let source = Array([UInt8](repeating: 0, count: 8) + Array("abcd".utf8) + [0xff, 0xff, 1])
    let bytes = Bytes(copying: source)
    let packed = Compression.compress(bytes)
    #expect(packed.withUnsafeBytes { Array($0) } == [
        0x0f, 0xbb, 0xd4, 0x61, 0x62, 0x63, 0x64, 0x01, 0x01,
    ])
    #expect(try Compression.decompress(packed) == bytes)
    #expect(throws: ProtoCacheError.outputLimitExceeded) {
        try Compression.decompress(packed, limits: .init(maximumOutputBytes: 2))
    }
}

@Test func perfectHashFindsEveryKey() throws {
    let keys = ["zero", "one", "two", "three"].map { Array($0.utf8) }
    for seed: UInt32 in [0, 1, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff] {
        let built = try PerfectHash.build(keys, initialSeed: seed)
        let rebuilt = try PerfectHash.build(keys, initialSeed: seed)
        #expect(rebuilt.index == built.index)
        #expect(rebuilt.positions == built.positions)
        let bytes = Bytes(copying: built.index)
        bytes.withBorrowedSpan { span in
            let view = PerfectHashView(span)
            #expect(Set(keys.map { $0.withUnsafeBytes { view.locate($0)! } }).count == keys.count)
        }
    }
}

@Test func reverseEncodingMessageRoundTrip() throws {
    let buffer = _ProtoCacheBuffer()
    let checkpoint = buffer.checkpoint
    var fields = [Unit](repeating: .empty, count: 2)
    fields[0] = _ProtoCacheEncoding.scalar(Int32(123))
    fields[1] = try _ProtoCacheEncoding.string("hello", in: buffer)
    let root = try _ProtoCacheEncoding.message(&fields, in: buffer, since: checkpoint)
    let bytes = try buffer.finish(root)
    bytes.withBorrowedSpan { span in
        let view = MessageView(span)
        #expect(view.scalar(0, as: Int32.self) == 123)
        let matches = view.string(1).equalsUTF8("hello")
        #expect(matches)
    }
}

@Test func reverseEncodingArrayRoundTrip() throws {
    let buffer = _ProtoCacheBuffer()
    let checkpoint = buffer.checkpoint
    let values = [1, 2, 3, 4].map { _ProtoCacheEncoding.scalar(Int32($0)) }
    let root = try _ProtoCacheEncoding.array(values, in: buffer, since: checkpoint)
    let bytes = try buffer.finish(root)
    bytes.withBorrowedSpan { span in
        let view = ArrayView<Int32>(span)
        var actual: [Int32] = []
        view.forEach { actual.append($0) }
        #expect(actual == [1, 2, 3, 4])
    }
}

@Test func boolArrayEncodingMatchesCanonicalByteArray() throws {
    let cases = [
        [Bool](),
        [true],
        [false, true, false],
        (0..<33).map { $0.isMultiple(of: 3) },
    ]
    for values in cases {
        let boolBuffer = _ProtoCacheBuffer()
        let boolRoot = try _ProtoCacheEncoding.boolArray(values, in: boolBuffer)
        let boolBytes = try boolBuffer.finish(boolRoot)

        let byteBuffer = _ProtoCacheBuffer()
        let raw = values.map { UInt8($0 ? 1 : 0) }
        let byteRoot = try _ProtoCacheEncoding.byteArray(raw, in: byteBuffer)
        #expect(boolBytes == (try byteBuffer.finish(byteRoot)))

        boolBytes.withBorrowedSpan { span in
            let view = BoolArrayView(StringView(span).rawBytes)
            var decoded: [Bool] = []
            view.forEach { decoded.append($0) }
            #expect(decoded == values)
        }
    }
}

@Test func mutableMapSupportsEagerOwnedMutationAndTraversal() {
    var map: MutableMap<String, Int32> = ["one": 1, "two": 2]
    map["three"] = 3
    map.forEachMutable { _, value in value += 10 }
    #expect(map.count == 3)
    #expect(map["one"] == 11)
    #expect(map["two"] == 12)
    #expect(map["three"] == 13)
    #expect(Set(map.map(\.key)) == ["one", "two", "three"])
    #expect(map.removeValue(forKey: "two") == 12)
    #expect(map["two"] == nil)
}

@Test func mutableMapPreservesValueSemanticsAndLargeMapTraversal() {
    let values = Dictionary(uniqueKeysWithValues: (0..<256).map { (Int32($0), Int32($0 * 2)) })
    let original = MutableMap(values)
    var copy = original
    copy.forEachMutable { key, value in value += key }
    copy.withValue(forKey: 300) { $0 = 900 }
    copy.withValue(forKey: 10) { $0 = nil }

    #expect(original.count == 256)
    #expect(original[10] == 20)
    #expect(original[255] == 510)
    #expect(original[300] == nil)
    #expect(copy.count == 256)
    #expect(copy[10] == nil)
    #expect(copy[255] == 765)
    #expect(copy[300] == 900)
}

@Test func reverseEncodingMapRoundTrip() throws {
    let buffer = _ProtoCacheBuffer()
    let checkpoint = buffer.checkpoint
    let names = ["alpha", "beta", "gamma", "delta"]
    var keyUnits: [Unit] = []
    for name in names { keyUnits.append(try _ProtoCacheEncoding.string(name, in: buffer)) }
    let valueUnits = [10, 20, 30, 40].map { _ProtoCacheEncoding.scalar(Int32($0)) }
    let root = try _ProtoCacheEncoding.map(
        keys: names.map { Array($0.utf8) },
        keyUnits: keyUnits,
        valueUnits: valueUnits,
        in: buffer,
        since: checkpoint
    )
    let bytes = try buffer.finish(root)
    bytes.withBorrowedSpan { span in
        let view = MapView<StringView, Int32>(span)
        #expect(view.position(for: "alpha").map { view.value(at: $0) } == 10)
        #expect(view.position(for: "gamma").map { view.value(at: $0) } == 30)
        #expect(view.position(for: "missing") == nil)
    }
}

@Test func mapEncodingCoversSmallScratchCutoff() throws {
    for count in [16, 17] {
        let buffer = _ProtoCacheBuffer()
        let checkpoint = buffer.checkpoint
        var entries: [_ProtoCacheMapEntry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            let key = "key-\(index)"
            entries.append(.init(
                key: Array(key.utf8),
                keyUnit: try _ProtoCacheEncoding.string(key, in: buffer),
                valueUnit: _ProtoCacheEncoding.scalar(Int32(index))
            ))
        }
        let root = try _ProtoCacheEncoding.map(&entries, in: buffer, since: checkpoint)
        let bytes = try buffer.finish(root)
        bytes.withBorrowedSpan { span in
            let view = MapView<StringView, Int32>(span)
            #expect(view.count == count)
            for index in 0..<count {
                #expect(view.position(for: "key-\(index)").map { view.value(at: $0) } == Int32(index))
            }
        }
    }
}

@Test func mapEncodingRemainsValidAcrossInputOrdersAndRandomSeeds() throws {
    let values = ["alpha": Int32(10), "beta": 20, "gamma": 30, "delta": 40]
    func encode(_ names: [String]) throws -> Bytes {
        let buffer = _ProtoCacheBuffer()
        let checkpoint = buffer.checkpoint
        var entries: [_ProtoCacheMapEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            entries.append(.init(
                key: Array(name.utf8),
                keyUnit: try _ProtoCacheEncoding.string(name, in: buffer),
                valueUnit: _ProtoCacheEncoding.scalar(values[name]!)
            ))
        }
        let root = try _ProtoCacheEncoding.map(&entries, in: buffer, since: checkpoint)
        return try buffer.finish(root)
    }
    let names = ["alpha", "beta", "gamma", "delta"]
    for bytes in try [encode(names), encode(Array(names.reversed()))] {
        bytes.withBorrowedSpan { span in
            let view = MapView<StringView, Int32>(span)
            #expect(view.count == values.count)
            for (key, value) in values {
                #expect(view.position(for: key).map { view.value(at: $0) } == value)
            }
        }
    }
}

@Test func compactionMaterializesWideInlineUnitsAndBoundsScratchStorage() throws {
    let arrayValues = (0..<95).map { "v\($0 % 10)" } + ["wide"]
    let arrayBuffer = _ProtoCacheBuffer()
    let arrayCheckpoint = arrayBuffer.checkpoint
    var arrayUnits: [Unit] = []
    arrayUnits.reserveCapacity(arrayValues.count)
    for value in arrayValues {
        var unit = try _ProtoCacheEncoding.string(value, in: arrayBuffer)
        _ProtoCacheEncoding.fold(&unit, in: arrayBuffer)
        arrayUnits.append(unit)
    }
    let arrayRoot = try _ProtoCacheEncoding.array(
        &arrayUnits, in: arrayBuffer, since: arrayCheckpoint
    )
    let arrayBytes = try arrayBuffer.finish(arrayRoot)
    arrayBytes.withBorrowedSpan { span in
        let view = ArrayView<StringView>(span)
        #expect(view.count == arrayValues.count)
        for index in arrayValues.indices {
            let matches = view[index].equalsUTF8(arrayValues[index])
            #expect(matches)
        }
    }

    let names = (0..<39).map { "k\($0)" } + ["wide"]
    let mapBuffer = _ProtoCacheBuffer()
    let mapCheckpoint = mapBuffer.checkpoint
    var entries: [_ProtoCacheMapEntry] = []
    entries.reserveCapacity(names.count)
    for (index, name) in names.enumerated() {
        var key = try _ProtoCacheEncoding.string(name, in: mapBuffer)
        _ProtoCacheEncoding.fold(&key, in: mapBuffer)
        entries.append(.init(
            key: Array(name.utf8),
            keyUnit: key,
            valueUnit: _ProtoCacheEncoding.scalar(Int32(index))
        ))
    }
    let mapRoot = try _ProtoCacheEncoding.map(&entries, in: mapBuffer, since: mapCheckpoint)
    let mapBytes = try mapBuffer.finish(mapRoot)
    mapBytes.withBorrowedSpan { span in
        let view = MapView<StringView, Int32>(span)
        for (index, name) in names.enumerated() {
            #expect(view.position(for: name).map { view.value(at: $0) } == Int32(index))
        }
    }
}

@Test func extendedMessageSectionsRoundTrip() throws {
    let buffer = _ProtoCacheBuffer()
    var fields = [Unit](repeating: .empty, count: 40)
    fields[0] = _ProtoCacheEncoding.scalar(UInt32(1))
    fields[12] = _ProtoCacheEncoding.scalar(UInt64(12))
    fields[39] = _ProtoCacheEncoding.scalar(Int32(39))
    let root = try _ProtoCacheEncoding.message(&fields, in: buffer, since: 0)
    let bytes = try buffer.finish(root)
    bytes.withBorrowedSpan { span in
        let view = MessageView(span)
        #expect(view.scalar(0, as: UInt32.self) == 1)
        #expect(view.scalar(12, as: UInt64.self) == 12)
        #expect(view.scalar(39, as: Int32.self) == 39)
    }
}
