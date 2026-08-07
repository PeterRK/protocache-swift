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
@_lifetime(copy owner)
public func _protoCacheObjectBytes(
    fromRawWords baseAddress: UnsafeRawPointer,
    availableByteCount: Int,
    width: Int,
    owner: borrowing Span
) -> Span? {
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

public struct FieldView: ~Escapable, Copyable, @unchecked Sendable {
    let tail: Span
    public let width: Int

    @_lifetime(copy tail)
    init(tail: Span, width: Int) {
        self.tail = tail
        self.width = width
    }

    public var rawBytes: Span {
        @_lifetime(copy self)
        borrowing get { tail.wordSlice(offset: 0, count: width) }
    }

    public var objectBytes: Span {
        @_lifetime(copy self)
        borrowing get {
            let first = tail.loadUInt32(wordOffset: 0)
            if first & 3 == 3 {
                return tail.wordSlice(offset: Int(first >> 2))
            }
            return tail
        }
    }

    public func scalar<T: Scalar>(_ type: T.Type = T.self) -> T? {
        T._decodeProtoCache(from: self)
    }

    @_lifetime(copy self)
    public func string() -> StringView { StringView(objectBytes) }
    @_lifetime(copy self)
    public func bytes() -> BytesView { BytesView(string()) }
    @_lifetime(copy self)
    public func message() -> MessageView { MessageView(objectBytes) }
    @_lifetime(copy self)
    public func array<Element: FieldDecodable>(of type: Element.Type = Element.self) -> ArrayView<Element>
    where Element: ~Escapable {
        ArrayView(objectBytes)
    }
    @_lifetime(copy self)
    public func map<Key: MapKey, Value: FieldDecodable>(key: Key.Type = Key.self, value: Value.Type = Value.self) -> MapView<Key, Value>
    where Key: ~Escapable, Value: ~Escapable {
        MapView(objectBytes)
    }
}

public struct MessageView: ~Escapable, Copyable, @unchecked Sendable {
    public let bytes: Span
    @usableFromInline let head: UInt32
    @usableFromInline let bodyWordOffset: UInt32

    @_lifetime(copy bytes)
    @inlinable public init(_ bytes: Span) {
        guard bytes.count >= 4 else {
            self.bytes = .empty
            head = 0
            bodyWordOffset = 1
            return
        }
        self.bytes = bytes
        head = bytes.loadUInt32(wordOffset: 0)
        bodyWordOffset = 1 + (head & 0xff) * 2
        assert(Int(bodyWordOffset) * 4 <= bytes.count)
    }

    @inlinable @inline(__always)
    public func hasField(_ id: Int) -> Bool { fieldLocation(id) != nil }

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
            guard section < Int(head & 0xff) else { return nil }
            let vector = bytes.loadUInt64(wordOffset: 1 + section * 2)
            width = Int((vector >> UInt64(bit * 2)) & 3)
            guard width != 0 else { return nil }
            let mask: UInt64 = bit == 0 ? 0 : (UInt64(1) << UInt64(bit * 2)) - 1
            offset = protoCacheCount64(vector & mask) + Int(vector >> 50)
        }
        let start = Int(bodyWordOffset) + offset
        assert((start + width) * 4 <= bytes.count)
        return (start, width)
    }

    @_lifetime(copy self)
    public func field(_ id: Int) -> FieldView? {
        guard let location = fieldLocation(id) else { return nil }
        return FieldView(tail: bytes.wordSlice(offset: location.start), width: location.width)
    }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    func objectBytes(_ id: Int) -> Span? {
        guard let location = fieldLocation(id) else { return nil }
        let first = bytes.loadUInt32(wordOffset: location.start)
        let objectStart = first & 3 == 3 ? location.start + Int(first >> 2) : location.start
        return bytes.wordSlice(offset: objectStart)
    }

    @inlinable @inline(__always)
    public func scalar<T: Scalar>(_ id: Int, as type: T.Type = T.self) -> T {
        guard let location = fieldLocation(id), location.width == T._protoCacheWordWidth else {
            return T._protoCacheDefault
        }
        let word0 = bytes.loadUInt32(wordOffset: location.start)
        let word1 = location.width == 2 ? bytes.loadUInt32(wordOffset: location.start + 1) : 0
        return T._decodeProtoCache(word0: word0, word1: word1)
    }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    public func string(_ id: Int) -> StringView {
        guard let bytes = objectBytes(id) else { return .empty }
        return StringView(bytes)
    }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    public func bytes(_ id: Int) -> BytesView { BytesView(string(id)) }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    public func message(_ id: Int) -> MessageView {
        guard let bytes = objectBytes(id) else { return MessageView(.empty) }
        return MessageView(bytes)
    }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    public func array<Element: FieldDecodable>(_ id: Int, of type: Element.Type = Element.self) -> ArrayView<Element>
    where Element: ~Escapable {
        guard let bytes = objectBytes(id) else { return .empty }
        return ArrayView<Element>(bytes)
    }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    public func map<Key: MapKey, Value: FieldDecodable>(_ id: Int, key: Key.Type = Key.self, value: Value.Type = Value.self) -> MapView<Key, Value>
    where Key: ~Escapable, Value: ~Escapable {
        guard let bytes = objectBytes(id) else { return .empty }
        return MapView<Key, Value>(bytes)
    }
}

