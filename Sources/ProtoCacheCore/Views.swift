@inlinable @inline(__always)
func protoCacheCount32(_ input: UInt32) -> Int {
    var value = (input & 0x3333_3333) &+ ((input >> 2) & 0x3333_3333)
    value = value &+ (value >> 4)
    value = (value & 0x0f0f_0f0f) &+ ((value >> 8) & 0x0f0f_0f0f)
    value = value &+ (value >> 16)
    return Int(value & 0xff)
}

@inlinable @inline(__always)
func protoCacheCount64(_ input: UInt64) -> Int {
    var value = (input & 0x3333_3333_3333_3333) &+ ((input >> 2) & 0x3333_3333_3333_3333)
    value = value &+ (value >> 4)
    value = (value & 0x0f0f_0f0f_0f0f_0f0f) &+ ((value >> 8) & 0x0f0f_0f0f_0f0f_0f0f)
    value = value &+ (value >> 16)
    value = value &+ (value >> 32)
    return Int(value & 0xff)
}

@inlinable @inline(__always)
func _protoCacheObjectBytes(
    fromRawWords baseAddress: UnsafeRawPointer,
    availableByteCount: Int,
    width: Int,
    owner: borrowing ProtoCacheBytes
) -> ProtoCacheBytes? {
    guard width > 0, availableByteCount >= width * 4 else { return nil }
    let ownerOffset = owner.rawBaseAddress.distance(to: baseAddress)
    guard ownerOffset >= 0, ownerOffset + availableByteCount <= owner.count else { return nil }
    let first = UInt32(littleEndian: baseAddress.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
    let objectOffset = first & 3 == 3 ? Int(first >> 2) * 4 : 0
    guard objectOffset < availableByteCount else { return nil }
    return owner.slice(
        byteOffset: ownerOffset + objectOffset,
        count: availableByteCount - objectOffset
    )
}

public struct FieldView: @unchecked Sendable {
    let tail: ProtoCacheBytes
    public let width: Int

    init(tail: ProtoCacheBytes, width: Int) {
        self.tail = tail
        self.width = width
    }

    public var rawBytes: ProtoCacheBytes { tail.wordSlice(offset: 0, count: width) }

    public var objectBytes: ProtoCacheBytes {
        let first = tail.loadUInt32(wordOffset: 0)
        if first & 3 == 3 {
            return tail.wordSlice(offset: Int(first >> 2))
        }
        return tail
    }

    public func scalar<T: ProtoCacheScalar>(_ type: T.Type = T.self) -> T? {
        T._decodeProtoCache(from: self)
    }

    public func string() -> StringView { StringView(objectBytes) }
    public func bytes() -> BytesView { BytesView(string()) }
    public func message() -> MessageView { MessageView(objectBytes) }
    public func array<Element: ProtoCacheDecodable>(of type: Element.Type = Element.self) -> ArrayView<Element> {
        ArrayView(objectBytes)
    }
    public func map<Key: ProtoCacheMapKey, Value: ProtoCacheDecodable>(key: Key.Type = Key.self, value: Value.Type = Value.self) -> MapView<Key, Value> {
        MapView(objectBytes)
    }
}

public struct MessageView: @unchecked Sendable {
    public let bytes: ProtoCacheBytes
    @usableFromInline let head: UInt32
    @usableFromInline let sectionCount: Int
    @usableFromInline let bodyWordOffset: Int

    @inlinable public init(_ bytes: ProtoCacheBytes) {
        let actual = bytes.count >= 4 ? bytes : .empty
        self.bytes = actual
        head = actual.loadUInt32(wordOffset: 0)
        sectionCount = Int(head & 0xff)
        bodyWordOffset = 1 + sectionCount * 2
        assert(bodyWordOffset * 4 <= actual.count)
    }

    public func hasField(_ id: Int) -> Bool { field(id) != nil }

    @inlinable @inline(__always)
    func fieldLocation(_ id: Int) -> (start: Int, width: Int)? {
        precondition(id >= 0 && id <= 6386)
        let width: Int
        let offset: Int
        if id < 12 {
            var vector = head >> 8
            width = Int((vector >> UInt32(id * 2)) & 3)
            guard width != 0 else { return nil }
            if id == 0 {
                vector = 0
            } else {
                vector &= (UInt32(1) << UInt32(id * 2)) - 1
            }
            offset = protoCacheCount32(vector)
        } else {
            let section = (id - 12) / 25
            let bit = (id - 12) % 25
            guard section < sectionCount else { return nil }
            let vector = bytes.loadUInt64(wordOffset: 1 + section * 2)
            width = Int((vector >> UInt64(bit * 2)) & 3)
            guard width != 0 else { return nil }
            let mask: UInt64 = bit == 0 ? 0 : (UInt64(1) << UInt64(bit * 2)) - 1
            offset = protoCacheCount64(vector & mask) + Int(vector >> 50)
        }
        let start = bodyWordOffset + offset
        assert((start + width) * 4 <= bytes.count)
        return (start, width)
    }

    public func field(_ id: Int) -> FieldView? {
        guard let location = fieldLocation(id) else { return nil }
        return FieldView(tail: bytes.wordSlice(offset: location.start), width: location.width)
    }

    @inlinable @inline(__always)
    func objectBytes(_ id: Int) -> ProtoCacheBytes? {
        guard let location = fieldLocation(id) else { return nil }
        let first = bytes.loadUInt32(wordOffset: location.start)
        let objectStart = first & 3 == 3 ? location.start + Int(first >> 2) : location.start
        return bytes.wordSlice(offset: objectStart)
    }

    @inlinable @inline(__always)
    public func scalar<T: ProtoCacheScalar>(_ id: Int, as type: T.Type = T.self) -> T {
        guard let location = fieldLocation(id), location.width == T._protoCacheWordWidth else {
            return T._protoCacheDefault
        }
        let word0 = bytes.loadUInt32(wordOffset: location.start)
        let word1 = location.width == 2 ? bytes.loadUInt32(wordOffset: location.start + 1) : 0
        return T._decodeProtoCache(word0: word0, word1: word1)
    }

    @inlinable public func string(_ id: Int) -> StringView { objectBytes(id).map(StringView.init) ?? .empty }
    @inlinable public func bytes(_ id: Int) -> BytesView { BytesView(string(id)) }
    @inlinable public func message(_ id: Int) -> MessageView { MessageView(objectBytes(id) ?? .empty) }
    @inlinable public func array<Element: ProtoCacheDecodable>(_ id: Int, of type: Element.Type = Element.self) -> ArrayView<Element> {
        objectBytes(id).map(ArrayView<Element>.init) ?? .empty
    }
    @inlinable public func map<Key: ProtoCacheMapKey, Value: ProtoCacheDecodable>(_ id: Int, key: Key.Type = Key.self, value: Value.Type = Value.self) -> MapView<Key, Value> {
        objectBytes(id).map(MapView<Key, Value>.init) ?? .empty
    }
}

public struct BytesView: RandomAccessCollection, @unchecked Sendable {
    public typealias Index = Int
    public typealias Element = UInt8
    @usableFromInline let bytes: ProtoCacheBytes
    let payloadOffset: Int
    public let count: Int

    @usableFromInline init(_ string: StringView) {
        bytes = string.bytes
        payloadOffset = string.payloadOffset
        count = string.count
    }

    init(bytes: ProtoCacheBytes, payloadOffset: Int, count: Int) {
        self.bytes = bytes
        self.payloadOffset = payloadOffset
        self.count = count
    }

    public static let empty = BytesView(bytes: .empty, payloadOffset: 1, count: 0)
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(position: Int) -> UInt8 {
        precondition(position >= 0 && position < count)
        return bytes.loadUInt8(at: payloadOffset + position)
    }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: bytes.rawBaseAddress.advanced(by: payloadOffset), count: count))
    }
}

