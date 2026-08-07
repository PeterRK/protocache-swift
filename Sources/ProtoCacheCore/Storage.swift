@usableFromInline final class ProtoCacheStorage: @unchecked Sendable {
    let baseAddress: UnsafeRawPointer
    let byteCount: Int
    private let mutableBaseAddress: UnsafeMutableRawPointer?
    private let deallocator: (@Sendable (UnsafeMutableRawPointer, Int) -> Void)?

    init(baseAddress: UnsafeRawPointer, mutableBaseAddress: UnsafeMutableRawPointer?, byteCount: Int, deallocator: (@Sendable (UnsafeMutableRawPointer, Int) -> Void)?) {
        self.baseAddress = baseAddress
        self.mutableBaseAddress = mutableBaseAddress
        self.byteCount = byteCount
        self.deallocator = deallocator
    }

    deinit {
        if let mutableBaseAddress, let deallocator { deallocator(mutableBaseAddress, byteCount) }
    }

    static let empty: ProtoCacheStorage = {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
        pointer.storeBytes(of: UInt32(0), as: UInt32.self)
        return ProtoCacheStorage(baseAddress: UnsafeRawPointer(pointer), mutableBaseAddress: pointer, byteCount: 4, deallocator: { pointer, _ in pointer.deallocate() })
    }()
}

public struct Span: ~Escapable, Copyable, @unchecked Sendable {
    @usableFromInline let raw: RawSpan

    @_lifetime(copy raw)
    @inlinable public init(_ raw: RawSpan) {
        self.raw = raw
    }

    @_lifetime(borrow bytes)
    @unsafe @inlinable
    public init(unsafeBorrowing bytes: UnsafeRawBufferPointer) {
        raw = RawSpan(_unsafeBytes: bytes)
    }

    @inlinable public var count: Int { raw.byteCount }
    @inlinable public var isEmpty: Bool { raw.isEmpty }

    @inlinable public static var empty: Span {
        @_lifetime(immortal)
        get { Span(RawSpan()) }
    }

    @inlinable @inline(__always)
    public func withUnsafeBytes<E: Error, Result: ~Copyable>(
        _ body: (UnsafeRawBufferPointer) throws(E) -> Result
    ) throws(E) -> Result {
        try raw.withUnsafeBytes(body)
    }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    public func slice(byteOffset: Int, count: Int) -> Span {
        precondition(byteOffset >= 0 && count >= 0 && byteOffset + count <= self.count)
        return Span(raw.extracting(byteOffset..<(byteOffset + count)))
    }

    @_lifetime(copy self)
    @inlinable @inline(__always)
    func wordSlice(offset: Int, count: Int? = nil) -> Span {
        let byteOffset = offset &* 4
        let byteCount = count.map { $0 &* 4 } ?? (self.count - byteOffset)
        return slice(byteOffset: byteOffset, count: byteCount)
    }

    @inlinable @inline(__always)
    var rawBaseAddress: UnsafeRawPointer {
        raw.withUnsafeBytes { $0.baseAddress! }
    }

    @inlinable @inline(__always)
    func loadUInt8(at offset: Int) -> UInt8 {
        assert(offset >= 0 && offset < count)
        return raw.unsafeLoad(fromUncheckedByteOffset: offset, as: UInt8.self)
    }

    @inlinable @inline(__always)
    func loadUInt32(wordOffset: Int) -> UInt32 {
        let offset = wordOffset &* 4
        assert(offset >= 0 && offset + 4 <= count)
        return UInt32(littleEndian: raw.unsafeLoadUnaligned(
            fromUncheckedByteOffset: offset,
            as: UInt32.self
        ))
    }

    @inlinable @inline(__always)
    func loadUInt64(wordOffset: Int) -> UInt64 {
        let offset = wordOffset &* 4
        assert(offset >= 0 && offset + 8 <= count)
        return UInt64(littleEndian: raw.unsafeLoadUnaligned(
            fromUncheckedByteOffset: offset,
            as: UInt64.self
        ))
    }

    @inlinable
    public func elementsEqual(_ other: borrowing Span) -> Bool {
        guard count == other.count else { return false }
        return withUnsafeBytes { left in
            other.withUnsafeBytes { right in left.elementsEqual(right) }
        }
    }