public struct BytesView: ~Escapable, Copyable, @unchecked Sendable {
    @usableFromInline let bytes: Span
    @usableFromInline let payloadOffset: Int
    public let count: Int

    @_lifetime(copy string)
    @usableFromInline init(_ string: StringView) {
        bytes = string.bytes
        payloadOffset = string.payloadOffset
        count = string.count
    }

    @_lifetime(copy bytes)
    @usableFromInline init(bytes: Span, payloadOffset: Int, count: Int) {
        self.bytes = bytes
        self.payloadOffset = payloadOffset
        self.count = count
    }

    @inlinable public static var empty: BytesView {
        @_lifetime(immortal)
        get { BytesView(bytes: .empty, payloadOffset: 0, count: 0) }
    }
    @inlinable public var isEmpty: Bool { count == 0 }

    @inlinable @inline(__always)
    public subscript(position: Int) -> UInt8 {
        precondition(position >= 0 && position < count)
        return bytes.loadUInt8(at: payloadOffset + position)
    }

    @inlinable
    public func forEach(_ body: (UInt8) throws -> Void) rethrows {
        var index = 0
        while index < count {
            try body(self[index])
            index += 1
        }
    }

    @inlinable @inline(__always)
    public func withUnsafeBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
        try bytes.withUnsafeBytes { source in
            try body(UnsafeRawBufferPointer(
                start: source.baseAddress?.advanced(by: payloadOffset),
                count: count
            ))
        }
    }

    public func elementsEqual(_ other: borrowing BytesView) -> Bool {
        guard count == other.count else { return false }
        return withUnsafeBytes { left in
            other.withUnsafeBytes { right in left.elementsEqual(right) }
        }
    }
}

public struct StringView: ~Escapable, Copyable, @unchecked Sendable {
    @usableFromInline let bytes: Span
    @usableFromInline let payloadOffset: Int
    public let count: Int

    @_lifetime(copy encoded)
    @inlinable @inline(__always)
    public init(_ encoded: Span) {
        guard !encoded.isEmpty else {
            bytes = .empty
            payloadOffset = 0
            count = 0
            return
        }
        var mark = 0
        var shift = 0
        var used = 0
        while shift < 35, used < encoded.count {
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

    @inlinable public static var empty: StringView {
        @_lifetime(immortal)
        get { StringView(.empty) }
    }
    @inlinable public var isEmpty: Bool { count == 0 }

    @inlinable @inline(__always)
    public subscript(position: Int) -> UInt8 {
        precondition(position >= 0 && position < count)
        return bytes.loadUInt8(at: payloadOffset + position)
    }

    public var rawBytes: BytesView {
        @_lifetime(copy self)
        borrowing get { BytesView(bytes: bytes, payloadOffset: payloadOffset, count: count) }
    }

    @inlinable
    public func forEach(_ body: (UInt8) throws -> Void) rethrows {
        try rawBytes.forEach(body)
    }

    @inlinable @inline(__always)
    public func withUnsafeUTF8<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
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

    public func elementsEqual(_ other: borrowing StringView) -> Bool {
        rawBytes.elementsEqual(other.rawBytes)
    }
}

extension StringView: FieldDecodable {
    @_lifetime(copy field)
    @inlinable @inline(__always)
    public static func _decodeProtoCache(from field: FieldView) -> StringView? { field.string() }

    @_lifetime(copy owner)
    @inlinable @inline(__always)
    public static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing Span
    ) -> StringView? {
        guard let bytes = _protoCacheObjectBytes(
            fromRawWords: baseAddress,
            availableByteCount: availableByteCount,
            width: width,
            owner: owner
        ) else { return nil }
        return StringView(bytes)
    }
}
extension StringView: MapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try withUnsafeUTF8(body)
    }

    @inlinable @inline(__always)
    public func _protoCacheEquals(_ other: borrowing StringView) -> Bool {
        elementsEqual(other)
    }
}

