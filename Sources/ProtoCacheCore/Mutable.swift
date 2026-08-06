public final class _ProtoCacheBox<Value: Sendable>: @unchecked Sendable {
    public var value: Value
    public init(_ value: Value) { self.value = value }
    public func copy() -> _ProtoCacheBox<Value> { _ProtoCacheBox(value) }
}

@inline(__always)
public func _protoCacheEnsureUnique<Value: Sendable>(_ box: inout _ProtoCacheBox<Value>) {
    if !isKnownUniquelyReferenced(&box) { box = box.copy() }
}

public struct _ProtoCacheAccessed: Sendable {
    private var words: [UInt64]
    public init(fieldCount: Int) { words = [UInt64](repeating: 0, count: (fieldCount + 63) / 64) }
    public mutating func insert(_ fieldID: Int) {
        guard !words.isEmpty else { return }
        words[fieldID >> 6] |= UInt64(1) << UInt64(fieldID & 63)
    }
    public func contains(_ fieldID: Int) -> Bool {
        !words.isEmpty && words[fieldID >> 6] & (UInt64(1) << UInt64(fieldID & 63)) != 0
    }
    public var isEmpty: Bool { words.allSatisfy { $0 == 0 } }
}

public protocol _ProtoCacheOwnedMapKey: Hashable, Sendable {
    var _protoCacheKeyBytes: [UInt8] { get }
}

extension String: _ProtoCacheOwnedMapKey {
    public var _protoCacheKeyBytes: [UInt8] { Array(utf8) }
}

private func integerKeyBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    var copy = value.littleEndian
    return Swift.withUnsafeBytes(of: &copy) { Array($0) }
}

extension Int32: _ProtoCacheOwnedMapKey {
    public var _protoCacheKeyBytes: [UInt8] { integerKeyBytes(self) }
}
extension UInt32: _ProtoCacheOwnedMapKey {
    public var _protoCacheKeyBytes: [UInt8] { integerKeyBytes(self) }
}
extension Int64: _ProtoCacheOwnedMapKey {
    public var _protoCacheKeyBytes: [UInt8] { integerKeyBytes(self) }
}
extension UInt64: _ProtoCacheOwnedMapKey {
    public var _protoCacheKeyBytes: [UInt8] { integerKeyBytes(self) }
}
