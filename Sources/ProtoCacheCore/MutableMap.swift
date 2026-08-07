/// Generated-code support for canonical mutable map-key encoding.
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

/// An eagerly materialized mutable ProtoCache map.
///
/// Generated mutable getters construct the complete map on first access. The
/// wrapper keeps Swift `Dictionary` value semantics while providing stable
/// in-place mutation operations for generated message values.
public struct MutableMap<Key: Hashable & Sendable, Value: Sendable>: Sendable,
    Collection, ExpressibleByDictionaryLiteral
{
    public typealias Index = Dictionary<Key, Value>.Index
    public typealias Element = Dictionary<Key, Value>.Element

    @usableFromInline var storage: [Key: Value]

    @inlinable
    public init() { storage = [:] }

    @inlinable
    public init(_ values: [Key: Value]) {
        storage = values
    }

    @inlinable
    public init(dictionaryLiteral elements: (Key, Value)...) {
        storage = [:]
        storage.reserveCapacity(elements.count)
        for (key, value) in elements { storage[key] = value }
    }

    @inlinable public var startIndex: Index { storage.startIndex }
    @inlinable public var endIndex: Index { storage.endIndex }
    @inlinable public var count: Int { storage.count }
    @inlinable public var isEmpty: Bool { storage.isEmpty }
    @inlinable public var keys: Dictionary<Key, Value>.Keys { storage.keys }

    @inlinable
    public subscript(position: Index) -> Element { storage[position] }
    @inlinable
    public func index(after index: Index) -> Index { storage.index(after: index) }

    @inlinable
    public subscript(key: Key) -> Value? {
        get { storage[key] }
        set { storage[key] = newValue }
        _modify { yield &storage[key] }
    }

    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        storage.reserveCapacity(minimumCapacity)
    }

    @discardableResult
    @inlinable
    public mutating func updateValue(_ value: Value, forKey key: Key) -> Value? {
        storage.updateValue(value, forKey: key)
    }

    @discardableResult
    @inlinable
    public mutating func removeValue(forKey key: Key) -> Value? {
        storage.removeValue(forKey: key)
    }

    @inlinable
    public mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepCapacity)
    }

    /// Performs an in-place operation on the value stored for `key`.
    @inlinable
    public mutating func withValue<Result>(
        forKey key: Key,
        _ body: (inout Value?) throws -> Result
    ) rethrows -> Result {
        try body(&storage[key])
    }

    /// Provides generated encoders with the underlying dictionary without a copy.
    ///
    /// This underscored entry point is generated-code support rather than a
    /// source-stable application API.
    @inlinable
    public func _withDictionary<Result>(
        _ body: (borrowing [Key: Value]) throws -> Result
    ) rethrows -> Result {
        try body(storage)
    }

    /// Mutates every value without requiring a separate key snapshot.
    @inlinable
    public mutating func forEachMutable(
        _ body: (Key, inout Value) throws -> Void
    ) rethrows {
        var index = storage.startIndex
        while index != storage.endIndex {
            let key = storage[index].key
            let next = storage.index(after: index)
            try body(key, &storage.values[index])
            index = next
        }
    }
}