public struct BoolArrayView: ~Escapable, Copyable, @unchecked Sendable {
    @usableFromInline let bytes: BytesView

    @_lifetime(copy bytes)
    public init(_ bytes: BytesView) { self.bytes = bytes }

    public static var empty: BoolArrayView {
        @_lifetime(immortal)
        get { BoolArrayView(.empty) }
    }
    public var count: Int { bytes.count }
    public var isEmpty: Bool { bytes.isEmpty }
    public subscript(position: Int) -> Bool { bytes[position] != 0 }

    @inlinable
    public func forEach(_ body: (Bool) throws -> Void) rethrows {
        try bytes.forEach { try body($0 != 0) }
    }
}

public struct ArrayView<Element: FieldDecodable>: ~Escapable, Copyable, @unchecked Sendable
where Element: ~Escapable {
    @usableFromInline let bytes: Span
    @usableFromInline let head: UInt32

    @_lifetime(copy bytes)
    @inlinable public init(_ bytes: Span) {
        guard bytes.count >= 4 else {
            self.bytes = .empty
            head = 0
            return
        }
        let parsedHead = bytes.loadUInt32(wordOffset: 0)
        let parsedWidth = Int(parsedHead & 3)
        if parsedWidth == 0 {
            head = 0
        } else {
            head = parsedHead
        }
        self.bytes = bytes
        assert((1 + count * width) * 4 <= bytes.count)
    }

    @inlinable public static var empty: Self {
        @_lifetime(immortal)
        get { Self(.empty) }
    }

    public var _protoCacheSpan: Span {
        @_lifetime(copy self)
        borrowing get { bytes }
    }
    @inlinable public var count: Int { Int(head >> 2) }
    @inlinable public var isEmpty: Bool { count == 0 }
    @inlinable @inline(__always) var width: Int { Swift.max(1, Int(head & 3)) }

    @inlinable @inline(__always)
    public subscript(position: Int) -> Element {
        @_lifetime(copy self)
        borrowing get {
            precondition(position >= 0 && position < count)
            let start = 1 + position * width
            let byteOffset = start * 4
            return Element._decodeProtoCache(
                fromRawWords: bytes.rawBaseAddress.advanced(by: byteOffset),
                availableByteCount: bytes.count - byteOffset,
                width: width,
                owner: bytes
            )!
        }
    }

    @inlinable
    public func forEach(_ body: (borrowing Element) throws -> Void) rethrows {
        let elementCount = Int(head >> 2)
        let elementWidth = Swift.max(1, Int(head & 3))
        let byteStride = elementWidth &* 4
        var byteOffset = 4
        var index = 0
        while index < elementCount {
            let element = Element._decodeProtoCache(
                fromRawWords: bytes.rawBaseAddress.advanced(by: byteOffset),
                availableByteCount: bytes.count - byteOffset,
                width: elementWidth,
                owner: bytes
            )!
            try body(element)
            byteOffset &+= byteStride
            index &+= 1
        }
    }
}

