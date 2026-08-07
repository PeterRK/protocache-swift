import Testing
@testable import ProtoCacheCore

@Test func readsInlineScalarAndString() {
    let words: [UInt32] = [
        (1 << 8) | (1 << 10),
        42,
        8,
    ]
    let bytes = words.withUnsafeBytes { ProtoCacheBytes(copying: $0) }
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
        #expect(ProtoCacheHash.hash128(Array(source.prefix(length))) == expected[length])
    }
}

@Test func compressionRoundTripAndLimits() throws {
    let source = Array([UInt8](repeating: 0, count: 8) + Array("abcd".utf8) + [0xff, 0xff, 1])
    let bytes = ProtoCacheBytes(copying: source)
    let packed = ProtoCacheCompression.compress(bytes)
    #expect(try ProtoCacheCompression.decompress(packed) == bytes)
    #expect(throws: ProtoCacheError.outputLimitExceeded) {
        try ProtoCacheCompression.decompress(packed, limits: .init(maximumOutputBytes: 2))
    }
}

@Test func perfectHashFindsEveryKey() throws {
    let keys = ["zero", "one", "two", "three"].map { Array($0.utf8) }
    let built = try PerfectHash.build(keys)
    let bytes = ProtoCacheBytes(copying: built.index)
    bytes.withBorrowedSpan { span in
        let view = PerfectHashView(span)
        #expect(Set(keys.map { $0.withUnsafeBytes { view.locate($0)! } }).count == keys.count)
    }
}

@Test func reverseEncodingMessageRoundTrip() throws {
    let buffer = _ProtoCacheBuffer()
    let checkpoint = buffer.checkpoint
    var fields = [_ProtoCacheUnit](repeating: .empty, count: 2)
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

@Test func reverseEncodingMapRoundTrip() throws {
    let buffer = _ProtoCacheBuffer()
    let checkpoint = buffer.checkpoint
    let names = ["alpha", "beta", "gamma", "delta"]
    var keyUnits: [_ProtoCacheUnit] = []
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

@Test func extendedMessageSectionsRoundTrip() throws {
    let buffer = _ProtoCacheBuffer()
    var fields = [_ProtoCacheUnit](repeating: .empty, count: 40)
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
