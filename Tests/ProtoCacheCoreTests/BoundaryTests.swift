import Testing
@testable import ProtoCacheCore

private final class DeallocationCounter: @unchecked Sendable {
    var value = 0
}

@Test func adoptedStorageOwnsAllocationExactlyOnce() {
    let counter = DeallocationCounter()
    do {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 4)
        pointer.storeBytes(of: UInt32(1 << 8).littleEndian, as: UInt32.self)
        pointer.storeBytes(of: UInt32(77).littleEndian, toByteOffset: 4, as: UInt32.self)
        let bytes = Bytes(adopting: pointer, count: 8) { pointer, _ in
            counter.value += 1
            pointer.deallocate()
        }
        #expect(bytes.withBorrowedSpan { MessageView($0).scalar(0, as: Int32.self) } == 77)
        #expect(counter.value == 0)
    }
    #expect(counter.value == 1)
}

@Test func unsafeBorrowingKeepsTheOriginalAddressAndDoesNotCopy() {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 4)
    defer { pointer.deallocate() }
    pointer.storeBytes(of: UInt32(1 << 8).littleEndian, as: UInt32.self)
    pointer.storeBytes(of: UInt32(41).littleEndian, toByteOffset: 4, as: UInt32.self)
    let source = UnsafeRawBufferPointer(start: pointer, count: 8)
    let span = Span(unsafeBorrowing: source)
    let sameAddress = span.withUnsafeBytes { $0.baseAddress == UnsafeRawPointer(pointer) }
    #expect(sameAddress)
    #expect(MessageView(span).scalar(0, as: Int32.self) == 41)
    pointer.storeBytes(of: UInt32(42).littleEndian, toByteOffset: 4, as: UInt32.self)
    #expect(MessageView(span).scalar(0, as: Int32.self) == 42)
}

@Test func scopedReadonlyViewBorrowsBackingStorageWithoutCopy() {
    let counter = DeallocationCounter()
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 4)
    pointer.storeBytes(of: UInt32(1 << 8).littleEndian, as: UInt32.self)
    pointer.storeBytes(of: UInt32(7).littleEndian, toByteOffset: 4, as: UInt32.self)
    pointer.storeBytes(of: UInt32(0x6c65_6814).littleEndian, toByteOffset: 8, as: UInt32.self)
    pointer.storeBytes(of: UInt32(0x0000_6f6c).littleEndian, toByteOffset: 12, as: UInt32.self)

    do {
        let bytes = Bytes(adopting: pointer, count: 16) { pointer, _ in
            counter.value += 1
            pointer.deallocate()
        }
        bytes.withBorrowedSpan { span in
            let string = MessageView(span).string(0)
            let sameAddress = string.withUnsafeUTF8 { $0.baseAddress == UnsafeRawPointer(pointer).advanced(by: 9) }
            let matches = string.equalsUTF8("hello")
            #expect(sameAddress)
            #expect(matches)
        }
        #expect(counter.value == 0)
    }
    #expect(counter.value == 1)
}

@Test func compressionCallerBuffersReuseCapacity() throws {
    let expected = Array("aaaa".utf8) + [0, 0, 0, 0] + Array("bbbb".utf8)
    let source = Bytes(copying: expected)
    var packed = [UInt8](repeating: 0, count: 4096)
    let packedAddress = packed.withUnsafeBufferPointer { buffer in buffer.baseAddress }
    Compression.compress(source, into: &packed)
    #expect(packed.withUnsafeBufferPointer { buffer in buffer.baseAddress } == packedAddress)

    let packedBytes = Bytes(copying: packed)
    var raw = [UInt8](repeating: 0, count: 4096)
    let rawAddress = raw.withUnsafeBufferPointer { buffer in buffer.baseAddress }
    try Compression.decompress(packedBytes, into: &raw)
    #expect(raw.withUnsafeBufferPointer { buffer in buffer.baseAddress } == rawAddress)
    #expect(raw == expected)
}

@Test func malformedCompressionIsRejectedAndClearsCallerBuffer() {
    let malformed: [[UInt8]] = [
        [0x80],
        [4, 7],
        [4, 1],
        [1, 0x0f],
        [0xff, 0xff, 0xff, 0xff, 0xff, 1],
    ]
    for bytes in malformed {
        var output: [UInt8] = [1, 2, 3]
        #expect(throws: (any Error).self) {
            try Compression.decompress(Bytes(copying: bytes), into: &output)
        }
        #expect(output.isEmpty)
    }
}

@Test func perfectHashHandlesEmptySingletonAndDuplicateKeys() throws {
    let empty = try PerfectHash.build([])
    let emptyBytes = Bytes(copying: empty.index)
    #expect(emptyBytes.withBorrowedSpan { PerfectHashView($0).count } == 0)
    let singleton = try PerfectHash.build([[1, 2, 3]])
    let singletonBytes = Bytes(copying: singleton.index)
    let position = singletonBytes.withBorrowedSpan { span in
        let view = PerfectHashView(span)
        return [UInt8](arrayLiteral: 1, 2, 3).withUnsafeBytes { view.locate($0) }
    }
    #expect(position == 0)
    #expect(throws: ProtoCacheError.duplicateMapKey) {
        try PerfectHash.build([[9], [9]])
    }
}

@Test func mapExtentRejectsTruncatedPerfectHashIndex() {
    var header = UInt32.max.littleEndian
    let bytes = withUnsafeBytes(of: &header) { Bytes(copying: Array($0)) }
    #expect(throws: ProtoCacheError.self) {
        try bytes.withBorrowedSpan { try _ProtoCacheEncoding._detectMapBaseWords($0) }
    }
}
