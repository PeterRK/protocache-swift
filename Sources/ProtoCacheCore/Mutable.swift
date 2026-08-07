/// The application-facing contract shared by generated mutable values.
///
/// Field access and incremental encoding remain concrete generated APIs; this
/// protocol only defines ownership construction and complete serialization.
public protocol MutableValue: Sendable {
    /// Creates an empty owned mutable value.
    init()

    /// Creates a lazy mutable value backed by immutable owned bytes.
    init(_ bytes: Bytes)

    /// Serializes the current value as a complete ProtoCache root.
    func serialized() throws -> Bytes

    /// Serializes into reusable storage and lends the result for the duration
    /// of `body`.
    func withSerializedSpan<Result>(
        using buffer: SerializationBuffer,
        _ body: (borrowing Span) throws -> Result
    ) throws -> Result
}

/// Reusable storage for repeated serialization.
///
/// The buffer is not thread-safe or reentrant. A span passed to a
/// `withSerializedSpan` callback is valid only during that call.
public final class SerializationBuffer {
    @usableFromInline let storage: _ProtoCacheBuffer

    package var _protoCacheStorage: _ProtoCacheBuffer { storage }

    public init(minimumCapacityBytes: Int = 256) {
        precondition(minimumCapacityBytes >= 0)
        let wholeWords = minimumCapacityBytes / MemoryLayout<UInt32>.size
        let partialWord = minimumCapacityBytes % MemoryLayout<UInt32>.size == 0 ? 0 : 1
        storage = _ProtoCacheBuffer(
            minimumCapacityWords: max(1, wholeWords + partialWord)
        )
    }
}

/// Generated-code support for composing nested mutable values.
public protocol _ProtoCacheMutableEncoding: MutableValue {
    /// Whether this value encodes as the canonical empty/default value.
    var _isProtoCacheEmpty: Bool { get }

    /// Encodes into a generated caller's reusable reverse buffer.
    func _encodeProtoCache(in buffer: _ProtoCacheBuffer) throws -> Unit
}

extension _ProtoCacheMutableEncoding {
    @inlinable
    public func serialized() throws -> Bytes {
        let buffer = _ProtoCacheBuffer()
        return try buffer.finish(_encodeProtoCache(in: buffer))
    }

    @inlinable
    public func withSerializedSpan<Result>(
        using buffer: SerializationBuffer,
        _ body: (borrowing Span) throws -> Result
    ) throws -> Result {
        buffer.storage.clear()
        let root = try _encodeProtoCache(in: buffer.storage)
        return try buffer.storage.withBorrowedOutput(root, body)
    }
}

/// Indirect storage used by generated mutable values only for recursive
/// singular-message edges.
public final class _ProtoCacheBox<Value: Sendable>: @unchecked Sendable {
    public var value: Value
    public init(_ value: Value) { self.value = value }
}

/// Preserves value isolation when a generated recursive field is modified.
@inline(__always)
public func _protoCacheEnsureUnique<Value: Sendable>(_ box: inout _ProtoCacheBox<Value>) {
    if !isKnownUniquelyReferenced(&box) { box = _ProtoCacheBox(box.value) }
}
