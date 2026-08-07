public struct PerfectHashView: ~Escapable, Copyable, @unchecked Sendable {
    let bytes: Span
    public let count: Int
    public let byteCount: Int
    private let section: Int
    private let bitmapOffset: Int
    private let tableOffset: Int
    private let tableWidth: Int

    @inline(__always)
    static func encodedByteCount(for count: Int) -> Int {
        guard count > 1 else { return 4 }
        let section = PerfectHash.section(for: count)
        let bitmapSize = PerfectHash.bitmapSize(section: section)
        let tableWidth = count > 65_535 ? 4 : count > 255 ? 2 : count > 24 ? 1 : 0
        return 8 + bitmapSize + (bitmapSize / 8) * tableWidth
    }

    @_lifetime(copy bytes)
    public init(_ bytes: Span) {
        guard bytes.count >= 4 else {
            self.bytes = .empty
            count = 0
            byteCount = 4
            section = 0
            bitmapOffset = 0
            tableOffset = 0
            tableWidth = 0
            return
        }
        self.bytes = bytes
        count = Int(bytes.loadUInt32(wordOffset: 0) & 0x0fff_ffff)
        if count <= 1 {
            byteCount = 4; section = 0; bitmapOffset = 0; tableOffset = 0; tableWidth = 0
        } else {
            section = PerfectHash.section(for: count)
            let bitmapSize = PerfectHash.bitmapSize(section: section)
            tableWidth = count > 65_535 ? 4 : count > 255 ? 2 : count > 24 ? 1 : 0
            bitmapOffset = 8
            tableOffset = bitmapOffset + bitmapSize
            byteCount = Self.encodedByteCount(for: count)
            assert(byteCount <= bytes.count)
        }
    }

    public static var empty: PerfectHashView {
        @_lifetime(immortal)
        get { PerfectHashView(.empty) }
    }

    public func locate(_ key: UnsafeRawBufferPointer) -> Int? {
        if count == 0 { return nil }
        if count == 1 { return 0 }
        let seed = UInt64(bytes.loadUInt32(wordOffset: 1))
        let code = ProtoCacheHash.hash128(key, seed: seed)
        let slots = [Int(code.0) % section, Int(code.1) % section + section, Int(code.2) % section + section * 2]
        let sum = bit2(slots[0]) + bit2(slots[1]) + bit2(slots[2])
        let slot = slots[sum % 3]
        let block = slot >> 5
        let bit = slot & 31
        let offset: Int
        switch tableWidth {
        case 4: offset = Int(loadUInt32(byteOffset: tableOffset + block * 4))
        case 2: offset = Int(loadUInt16(byteOffset: tableOffset + block * 2))
        case 1: offset = Int(bytes.loadUInt8(at: tableOffset + block))
        default: offset = 0
        }
        let bitmapWord = loadUInt64(byteOffset: bitmapOffset + block * 8)
        let masked = bitmapWord | (UInt64.max << UInt64(bit * 2))
        let invalid = ((masked & 0x5555_5555_5555_5555) & (masked >> 1)).nonzeroBitCount
        return offset + 32 - invalid
    }

    private func bit2(_ position: Int) -> Int {
        Int((bytes.loadUInt8(at: bitmapOffset + (position >> 2)) >> UInt8((position & 3) * 2)) & 3)
    }
    private func loadUInt16(byteOffset: Int) -> UInt16 {
        UInt16(littleEndian: bytes.rawBaseAddress.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self))
    }
    private func loadUInt32(byteOffset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.rawBaseAddress.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self))
    }
    private func loadUInt64(byteOffset: Int) -> UInt64 {
        UInt64(littleEndian: bytes.rawBaseAddress.loadUnaligned(fromByteOffset: byteOffset, as: UInt64.self))
    }
}

public enum PerfectHash {
    struct Edge { let slots: [Int] }

    static func section(for count: Int) -> Int { max(10, (count * 105 + 255) / 256) }
    static func bitmapSize(section: Int) -> Int { ((section * 3 + 31) & ~31) / 4 }

