public protocol ProtoCacheDecodable: Sendable {
    static func _decodeProtoCache(from field: FieldView) -> Self?
    static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing ProtoCacheBytes
    ) -> Self?
}

extension ProtoCacheDecodable {
    public static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing ProtoCacheBytes
    ) -> Self? {
        let offset = owner.rawBaseAddress.distance(to: baseAddress)
        guard offset >= 0, availableByteCount >= width * 4,
              offset + availableByteCount <= owner.count else { return nil }
        let tail = owner.slice(byteOffset: offset, count: availableByteCount)
        return _decodeProtoCache(from: FieldView(tail: tail, width: width))
    }
}

public protocol ProtoCacheScalar: ProtoCacheDecodable {
    static var _protoCacheWordWidth: Int { get }
    static var _protoCacheDefault: Self { get }
    static func _decodeProtoCache(words: ProtoCacheBytes) -> Self?
    static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Self
    func _encodeProtoCacheWords() -> (UInt32, UInt32)
}

extension ProtoCacheScalar {
    @inlinable @inline(__always)
    public static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing ProtoCacheBytes
    ) -> Self? {
        guard width == _protoCacheWordWidth, availableByteCount >= width * 4 else { return nil }
        let word0 = UInt32(littleEndian: baseAddress.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        let word1 = width == 2
            ? UInt32(littleEndian: baseAddress.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            : 0
        return _decodeProtoCache(word0: word0, word1: word1)
    }

    public static func _decodeProtoCache(from field: FieldView) -> Self? {
        guard field.width == _protoCacheWordWidth else { return nil }
        return _decodeProtoCache(words: field.rawBytes)
    }

}

extension Bool: ProtoCacheScalar {
    public static let _protoCacheWordWidth = 1
    public static let _protoCacheDefault = false
    public static func _decodeProtoCache(words: ProtoCacheBytes) -> Bool? { words.loadUInt32(wordOffset: 0) != 0 }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Bool { word0 != 0 }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (self ? 1 : 0, 0) }
}
extension Int32: ProtoCacheScalar {
    public static let _protoCacheWordWidth = 1
    public static let _protoCacheDefault: Int32 = 0
    public static func _decodeProtoCache(words: ProtoCacheBytes) -> Int32? { Int32(bitPattern: words.loadUInt32(wordOffset: 0)) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Int32 { Int32(bitPattern: word0) }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (UInt32(bitPattern: self), 0) }
}
extension UInt32: ProtoCacheScalar {
    public static let _protoCacheWordWidth = 1
    public static let _protoCacheDefault: UInt32 = 0
    public static func _decodeProtoCache(words: ProtoCacheBytes) -> UInt32? { words.loadUInt32(wordOffset: 0) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> UInt32 { word0 }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (self, 0) }
}
extension Int64: ProtoCacheScalar {
    public static let _protoCacheWordWidth = 2
    public static let _protoCacheDefault: Int64 = 0
    public static func _decodeProtoCache(words: ProtoCacheBytes) -> Int64? { Int64(bitPattern: words.loadUInt64(wordOffset: 0)) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Int64 { Int64(bitPattern: UInt64(word0) | UInt64(word1) << 32) }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { let bits = UInt64(bitPattern: self); return (UInt32(truncatingIfNeeded: bits), UInt32(truncatingIfNeeded: bits >> 32)) }
}
extension UInt64: ProtoCacheScalar {
    public static let _protoCacheWordWidth = 2
    public static let _protoCacheDefault: UInt64 = 0
    public static func _decodeProtoCache(words: ProtoCacheBytes) -> UInt64? { words.loadUInt64(wordOffset: 0) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> UInt64 { UInt64(word0) | UInt64(word1) << 32 }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (UInt32(truncatingIfNeeded: self), UInt32(truncatingIfNeeded: self >> 32)) }
}
extension Float: ProtoCacheScalar {
    public static let _protoCacheWordWidth = 1
    public static let _protoCacheDefault: Float = 0
    public static func _decodeProtoCache(words: ProtoCacheBytes) -> Float? { Float(bitPattern: words.loadUInt32(wordOffset: 0)) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Float { Float(bitPattern: word0) }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (bitPattern, 0) }
}
extension Double: ProtoCacheScalar {
    public static let _protoCacheWordWidth = 2
    public static let _protoCacheDefault: Double = 0
    public static func _decodeProtoCache(words: ProtoCacheBytes) -> Double? { Double(bitPattern: words.loadUInt64(wordOffset: 0)) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Double { Double(bitPattern: UInt64(word0) | UInt64(word1) << 32) }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (UInt32(truncatingIfNeeded: bitPattern), UInt32(truncatingIfNeeded: bitPattern >> 32)) }
}

public protocol ProtoCacheMapKey: ProtoCacheDecodable, Hashable {
    func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
}

private func withIntegerKeyBytes<T, R>(_ value: T, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    var copy = value
    return try Swift.withUnsafeBytes(of: &copy) { try body($0) }
}

extension Int32: ProtoCacheMapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try withIntegerKeyBytes(littleEndian, body) }
}
extension UInt32: ProtoCacheMapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try withIntegerKeyBytes(littleEndian, body) }
}
extension Int64: ProtoCacheMapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try withIntegerKeyBytes(littleEndian, body) }
}
extension UInt64: ProtoCacheMapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try withIntegerKeyBytes(littleEndian, body) }
}
