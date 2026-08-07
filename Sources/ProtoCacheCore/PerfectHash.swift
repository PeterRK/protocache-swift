import Synchronization

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
        let code = Hash.hash128(key, seed: seed)
        let slot0 = Int(code.0) % section
        let slot1 = Int(code.1) % section + section
        let slot2 = Int(code.2) % section + section * 2
        return locate(slot0, slot1, slot2)
    }

    fileprivate func locate(_ slot0: Int, _ slot1: Int, _ slot2: Int) -> Int {
        let sum = bit2(slot0) + bit2(slot1) + bit2(slot2)
        let slot = switch sum % 3 {
        case 0: slot0
        case 1: slot1
        default: slot2
        }
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
    private struct SeedSequence {
        private var state0: UInt32 = 0x6c07_8965
        private var state1: UInt32 = 0x9908_b0df
        private var state2: UInt32 = 0x9d2c_5680
        private var state3: UInt32

        init(_ seed: UInt32) { state3 = seed }

        mutating func next() -> UInt32 {
            let value = state0 ^ (state0 << 11)
            state0 = state1
            state1 = state2
            state2 = state3
            state3 ^= (state3 >> 19) ^ value ^ (value >> 8)
            return state3
        }
    }

    private static let seedCounter = Atomic<UInt32>(
        UInt32.random(in: UInt32.min...UInt32.max)
    )

    private static func nextSeed() -> UInt32 {
        seedCounter.wrappingAdd(1, ordering: .relaxed).oldValue
    }

    struct Edge {
        let slot0: Int
        let slot1: Int
        let slot2: Int
    }

    struct PeelOrder {
        let scratch: [Int]
        let start: Int
        let count: Int
    }

    static func section(for count: Int) -> Int { max(10, (count * 105 + 255) / 256) }
    static func bitmapSize(section: Int) -> Int { ((section * 3 + 31) & ~31) / 4 }
    static func attemptLimit(for count: Int) -> Int { count <= Int(UInt8.max) ? 40 : 16 }

    public static func build(_ keys: [[UInt8]]) throws -> (index: [UInt8], positions: [Int]) {
        try build(keys, initialSeed: nextSeed())
    }

    static func build(
        _ keys: [[UInt8]], initialSeed: UInt32
    ) throws -> (index: [UInt8], positions: [Int]) {
        guard keys.count < 1 << 28 else { throw ProtoCacheError.integerOverflow }
        if keys.count <= 16 {
            for index in keys.indices {
                for previous in keys.indices where previous < index {
                    if keys[index] == keys[previous] { throw ProtoCacheError.duplicateMapKey }
                }
            }
        } else {
            var unique = Set<[UInt8]>()
            unique.reserveCapacity(keys.count)
            for key in keys where !unique.insert(key).inserted {
                throw ProtoCacheError.duplicateMapKey
            }
        }
        return try buildUnique(count: keys.count, initialSeed: initialSeed) { keys[$0] }
    }

    private static func buildUnique(
        count: Int,
        initialSeed: UInt32 = nextSeed(),
        keyAt: (Int) -> [UInt8]
    ) throws -> (index: [UInt8], positions: [Int]) {
        if count <= 1 {
            var output = [UInt8](repeating: 0, count: 4)
            output.withUnsafeMutableBytes {
                $0.baseAddress!.storeBytes(of: UInt32(count).littleEndian, as: UInt32.self)
            }
            return (output, count == 0 ? [] : [0])
        }
        if count <= 16 {
            return try buildSmall(count: count, initialSeed: initialSeed, keyAt: keyAt)
        }
        let section = section(for: count)
        let vertexCount = section * 3
        var seeds = SeedSequence(initialSeed)
        var result: (seed: UInt32, edges: [Edge], order: PeelOrder)?
        for _ in 0..<attemptLimit(for: count) {
            let seed = seeds.next()
            let edges = (0..<count).map { index -> Edge in
                let code = Hash.hash128(keyAt(index), seed: UInt64(seed))
                return Edge(
                    slot0: Int(code.0) % section,
                    slot1: Int(code.1) % section + section,
                    slot2: Int(code.2) % section + section * 2
                )
            }
            if let order = peel(edges, vertexCount: vertexCount) {
                result = (seed, edges, order)
                break
            }
        }
        guard let result else { throw ProtoCacheError.perfectHashBuildFailed }

        let bitmapSize = bitmapSize(section: section)
        var bitmap = [UInt8](repeating: 0xff, count: bitmapSize)
        var taken = [Bool](repeating: false, count: vertexCount)
        let order = result.order
        for orderIndex in stride(from: order.count - 1, through: 0, by: -1) {
            let edgeIndex = order.scratch[order.start + orderIndex]
            let edge = result.edges[edgeIndex]
            let chosen: Int
            let other0: Int
            let other1: Int
            let target: UInt8
            if !taken[edge.slot0] {
                chosen = edge.slot0
                other0 = edge.slot1
                other1 = edge.slot2
                target = 0
                taken[edge.slot0] = true
                taken[edge.slot1] = true
                taken[edge.slot2] = true
            } else if !taken[edge.slot1] {
                chosen = edge.slot1
                other0 = edge.slot0
                other1 = edge.slot2
                target = 1
                taken[edge.slot1] = true
                taken[edge.slot2] = true
            } else {
                chosen = edge.slot2
                other0 = edge.slot0
                other1 = edge.slot1
                target = 2
                taken[edge.slot2] = true
            }
            let sum = Int(getBit2(bitmap, other0)) + Int(getBit2(bitmap, other1))
            setBit2(&bitmap, chosen, UInt8((Int(target) - sum % 3 + 3) % 3))
        }

        let blocks = bitmapSize / 8
        let tableWidth = count > 65_535 ? 4 : count > 255 ? 2 : count > 24 ? 1 : 0
        var output = [UInt8](repeating: 0, count: 8 + bitmapSize + blocks * tableWidth)
        output.withUnsafeMutableBytes { raw in
            raw.baseAddress!.storeBytes(of: UInt32(count).littleEndian, as: UInt32.self)
            raw.baseAddress!.advanced(by: 4).storeBytes(
                of: result.seed.littleEndian, as: UInt32.self
            )
            bitmap.withUnsafeBytes {
                raw.baseAddress!.advanced(by: 8).copyMemory(
                    from: $0.baseAddress!,
                    byteCount: bitmapSize
                )
            }
            let tableOffset = 8 + bitmapSize
            if tableWidth == 4 {
                var running: UInt32 = 0
                for block in 0..<blocks {
                    raw.baseAddress!.advanced(by: tableOffset + block * 4).storeBytes(
                        of: running.littleEndian,
                        as: UInt32.self
                    )
                    running &+= UInt32(validCount(bitmap, block))
                }
            } else if tableWidth == 2 {
                var running: UInt16 = 0
                for block in 0..<blocks {
                    raw.baseAddress!.advanced(by: tableOffset + block * 2).storeBytes(
                        of: running.littleEndian,
                        as: UInt16.self
                    )
                    running &+= UInt16(validCount(bitmap, block))
                }
            } else if tableWidth == 1 {
                var running: UInt8 = 0
                for block in 0..<blocks {
                    raw[tableOffset + block] = running
                    running &+= UInt8(validCount(bitmap, block))
                }
            }
        }
        let positions = output.withUnsafeBytes { raw in
            let bytes = Span(unsafeBorrowing: raw)
            let view = PerfectHashView(bytes)
            return result.edges.map { edge in
                view.locate(edge.slot0, edge.slot1, edge.slot2)
            }
        }
        return (output, positions)
    }

    static func buildEntries(
        _ entries: UnsafeMutableBufferPointer<_ProtoCacheMapEntry>
    ) throws -> (index: [UInt8], positions: [Int]) {
        guard entries.count < 1 << 28 else { throw ProtoCacheError.integerOverflow }
        if entries.count > 1 {
            for index in 1..<entries.count {
                if entries[index].key == entries[index - 1].key {
                    throw ProtoCacheError.duplicateMapKey
                }
            }
        }
        if entries.count > 16 {
            return try buildUnique(count: entries.count) { entries[$0].key }
        }
        if entries.count <= 1 {
            var output = [UInt8](repeating: 0, count: 4)
            output.withUnsafeMutableBytes {
                $0.baseAddress!.storeBytes(of: UInt32(entries.count).littleEndian, as: UInt32.self)
            }
            return (output, entries.isEmpty ? [] : [0])
        }
        return try buildSmall(count: entries.count) { entries[$0].key }
    }

    static func buildSmallEntries(
        _ entries: UnsafeMutableBufferPointer<_ProtoCacheMapEntry>,
        index: UnsafeMutableBufferPointer<UInt8>,
        positions: UnsafeMutableBufferPointer<Int>
    ) throws -> Int {
        precondition(entries.count <= 16 && positions.count == entries.count)
        if entries.count > 1 {
            for index in 1..<entries.count {
                if entries[index].key == entries[index - 1].key {
                    throw ProtoCacheError.duplicateMapKey
                }
            }
        }
        if entries.count <= 1 {
            precondition(index.count >= 4)
            UnsafeMutableRawPointer(index.baseAddress!).storeBytes(
                of: UInt32(entries.count).littleEndian, as: UInt32.self
            )
            if !entries.isEmpty { positions[0] = 0 }
            return 4
        }
        return try fillSmallIndex(
            count: entries.count, keyAt: { entries[$0].key },
            index: index, positions: positions
        )
    }

    private static func buildSmall(
        count edgeCount: Int,
        initialSeed: UInt32 = nextSeed(),
        keyAt: (Int) -> [UInt8]
    ) throws -> (index: [UInt8], positions: [Int]) {
        var positions = [Int](repeating: 0, count: edgeCount)
        var index = [UInt8](repeating: 0, count: 24)
        let count = try positions.withUnsafeMutableBufferPointer { positions in
            try index.withUnsafeMutableBufferPointer { index in
                try fillSmallIndex(
                    count: edgeCount, keyAt: keyAt, index: index,
                    positions: positions, initialSeed: initialSeed
                )
            }
        }
        if count < index.count { index.removeLast(index.count - count) }
        return (index, positions)
    }

    private static func fillSmallIndex(
        count edgeCount: Int,
        keyAt: (Int) -> [UInt8],
        index: UnsafeMutableBufferPointer<UInt8>,
        positions: UnsafeMutableBufferPointer<Int>,
        initialSeed: UInt32 = nextSeed()
    ) throws -> Int {
        precondition(positions.count == edgeCount)
        let section = 10
        let vertexCount = section * 3
        let headsStart = 0
        let previousStart = headsStart + vertexCount
        let nextStart = previousStart + edgeCount * 3
        let queueStart = nextStart + edgeCount * 3
        let orderStart = queueStart + edgeCount
        let bookedStart = orderStart + edgeCount
        let takenStart = bookedStart + edgeCount
        let bitmapStart = takenStart + vertexCount
        let bitmapSize = bitmapSize(section: section)
        let scratchCount = bitmapStart + bitmapSize

        return try withUnsafeTemporaryAllocation(of: Edge.self, capacity: edgeCount) { edges in
            edges.initialize(repeating: Edge(slot0: 0, slot1: 0, slot2: 0))
            defer { edges.deinitialize() }
            return try withUnsafeTemporaryAllocation(of: Int.self, capacity: scratchCount) { scratch in
                scratch.initialize(repeating: 0)
                defer { scratch.deinitialize() }
                var seeds = SeedSequence(initialSeed)
                var seed: UInt32 = 0
                var built = false
                for _ in 0..<attemptLimit(for: edgeCount) {
                    seed = seeds.next()
                    for index in scratch.indices { scratch[index] = 0 }
                    for index in 0..<edgeCount {
                        let code = Hash.hash128(keyAt(index), seed: UInt64(seed))
                        edges[index] = Edge(
                            slot0: Int(code.0) % section,
                            slot1: Int(code.1) % section + section,
                            slot2: Int(code.2) % section + section * 2
                        )
                    }
                    if peelSmall(
                        edges: UnsafeBufferPointer(edges),
                        scratch: scratch,
                        headsStart: headsStart,
                        previousStart: previousStart,
                        nextStart: nextStart,
                        queueStart: queueStart,
                        orderStart: orderStart,
                        bookedStart: bookedStart,
                        vertexCount: vertexCount
                    ) {
                        built = true
                        break
                    }
                }
                guard built else { throw ProtoCacheError.perfectHashBuildFailed }

                for index in 0..<bitmapSize { scratch[bitmapStart + index] = 0xff }
                for orderIndex in stride(from: edgeCount - 1, through: 0, by: -1) {
                    let edge = edges[scratch[orderStart + orderIndex]]
                    let chosen: Int
                    let other0: Int
                    let other1: Int
                    let target: Int
                    if scratch[takenStart + edge.slot0] == 0 {
                        chosen = edge.slot0; other0 = edge.slot1; other1 = edge.slot2; target = 0
                        scratch[takenStart + edge.slot0] = 1
                        scratch[takenStart + edge.slot1] = 1
                        scratch[takenStart + edge.slot2] = 1
                    } else if scratch[takenStart + edge.slot1] == 0 {
                        chosen = edge.slot1; other0 = edge.slot0; other1 = edge.slot2; target = 1
                        scratch[takenStart + edge.slot1] = 1
                        scratch[takenStart + edge.slot2] = 1
                    } else {
                        chosen = edge.slot2; other0 = edge.slot0; other1 = edge.slot1; target = 2
                        scratch[takenStart + edge.slot2] = 1
                    }
                    let sum = smallBit2(scratch, bitmapStart: bitmapStart, position: other0)
                        + smallBit2(scratch, bitmapStart: bitmapStart, position: other1)
                    setSmallBit2(
                        scratch,
                        bitmapStart: bitmapStart,
                        position: chosen,
                        value: (target - sum % 3 + 3) % 3
                    )
                }

                let indexCount = 8 + bitmapSize
                precondition(index.count >= indexCount)
                let raw = UnsafeMutableRawBufferPointer(
                    start: index.baseAddress!, count: indexCount
                )
                raw.baseAddress!.storeBytes(of: UInt32(edgeCount).littleEndian, as: UInt32.self)
                raw.baseAddress!.advanced(by: 4).storeBytes(of: seed.littleEndian, as: UInt32.self)
                for position in 0..<bitmapSize {
                    raw[8 + position] = UInt8(scratch[bitmapStart + position])
                }
                var bitmapWord: UInt64 = 0
                for byte in 0..<bitmapSize {
                    bitmapWord |= UInt64(scratch[bitmapStart + byte]) << UInt64(byte * 8)
                }
                for position in 0..<edgeCount {
                    let edge = edges[position]
                    let sum = smallBit2(scratch, bitmapStart: bitmapStart, position: edge.slot0)
                        + smallBit2(scratch, bitmapStart: bitmapStart, position: edge.slot1)
                        + smallBit2(scratch, bitmapStart: bitmapStart, position: edge.slot2)
                    let slot = switch sum % 3 {
                    case 0: edge.slot0
                    case 1: edge.slot1
                    default: edge.slot2
                    }
                    let bit = slot & 31
                    let masked = bitmapWord | (UInt64.max << UInt64(bit * 2))
                    let invalid = (
                        (masked & 0x5555_5555_5555_5555) & (masked >> 1)
                    ).nonzeroBitCount
                    positions[position] = 32 - invalid
                }
                return indexCount
            }
        }
    }

    private static func peelSmall(
        edges: UnsafeBufferPointer<Edge>,
        scratch: UnsafeMutableBufferPointer<Int>,
        headsStart: Int,
        previousStart: Int,
        nextStart: Int,
        queueStart: Int,
        orderStart: Int,
        bookedStart: Int,
        vertexCount: Int
    ) -> Bool {
        let none = -1
        for vertex in 0..<vertexCount { scratch[headsStart + vertex] = none }
        for (edgeIndex, edge) in edges.enumerated() {
            let slots = (edge.slot0, edge.slot1, edge.slot2)
            for slotIndex in 0..<3 {
                let slot = switch slotIndex {
                case 0: slots.0
                case 1: slots.1
                default: slots.2
                }
                let node = edgeIndex * 3 + slotIndex
                let head = scratch[headsStart + slot]
                scratch[previousStart + node] = none
                scratch[nextStart + node] = head
                if head != none { scratch[previousStart + head] = node }
                scratch[headsStart + slot] = node
            }
        }
        var queueCount = 0
        for edgeIndex in edges.indices {
            let node = edgeIndex * 3
            let isFree = (scratch[previousStart + node] == none
                    && scratch[nextStart + node] == none)
                || (scratch[previousStart + node + 1] == none
                    && scratch[nextStart + node + 1] == none)
                || (scratch[previousStart + node + 2] == none
                    && scratch[nextStart + node + 2] == none)
            if isFree {
                scratch[bookedStart + edgeIndex] = 1
                scratch[queueStart + queueCount] = edgeIndex
                queueCount += 1
            }
        }
        var head = 0
        var orderCount = 0
        while head < queueCount {
            let edgeIndex = scratch[queueStart + head]
            head += 1
            scratch[orderStart + orderCount] = edgeIndex
            orderCount += 1
            let edge = edges[edgeIndex]
            let slots = (edge.slot0, edge.slot1, edge.slot2)
            for slotIndex in 0..<3 {
                let slot = switch slotIndex {
                case 0: slots.0
                case 1: slots.1
                default: slots.2
                }
                let node = edgeIndex * 3 + slotIndex
                let previous = scratch[previousStart + node]
                let next = scratch[nextStart + node]
                if previous == none {
                    scratch[headsStart + slot] = next
                } else {
                    scratch[nextStart + previous] = next
                }
                if next != none { scratch[previousStart + next] = previous }

                let newHead = scratch[headsStart + slot]
                if newHead != none, scratch[nextStart + newHead] == none {
                    let candidate = newHead / 3
                    if scratch[bookedStart + candidate] == 0 {
                        scratch[bookedStart + candidate] = 1
                        scratch[queueStart + queueCount] = candidate
                        queueCount += 1
                    }
                }
            }
        }
        return orderCount == edges.count
    }

    private static func smallBit2(
        _ scratch: UnsafeMutableBufferPointer<Int>, bitmapStart: Int, position: Int
    ) -> Int {
        (scratch[bitmapStart + (position >> 2)] >> ((position & 3) * 2)) & 3
    }

    private static func setSmallBit2(
        _ scratch: UnsafeMutableBufferPointer<Int>, bitmapStart: Int, position: Int, value: Int
    ) {
        let index = bitmapStart + (position >> 2)
        let shift = (position & 3) * 2
        scratch[index] = (scratch[index] & ~(3 << shift)) | ((value & 3) << shift)
    }

    private static func peel(_ edges: [Edge], vertexCount: Int) -> PeelOrder? {
        let degreesStart = 0
        let offsetsStart = degreesStart + vertexCount
        let cursorsStart = offsetsStart + vertexCount + 1
        let adjacencyStart = cursorsStart + vertexCount + 1
        let queueStart = adjacencyStart + edges.count * 3
        let orderStart = queueStart + vertexCount
        let removedStart = orderStart + edges.count
        var scratch = [Int](repeating: 0, count: removedStart + edges.count)
        for edge in edges {
            scratch[degreesStart + edge.slot0] += 1
            scratch[degreesStart + edge.slot1] += 1
            scratch[degreesStart + edge.slot2] += 1
        }
        for vertex in 0..<vertexCount {
            let offset = scratch[offsetsStart + vertex]
            scratch[offsetsStart + vertex + 1] = offset + scratch[degreesStart + vertex]
            scratch[cursorsStart + vertex] = offset
        }
        scratch[cursorsStart + vertexCount] = edges.count * 3
        for (index, edge) in edges.enumerated() {
            let cursor0 = cursorsStart + edge.slot0
            scratch[adjacencyStart + scratch[cursor0]] = index
            scratch[cursor0] += 1
            let cursor1 = cursorsStart + edge.slot1
            scratch[adjacencyStart + scratch[cursor1]] = index
            scratch[cursor1] += 1
            let cursor2 = cursorsStart + edge.slot2
            scratch[adjacencyStart + scratch[cursor2]] = index
            scratch[cursor2] += 1
        }
        var queueCount = 0
        for vertex in 0..<vertexCount where scratch[degreesStart + vertex] == 1 {
            scratch[queueStart + queueCount] = vertex
            queueCount += 1
        }
        var head = 0
        var orderCount = 0
        while head < queueCount {
            let vertex = scratch[queueStart + head]
            head += 1
            guard scratch[degreesStart + vertex] == 1 else { continue }
            var edgeIndex: Int?
            let begin = scratch[offsetsStart + vertex]
            let end = scratch[offsetsStart + vertex + 1]
            for offset in begin..<end
            where scratch[removedStart + scratch[adjacencyStart + offset]] == 0 {
                edgeIndex = scratch[adjacencyStart + offset]
                break
            }
            guard let edgeIndex else { continue }
            scratch[removedStart + edgeIndex] = 1
            scratch[orderStart + orderCount] = edgeIndex
            orderCount += 1
            let edge = edges[edgeIndex]
            let degree0 = degreesStart + edge.slot0
            scratch[degree0] -= 1
            if scratch[degree0] == 1 {
                scratch[queueStart + queueCount] = edge.slot0
                queueCount += 1
            }
            let degree1 = degreesStart + edge.slot1
            scratch[degree1] -= 1
            if scratch[degree1] == 1 {
                scratch[queueStart + queueCount] = edge.slot1
                queueCount += 1
            }
            let degree2 = degreesStart + edge.slot2
            scratch[degree2] -= 1
            if scratch[degree2] == 1 {
                scratch[queueStart + queueCount] = edge.slot2
                queueCount += 1
            }
        }
        guard orderCount == edges.count else { return nil }
        return PeelOrder(scratch: scratch, start: orderStart, count: orderCount)
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
}
