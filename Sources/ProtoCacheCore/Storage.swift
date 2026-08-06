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

public struct ProtoCacheBytes: @unchecked Sendable {
    @usableFromInline let storage: ProtoCacheStorage?
    @usableFromInline let baseAddress: UnsafeRawPointer
    @usableFromInline let byteOffset: Int
    public let count: Int

    public static let empty = ProtoCacheBytes(storage: .empty, byteOffset: 0, count: 4)

    init(storage: ProtoCacheStorage, byteOffset: Int, count: Int) {
        self.storage = storage
        self.baseAddress = storage.baseAddress.advanced(by: byteOffset)
        self.byteOffset = byteOffset
        self.count = count
    }

    @usableFromInline init(
        storage: ProtoCacheStorage?,
        baseAddress: UnsafeRawPointer,
        byteOffset: Int,
        count: Int
    ) {
        self.storage = storage
        self.baseAddress = baseAddress
        self.byteOffset = byteOffset
        self.count = count
    }

    public init(adopting baseAddress: UnsafeMutableRawPointer, count: Int, deallocator: @escaping @Sendable (UnsafeMutableRawPointer, Int) -> Void = { pointer, _ in pointer.deallocate() }) {
        precondition(count >= 0)
        let storage = ProtoCacheStorage(baseAddress: UnsafeRawPointer(baseAddress), mutableBaseAddress: baseAddress, byteCount: count, deallocator: deallocator)
        self.init(storage: storage, byteOffset: 0, count: count)
    }

    public init(unsafeBorrowing bytes: UnsafeRawBufferPointer) {
        precondition(bytes.count == 0 || bytes.baseAddress != nil)
        if let baseAddress = bytes.baseAddress, !bytes.isEmpty {
            self.init(storage: nil, baseAddress: baseAddress, byteOffset: 0, count: bytes.count)
        } else {
            self = .empty
        }
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

    @inlinable public func slice(byteOffset: Int, count: Int) -> ProtoCacheBytes {
        precondition(byteOffset >= 0 && count >= 0 && byteOffset + count <= self.count)
        return ProtoCacheBytes(
            storage: storage,
            baseAddress: baseAddress.advanced(by: byteOffset),
            byteOffset: self.byteOffset + byteOffset,
            count: count
        )
    }

    @inlinable var rawBaseAddress: UnsafeRawPointer { baseAddress }

    package var _hasOwner: Bool { storage != nil }

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