    public func byteRange(of child: borrowing Span) -> Range<Int> {
        withUnsafeBytes { root in
            child.withUnsafeBytes { nested in
                guard let nestedBase = nested.baseAddress else { return 0..<0 }
                let offset = root.baseAddress!.distance(to: nestedBase)
                precondition(offset >= 0 && offset + nested.count <= root.count)
                return offset..<(offset + nested.count)
            }
        }
    }
}

public struct ProtoCacheBytes: @unchecked Sendable {
    @usableFromInline let storage: ProtoCacheStorage
    @usableFromInline let baseAddress: UnsafeRawPointer
    @usableFromInline let byteOffset: Int
    public let count: Int

    public static let empty = ProtoCacheBytes(storage: .empty, byteOffset: 0, count: 4)

    @usableFromInline init(storage: ProtoCacheStorage, byteOffset: Int, count: Int) {
        self.storage = storage
        self.baseAddress = storage.baseAddress.advanced(by: byteOffset)
        self.byteOffset = byteOffset
        self.count = count
    }

    public init(adopting baseAddress: UnsafeMutableRawPointer, count: Int, deallocator: @escaping @Sendable (UnsafeMutableRawPointer, Int) -> Void = { pointer, _ in pointer.deallocate() }) {
        precondition(count >= 0)
        let storage = ProtoCacheStorage(baseAddress: UnsafeRawPointer(baseAddress), mutableBaseAddress: baseAddress, byteCount: count, deallocator: deallocator)
        self.init(storage: storage, byteOffset: 0, count: count)
    }

    package init(copying bytes: UnsafeRawBufferPointer) {
        if bytes.isEmpty { self = .empty; return }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 4)
        pointer.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        self.init(adopting: pointer, count: bytes.count)
    }

    package init(copying bytes: [UInt8]) {
        self = bytes.withUnsafeBytes { ProtoCacheBytes(copying: $0) }
    }

    public var isEmpty: Bool { count == 0 }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: rawBaseAddress, count: count))
    }

    public borrowing func withBorrowedSpan<R>(
        _ body: (borrowing Span) throws -> R
    ) rethrows -> R {
        try withUnsafeBytes { bytes in
            try body(Span(unsafeBorrowing: bytes))
        }
    }

    public borrowing func ownedSlice(of span: borrowing Span) -> ProtoCacheBytes {
        let range = byteRange(of: span)
        return slice(byteOffset: range.lowerBound, count: range.count)
    }

    public borrowing func byteRange(of span: borrowing Span) -> Range<Int> {
        withUnsafeBytes { root in
            span.withUnsafeBytes { child in
                guard let childBase = child.baseAddress else { return 0..<0 }
                let offset = root.baseAddress!.distance(to: childBase)
                precondition(offset >= 0 && offset + child.count <= root.count)
                return offset..<(offset + child.count)
            }
        }
    }

    @inlinable public func slice(byteOffset: Int, count: Int) -> ProtoCacheBytes {
        precondition(byteOffset >= 0 && count >= 0 && byteOffset + count <= self.count)
        return ProtoCacheBytes(
            storage: storage,
            byteOffset: self.byteOffset + byteOffset,
            count: count
        )
    }

    @inlinable var rawBaseAddress: UnsafeRawPointer { baseAddress }

    @inlinable @inline(__always)
    func loadUInt8(at offset: Int) -> UInt8 {
        assert(offset >= 0 && offset < count)
        return rawBaseAddress.load(fromByteOffset: offset, as: UInt8.self)
    }

    @inlinable @inline(__always)
    func loadUInt32(wordOffset: Int) -> UInt32 {
        let offset = wordOffset &* 4
        assert(offset >= 0 && offset + 4 <= count)
        return UInt32(littleEndian: rawBaseAddress.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inlinable @inline(__always)
    func loadUInt64(wordOffset: Int) -> UInt64 {
        let offset = wordOffset &* 4
        assert(offset >= 0 && offset + 8 <= count)
        return UInt64(littleEndian: rawBaseAddress.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inlinable @inline(__always)
    func wordSlice(offset: Int, count: Int? = nil) -> ProtoCacheBytes {
        let byteOffset = offset &* 4
        let byteCount = count.map { $0 &* 4 } ?? (self.count - byteOffset)
        return slice(byteOffset: byteOffset, count: byteCount)
    }
}

extension ProtoCacheBytes: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBytes { left in rhs.withUnsafeBytes { right in left.elementsEqual(right) } }
    }
}
