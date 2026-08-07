public protocol FieldDecodable: ~Escapable, Sendable {
    @_lifetime(copy field)
    static func _decodeProtoCache(from field: FieldView) -> Self?

    @_lifetime(copy owner)
    static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing Span
    ) -> Self?
}

public protocol Scalar: FieldDecodable {
    static var _protoCacheWordWidth: Int { get }
    static var _protoCacheDefault: Self { get }
    static func _decodeProtoCache(words: Span) -> Self?
    static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Self
    func _encodeProtoCacheWords() -> (UInt32, UInt32)
}

extension Scalar {
    @inlinable @inline(__always)
    public static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing Span
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

extension Bool: Scalar {
    public static let _protoCacheWordWidth = 1
    public static let _protoCacheDefault = false
    public static func _decodeProtoCache(words: Span) -> Bool? { words.loadUInt32(wordOffset: 0) != 0 }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Bool { word0 != 0 }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (self ? 1 : 0, 0) }
}
extension Int32: Scalar {
    public static let _protoCacheWordWidth = 1
    public static let _protoCacheDefault: Int32 = 0
    public static func _decodeProtoCache(words: Span) -> Int32? { Int32(bitPattern: words.loadUInt32(wordOffset: 0)) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Int32 { Int32(bitPattern: word0) }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (UInt32(bitPattern: self), 0) }
}
extension UInt32: Scalar {
    public static let _protoCacheWordWidth = 1
    public static let _protoCacheDefault: UInt32 = 0
    public static func _decodeProtoCache(words: Span) -> UInt32? { words.loadUInt32(wordOffset: 0) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> UInt32 { word0 }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (self, 0) }
}
extension Int64: Scalar {
    public static let _protoCacheWordWidth = 2
    public static let _protoCacheDefault: Int64 = 0
    public static func _decodeProtoCache(words: Span) -> Int64? { Int64(bitPattern: words.loadUInt64(wordOffset: 0)) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Int64 { Int64(bitPattern: UInt64(word0) | UInt64(word1) << 32) }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { let bits = UInt64(bitPattern: self); return (UInt32(truncatingIfNeeded: bits), UInt32(truncatingIfNeeded: bits >> 32)) }
}
extension UInt64: Scalar {
    public static let _protoCacheWordWidth = 2
    public static let _protoCacheDefault: UInt64 = 0
    public static func _decodeProtoCache(words: Span) -> UInt64? { words.loadUInt64(wordOffset: 0) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> UInt64 { UInt64(word0) | UInt64(word1) << 32 }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (UInt32(truncatingIfNeeded: self), UInt32(truncatingIfNeeded: self >> 32)) }
}
extension Float: Scalar {
    public static let _protoCacheWordWidth = 1
    public static let _protoCacheDefault: Float = 0
    public static func _decodeProtoCache(words: Span) -> Float? { Float(bitPattern: words.loadUInt32(wordOffset: 0)) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Float { Float(bitPattern: word0) }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (bitPattern, 0) }
}
extension Double: Scalar {
    public static let _protoCacheWordWidth = 2
    public static let _protoCacheDefault: Double = 0
    public static func _decodeProtoCache(words: Span) -> Double? { Double(bitPattern: words.loadUInt64(wordOffset: 0)) }
    @inlinable public static func _decodeProtoCache(word0: UInt32, word1: UInt32) -> Double { Double(bitPattern: UInt64(word0) | UInt64(word1) << 32) }
    public func _encodeProtoCacheWords() -> (UInt32, UInt32) { (UInt32(truncatingIfNeeded: bitPattern), UInt32(truncatingIfNeeded: bitPattern >> 32)) }
}

public protocol MapKey: ~Escapable, FieldDecodable {
    func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
    func _protoCacheEquals(_ other: borrowing Self) -> Bool
}

extension MapKey where Self: Equatable {
    @inlinable @inline(__always)
    public func _protoCacheEquals(_ other: borrowing Self) -> Bool { self == other }
}

private func withIntegerKeyBytes<T, R>(_ value: T, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    var copy = value
    return try Swift.withUnsafeBytes(of: &copy) { try body($0) }
}

extension Int32: MapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try withIntegerKeyBytes(littleEndian, body) }
}
extension UInt32: MapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try withIntegerKeyBytes(littleEndian, body) }
}
extension Int64: MapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try withIntegerKeyBytes(littleEndian, body) }
}
extension UInt64: MapKey {
    public func _withProtoCacheKeyBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try withIntegerKeyBytes(littleEndian, body) }
}