extension BytesView: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBytes { l in rhs.withUnsafeBytes { r in l.elementsEqual(r) } }
    }
}

public struct StringView: RandomAccessCollection, @unchecked Sendable {
    public typealias Index = Int
    public typealias Element = UInt8
    @usableFromInline let bytes: ProtoCacheBytes
    let payloadOffset: Int
    public let count: Int

    public init(_ encoded: ProtoCacheBytes) {
        var mark = 0
        var shift = 0
        var used = 0
        while shift < 35 {
            let byte = encoded.loadUInt8(at: used)
            used += 1
            mark |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        assert(mark & 3 == 0)
        let length = mark >> 2
        assert(used + length <= encoded.count)
        bytes = encoded
        payloadOffset = used
        count = length
    }

    public static let empty = StringView(.empty)
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(position: Int) -> UInt8 {
        precondition(position >= 0 && position < count)
        return bytes.loadUInt8(at: payloadOffset + position)
    }
    public var rawBytes: BytesView { BytesView(bytes: bytes, payloadOffset: payloadOffset, count: count) }
    public func withUnsafeUTF8<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try rawBytes.withUnsafeBytes(body)
    }
    public func equalsUTF8(_ value: String) -> Bool {
        guard value.utf8.count == count else { return false }
        return value.utf8.withContiguousStorageIfAvailable { source in
            withUnsafeUTF8 { encoded in
                UnsafeRawBufferPointer(source).elementsEqual(encoded)
            }
        } ?? Array(value.utf8).withUnsafeBytes { source in
            withUnsafeUTF8 { source.elementsEqual($0) }
        }
    }
}