    public static func build(_ keys: [[UInt8]]) throws -> (index: [UInt8], positions: [Int]) {
        guard keys.count < 1 << 28 else { throw ProtoCacheError.integerOverflow }
        var unique = Set<[UInt8]>()
        for key in keys where !unique.insert(key).inserted { throw ProtoCacheError.duplicateMapKey }
        if keys.count <= 1 {
            return (littleEndianBytes(UInt32(keys.count)), keys.isEmpty ? [] : [0])
        }
        let section = section(for: keys.count)
        let vertexCount = section * 3
        var seed: UInt32 = 0
        var selectedEdges: [Edge] = []
        var selectedOrder: [Int] = []
        while true {
            let edges = keys.map { key -> Edge in
                let code = ProtoCacheHash.hash128(key, seed: UInt64(seed))
                return Edge(slots: [Int(code.0) % section, Int(code.1) % section + section, Int(code.2) % section + section * 2])
            }
            if let order = peel(edges, vertexCount: vertexCount) {
                selectedEdges = edges; selectedOrder = order; break
            }
            seed &+= 1
            if seed == 0 { throw ProtoCacheError.perfectHashBuildFailed }
        }

        let bitmapSize = bitmapSize(section: section)
        var bitmap = [UInt8](repeating: 0xff, count: bitmapSize)
        var taken = [Bool](repeating: false, count: vertexCount)
        for edgeIndex in selectedOrder.reversed() {
            let slots = selectedEdges[edgeIndex].slots
            let chosen: Int
            let target: UInt8
            if !taken[slots[0]] { chosen = slots[0]; target = 0; taken[slots[0]] = true; taken[slots[1]] = true; taken[slots[2]] = true }
            else if !taken[slots[1]] { chosen = slots[1]; target = 1; taken[slots[1]] = true; taken[slots[2]] = true }
            else { chosen = slots[2]; target = 2; taken[slots[2]] = true }
            let others = slots.filter { $0 != chosen }
            let sum = Int(getBit2(bitmap, others[0])) + Int(getBit2(bitmap, others[1]))
            setBit2(&bitmap, chosen, UInt8((Int(target) - sum % 3 + 3) % 3))
        }

        var output = littleEndianBytes(UInt32(keys.count))
        output += littleEndianBytes(seed)
        output += bitmap
        let blocks = bitmapSize / 8
        if keys.count > 65_535 {
            var running: UInt32 = 0
            for block in 0..<blocks { output += littleEndianBytes(running); running &+= UInt32(validCount(bitmap, block)) }
        } else if keys.count > 255 {
            var running: UInt16 = 0
            for block in 0..<blocks { output += littleEndianBytes(running); running &+= UInt16(validCount(bitmap, block)) }
        } else if keys.count > 24 {
            var running: UInt8 = 0
            for block in 0..<blocks { output.append(running); running &+= UInt8(validCount(bitmap, block)) }
        }
        let owned = ProtoCacheBytes(copying: output)
        let positions = owned.withBorrowedSpan { bytes in
            let view = PerfectHashView(bytes)
            return keys.map { key in key.withUnsafeBytes { view.locate($0)! } }
        }
        return (output, positions)
    }

    private static func peel(_ edges: [Edge], vertexCount: Int) -> [Int]? {
        var adjacency = [[Int]](repeating: [], count: vertexCount)
        for (index, edge) in edges.enumerated() { for slot in edge.slots { adjacency[slot].append(index) } }
        var degrees = adjacency.map(\.count)
        var removed = [Bool](repeating: false, count: edges.count)
        var queue = degrees.indices.filter { degrees[$0] == 1 }
        var head = 0
        var order: [Int] = []
        while head < queue.count {
            let vertex = queue[head]; head += 1
            guard degrees[vertex] == 1, let edgeIndex = adjacency[vertex].first(where: { !removed[$0] }) else { continue }
            removed[edgeIndex] = true; order.append(edgeIndex)
            for slot in edges[edgeIndex].slots {
                degrees[slot] -= 1
                if degrees[slot] == 1 { queue.append(slot) }
            }
        }
        return order.count == edges.count ? order : nil
    }

    private static func setBit2(_ bitmap: inout [UInt8], _ position: Int, _ value: UInt8) {
        let index = position >> 2, shift = (position & 3) * 2
        bitmap[index] = (bitmap[index] & ~(3 << shift)) | ((value & 3) << shift)
    }
    private static func getBit2(_ bitmap: [UInt8], _ position: Int) -> UInt8 { (bitmap[position >> 2] >> ((position & 3) * 2)) & 3 }
    private static func validCount(_ bitmap: [UInt8], _ block: Int) -> Int {
        bitmap.withUnsafeBytes { raw in
            let word = UInt64(littleEndian: raw.baseAddress!.loadUnaligned(fromByteOffset: block * 8, as: UInt64.self))
            return 32 - ((word & 0x5555_5555_5555_5555) & (word >> 1)).nonzeroBitCount
        }
    }
    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var copy = value.littleEndian
        return Swift.withUnsafeBytes(of: &copy) { Array($0) }
    }
}