public struct MapView<Key: MapKey, Value: FieldDecodable>: ~Escapable, Copyable, @unchecked Sendable
where Key: ~Escapable, Value: ~Escapable {
    @usableFromInline let bytes: Span
    @usableFromInline let indexByteCount: Int

    @_lifetime(copy bytes)
    public init(_ bytes: Span) {
        guard bytes.count >= 4 else {
            self.bytes = .empty
            indexByteCount = 4
            return
        }
        self.bytes = bytes
        let head = bytes.loadUInt32(wordOffset: 0)
        let parsedKeyWidth = Int((head >> 30) & 3)
        let parsedValueWidth = Int((head >> 28) & 3)
        if parsedKeyWidth == 0 || parsedValueWidth == 0 {
            indexByteCount = 4
        } else {
            indexByteCount = PerfectHashView.encodedByteCount(for: Int(head & 0x0fff_ffff))
        }
        assert((bodyWordOffset + (keyWidth + valueWidth) * count) * 4 <= bytes.count)
    }

    public static var empty: Self {
        @_lifetime(immortal)
        get { Self(.empty) }
    }

    public var _protoCacheSpan: Span {
        @_lifetime(copy self)
        borrowing get { bytes }
    }
    @inlinable public var count: Int {
        guard bytes.count >= 4 else { return 0 }
        let head = bytes.loadUInt32(wordOffset: 0)
        return keyWidth == 0 || valueWidth == 0 ? 0 : Int(head & 0x0fff_ffff)
    }
    @inlinable public var isEmpty: Bool { count == 0 }
    @inlinable @inline(__always) var keyWidth: Int {
        bytes.count >= 4 ? Int((bytes.loadUInt32(wordOffset: 0) >> 30) & 3) : 0
    }
    @inlinable @inline(__always) var valueWidth: Int {
        bytes.count >= 4 ? Int((bytes.loadUInt32(wordOffset: 0) >> 28) & 3) : 0
    }
    @inlinable @inline(__always) var bodyWordOffset: Int { (indexByteCount + 3) / 4 }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    public func key(at position: Int) -> Key {
        precondition(position >= 0 && position < count)
        let keyWidth = self.keyWidth
        let valueWidth = self.valueWidth
        let start = bodyWordOffset + position * (keyWidth + valueWidth)
        let keyByteOffset = start * 4
        return Key._decodeProtoCache(
            fromRawWords: bytes.rawBaseAddress.advanced(by: keyByteOffset),
            availableByteCount: bytes.count - keyByteOffset,
            width: keyWidth,
            owner: bytes
        )!
    }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    public func value(at position: Int) -> Value {
        precondition(position >= 0 && position < count)
        let keyWidth = self.keyWidth
        let valueWidth = self.valueWidth
        let start = bodyWordOffset + position * (keyWidth + valueWidth) + keyWidth
        let valueByteOffset = start * 4
        return Value._decodeProtoCache(
            fromRawWords: bytes.rawBaseAddress.advanced(by: valueByteOffset),
            availableByteCount: bytes.count - valueByteOffset,
            width: valueWidth,
            owner: bytes
        )!
    }

    @_lifetime(copy self)
    public func value(for key: borrowing Key) -> Value? {
        let index = PerfectHashView(bytes)
        let position = key._withProtoCacheKeyBytes { index.locate($0) }
        guard let position, position < count,
              self.key(at: position)._protoCacheEquals(key) else { return nil }
        return value(at: position)
    }

    @inlinable
    public func forEach(
        _ body: (borrowing Key, borrowing Value) throws -> Void
    ) rethrows {
        guard bytes.count >= 4 else { return }
        let head = bytes.loadUInt32(wordOffset: 0)
        let entryCount = Int(head & 0x0fff_ffff)
        let keyWidth = Int((head >> 30) & 3)
        let valueWidth = Int((head >> 28) & 3)
        guard keyWidth != 0, valueWidth != 0 else { return }
        let entryByteStride = (keyWidth &+ valueWidth) &* 4
        var keyByteOffset = bodyWordOffset &* 4
        var position = 0
        while position < entryCount {
            let key = Key._decodeProtoCache(
                fromRawWords: bytes.rawBaseAddress.advanced(by: keyByteOffset),
                availableByteCount: bytes.count - keyByteOffset,
                width: keyWidth,
                owner: bytes
            )!
            let valueByteOffset = keyByteOffset &+ keyWidth &* 4
            let value = Value._decodeProtoCache(
                fromRawWords: bytes.rawBaseAddress.advanced(by: valueByteOffset),
                availableByteCount: bytes.count - valueByteOffset,
                width: valueWidth,
                owner: bytes
            )!
            try body(key, value)
            keyByteOffset &+= entryByteStride
            position &+= 1
        }
    }
}

extension MapView where Key == StringView, Value: ~Escapable {
    public func position(for key: String) -> Int? {
        let index = PerfectHashView(bytes)
        let position = key.utf8.withContiguousStorageIfAvailable { storage in
            index.locate(UnsafeRawBufferPointer(storage))
        } ?? Array(key.utf8).withUnsafeBytes { index.locate($0) }
        guard let position, position < count else { return nil }
        let stored = self.key(at: position)
        guard stored.equalsUTF8(key) else { return nil }
        return position
    }
}

extension BytesView: FieldDecodable {
    @_lifetime(copy field)
    @inlinable @inline(__always)
    public static func _decodeProtoCache(from field: FieldView) -> BytesView? { field.bytes() }

    @_lifetime(copy owner)
    @inlinable @inline(__always)
    public static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing Span
    ) -> BytesView? {
        guard let string = StringView._decodeProtoCache(
            fromRawWords: baseAddress,
            availableByteCount: availableByteCount,
            width: width,
            owner: owner
        ) else { return nil }
        return BytesView(string)
    }
}