extension StringView: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawBytes == rhs.rawBytes }
}
extension StringView: Hashable {
    public func hash(into hasher: inout Hasher) {
        withUnsafeUTF8 { hasher.combine(bytes: $0) }
    }
}
extension StringView: ProtoCacheDecodable {
    public static func _decodeProtoCache(from field: FieldView) -> StringView? { field.string() }
    public static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing ProtoCacheBytes
    ) -> StringView? {
        _protoCacheObjectBytes(
            fromRawWords: baseAddress,
            availableByteCount: availableByteCount,
            width: width,
            owner: owner
        ).map(StringView.init)
    }
}
extension StringView: ProtoCacheMapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try withUnsafeUTF8(body)
    }
}

public struct BoolArrayView: RandomAccessCollection, @unchecked Sendable {
    public typealias Index = Int
    private let bytes: BytesView
    public init(_ bytes: BytesView) { self.bytes = bytes }
    public static let empty = BoolArrayView(.empty)
    public var startIndex: Int { 0 }
    public var endIndex: Int { bytes.count }
    public subscript(position: Int) -> Bool { bytes[position] != 0 }
}

public struct ArrayView<Element: ProtoCacheDecodable>: RandomAccessCollection, @unchecked Sendable {
    public typealias Index = Int
    @usableFromInline let bytes: ProtoCacheBytes
    @usableFromInline let bodyWordOffset: Int
    @usableFromInline let width: Int
    public let count: Int

    @inlinable public init(_ bytes: ProtoCacheBytes) {
        let head = bytes.loadUInt32(wordOffset: 0)
        let parsedWidth = Int(head & 3)
        if parsedWidth == 0 {
            count = 0; width = 1
        } else {
            count = Int(head >> 2); width = parsedWidth
        }
        bodyWordOffset = 1
        self.bytes = bytes
        assert((1 + count * width) * 4 <= bytes.count)
    }

    private init(empty: Void) {
        bytes = .empty
        bodyWordOffset = 1
        width = 1
        count = 0
    }
    public static var empty: Self { Self(empty: ()) }
    @inlinable public var _protoCacheBytes: ProtoCacheBytes { bytes }
    @inlinable public var startIndex: Int { 0 }
    @inlinable public var endIndex: Int { count }
    @inlinable @inline(__always)
    public subscript(position: Int) -> Element {
        precondition(position >= 0 && position < count)
        let start = bodyWordOffset + position * width
        let byteOffset = start * 4
        return Element._decodeProtoCache(
            fromRawWords: bytes.rawBaseAddress.advanced(by: byteOffset),
            availableByteCount: bytes.count - byteOffset,
            width: width,
            owner: bytes
        )!
    }
}

public struct MapEntryView<Key: ProtoCacheMapKey, Value: ProtoCacheDecodable>: Sendable {
    public let key: Key
    public let value: Value
    @inlinable public init(key: Key, value: Value) { self.key = key; self.value = value }
}

public struct MapView<Key: ProtoCacheMapKey, Value: ProtoCacheDecodable>: RandomAccessCollection, @unchecked Sendable {
    public typealias Index = Int
    public typealias Element = MapEntryView<Key, Value>
    @usableFromInline let bytes: ProtoCacheBytes
    @usableFromInline let index: PerfectHashView
    @usableFromInline let bodyWordOffset: Int
    @usableFromInline let keyWidth: Int
    @usableFromInline let valueWidth: Int

    public init(_ bytes: ProtoCacheBytes) {
        self.bytes = bytes
        let parsedKeyWidth = Int((bytes.loadUInt32(wordOffset: 0) >> 30) & 3)
        let parsedValueWidth = Int((bytes.loadUInt32(wordOffset: 0) >> 28) & 3)
        if parsedKeyWidth == 0 || parsedValueWidth == 0 {
            keyWidth = 1; valueWidth = 1; index = .empty; bodyWordOffset = 1
        } else {
            keyWidth = parsedKeyWidth; valueWidth = parsedValueWidth
            index = PerfectHashView(bytes); bodyWordOffset = (index.byteCount + 3) / 4
        }
        assert((bodyWordOffset + (keyWidth + valueWidth) * index.count) * 4 <= bytes.count)
    }

    private init(empty: Void) {
        bytes = .empty
        keyWidth = 1
        valueWidth = 1
        index = .empty
        bodyWordOffset = 1
    }
    public static var empty: Self { Self(empty: ()) }
    @inlinable public var _protoCacheBytes: ProtoCacheBytes { bytes }
    @inlinable public var startIndex: Int { 0 }
    @inlinable public var endIndex: Int { index.count }
    @inlinable public var count: Int { index.count }

    @inlinable @inline(__always)
    public subscript(position: Int) -> Element {
        precondition(position >= 0 && position < count)
        return Element(
            key: decode(Key.self, position: position, value: false)!,
            value: decode(Value.self, position: position, value: true)!
        )
    }

    public subscript(key: Key) -> Value? {
        let position = key._withProtoCacheKeyBytes { index.locate($0) }
        guard let position, position < count,
              decode(Key.self, position: position, value: false) == key else { return nil }
        return decode(Value.self, position: position, value: true)
    }

    @inlinable @inline(__always)
    func decode<T: ProtoCacheDecodable>(
        _ type: T.Type,
        position: Int,
        value: Bool
    ) -> T? {
        let pairWidth = keyWidth + valueWidth
        let width = value ? valueWidth : keyWidth
        let start = bodyWordOffset + position * pairWidth + (value ? keyWidth : 0)
        let byteOffset = start * 4
        return T._decodeProtoCache(
            fromRawWords: bytes.rawBaseAddress.advanced(by: byteOffset),
            availableByteCount: bytes.count - byteOffset,
            width: width,
            owner: bytes
        )
    }

}

extension MapView where Key == StringView {
    public subscript(key: String) -> Value? {
        let position = key.utf8.withContiguousStorageIfAvailable { storage in
            index.locate(UnsafeRawBufferPointer(storage))
        } ?? Array(key.utf8).withUnsafeBytes { index.locate($0) }
        guard let position, position < count,
              let stored = decode(StringView.self, position: position, value: false),
              stored.equalsUTF8(key) else { return nil }
        return decode(Value.self, position: position, value: true)
    }
}

extension BytesView: ProtoCacheDecodable {
    public static func _decodeProtoCache(from field: FieldView) -> BytesView? { field.bytes() }
    public static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing ProtoCacheBytes
    ) -> BytesView? {
        StringView._decodeProtoCache(
            fromRawWords: baseAddress,
            availableByteCount: availableByteCount,
            width: width,
            owner: owner
        ).map(BytesView.init)
    }
}
