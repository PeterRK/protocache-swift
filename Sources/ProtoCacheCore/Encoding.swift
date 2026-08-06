public struct _ProtoCacheSegment: Sendable {
    public var position: Int
    public var count: Int
    public var end: Int { position - count }
}

public struct _ProtoCacheUnit: Sendable {
    var inlineCount: Int
    var word0: UInt32
    var word1: UInt32
    var word2: UInt32
    var segment: _ProtoCacheSegment

    public static var empty: Self { Self(inline: []) }

    public init(inline words: [UInt32]) {
        precondition(words.count <= 3)
        inlineCount = words.count
        word0 = words.indices.contains(0) ? words[0] : 0
        word1 = words.indices.contains(1) ? words[1] : 0
        word2 = words.indices.contains(2) ? words[2] : 0
        segment = .init(position: 0, count: 0)
    }

    init(segment: _ProtoCacheSegment) {
        inlineCount = 0; word0 = 0; word1 = 0; word2 = 0; self.segment = segment
    }

    public var count: Int { inlineCount == 0 ? segment.count : inlineCount }
    public var isEmpty: Bool { count == 0 }
    var isSegment: Bool { inlineCount == 0 && segment.count != 0 }
    func inlineWord(_ index: Int) -> UInt32 {
        switch index { case 0: word0; case 1: word1; default: word2 }
    }
}

public final class _ProtoCacheBuffer {
    private var pointer: UnsafeMutablePointer<UInt32>?
    private var capacity: Int
    private var start: Int

    public init(minimumCapacityWords: Int = 64) {
        capacity = max(8, minimumCapacityWords)
        pointer = .allocate(capacity: capacity)
        pointer!.initialize(repeating: 0, count: capacity)
        start = capacity
    }

    deinit { pointer?.deallocate() }
    public var count: Int { capacity - start }
    public var checkpoint: Int { count }

    public func clear() { start = capacity }

    func expand(_ words: Int) -> UnsafeMutableBufferPointer<UInt32> {
        precondition(words >= 0)
        if start < words { grow(minimum: count + words) }
        start -= words
        let buffer = UnsafeMutableBufferPointer(start: pointer!.advanced(by: start), count: words)
        buffer.initialize(repeating: 0)
        return buffer
    }

    func shrink(_ words: Int) {
        precondition(words >= 0 && words <= count)
        start += words
    }

    func put(_ word: UInt32) { expand(1)[0] = word }

    func put(_ words: [UInt32]) {
        let destination = expand(words.count)
        for index in words.indices { destination[index] = words[index] }
    }

    func activeWord(_ index: Int) -> UInt32 {
        precondition(index >= 0 && index < count)
        return pointer![start + index]
    }

    func unitWords(_ unit: _ProtoCacheUnit) -> [UInt32]? {
        if unit.inlineCount > 0 { return (0..<unit.inlineCount).map(unit.inlineWord) }
        if unit.segment.count == 0 { return [] }
        let offset = count - unit.segment.position
        guard offset >= 0 && offset + unit.segment.count <= count else { return nil }
        return (0..<unit.segment.count).map { activeWord(offset + $0) }
    }

    public func finish(_ root: _ProtoCacheUnit) throws -> ProtoCacheBytes {
        if root.inlineCount > 0 { put((0..<root.inlineCount).map(root.inlineWord)) }
        guard root.count > 0 else { throw ProtoCacheError.invalidHeader }
        let base = pointer!
        let byteOffset = start * 4
        let byteCount = count * 4
        let storage = ProtoCacheStorage(
            baseAddress: UnsafeRawPointer(base),
            mutableBaseAddress: UnsafeMutableRawPointer(base),
            byteCount: capacity * 4,
            deallocator: { pointer, _ in pointer.deallocate() }
        )
        pointer = nil
        return ProtoCacheBytes(storage: storage, byteOffset: byteOffset, count: byteCount)
    }

    private func grow(minimum: Int) {
        var newCapacity = capacity
        while newCapacity < minimum { newCapacity = newCapacity.multipliedReportingOverflow(by: 2).overflow ? minimum : newCapacity * 2 }
        let replacement = UnsafeMutablePointer<UInt32>.allocate(capacity: newCapacity)
        replacement.initialize(repeating: 0, count: newCapacity)
        let active = count
        replacement.advanced(by: newCapacity - active).update(from: pointer!.advanced(by: start), count: active)
        pointer!.deallocate()
        pointer = replacement
        capacity = newCapacity
        start = newCapacity - active
    }
}

public enum _ProtoCacheEncoding {
    @inline(__always) static func offset(_ words: Int) -> UInt32 { (UInt32(words) << 2) | 3 }

    public static func scalar<T: ProtoCacheScalar>(_ value: T) -> _ProtoCacheUnit {
        let words = value._encodeProtoCacheWords()
        return _ProtoCacheUnit(inline: T._protoCacheWordWidth == 1 ? [words.0] : [words.0, words.1])
    }

    public static func bytes(_ source: UnsafeRawBufferPointer, in buffer: _ProtoCacheBuffer) throws -> _ProtoCacheUnit {
        guard source.count < 1 << 30 else { throw ProtoCacheError.integerOverflow }
        var value = UInt32(source.count) << 2
        var header: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f); value >>= 7
            if value != 0 { byte |= 0x80 }
            header.append(byte)
        } while value != 0
        let wordCount = (header.count + source.count + 3) / 4
        if wordCount == 1 {
            var word: UInt32 = 0
            withUnsafeMutableBytes(of: &word) { destination in
                for index in header.indices { destination[index] = header[index] }
                for index in 0..<source.count { destination[header.count + index] = source[index] }
            }
            return _ProtoCacheUnit(inline: [UInt32(littleEndian: word)])
        }
        let previous = buffer.count
        let words = buffer.expand(wordCount)
        let raw = UnsafeMutableRawBufferPointer(start: words.baseAddress, count: wordCount * 4)
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        for index in header.indices { raw[index] = header[index] }
        for index in 0..<source.count { raw[header.count + index] = source[index] }
        return _ProtoCacheUnit(segment: .init(position: buffer.count, count: buffer.count - previous))
    }

    public static func string(_ value: String, in buffer: _ProtoCacheBuffer) throws -> _ProtoCacheUnit {
        try value.utf8.withContiguousStorageIfAvailable { storage in
            try bytes(UnsafeRawBufferPointer(storage), in: buffer)
        } ?? Array(value.utf8).withUnsafeBytes { try bytes($0, in: buffer) }
    }

    public static func copy(
        _ field: FieldView,
        kind: _ProtoCacheFieldKind,
        in buffer: _ProtoCacheBuffer
    ) throws -> _ProtoCacheUnit {
        let raw = field.rawBytes
        switch kind {
        case .scalar, .enumeration:
            return _ProtoCacheUnit(inline: (0..<field.width).map { raw.loadUInt32(wordOffset: $0) })
        default:
            break
        }
        guard raw.loadUInt32(wordOffset: 0) & 3 == 3 else {
            return _ProtoCacheUnit(inline: (0..<field.width).map { raw.loadUInt32(wordOffset: $0) })
        }
        let source = field.objectBytes
        let words = try encodedWordCount(source, kind: kind, depth: 0)
        return try embedded(source.slice(byteOffset: 0, count: words * 4), in: buffer)
    }

    private static func encodedWordCount(
        _ bytes: ProtoCacheBytes,
        kind: _ProtoCacheFieldKind,
        depth: Int
    ) throws -> Int {
        guard depth <= 100, bytes.count >= 4 else { throw ProtoCacheError.invalidHeader }
        switch kind {
        case .scalar(let scalar):
            switch scalar {
            case .int64, .uint64, .double: return 2
            default: return 1
            }
        case .enumeration:
            return 1
        case .string, .bytes:
            return try stringWordCount(bytes)
        case .message(let nested):
            let layout = nested()
            if layout.isAlias {
                guard let field = layout.fields.first(where: { $0.number == 1 }) else {
                    throw ProtoCacheError.invalidHeader
                }
                return try encodedWordCount(bytes, kind: field.kind, depth: depth + 1)
            }
            return try messageWordCount(bytes, layout: layout, depth: depth + 1)
        case .array(let element):
            return try arrayWordCount(bytes, element: element(), depth: depth + 1)
        case .map(let key, let value):
            return try mapWordCount(bytes, key: key(), value: value(), depth: depth + 1)
        }
    }

    private static func stringWordCount(_ bytes: ProtoCacheBytes) throws -> Int {
        var mark = 0
        var shift = 0
        var used = 0
        var terminated = false
        while shift < 35, used < bytes.count {
            let byte = bytes.loadUInt8(at: used)
            used += 1
            mark |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                terminated = true
                break
            }
            shift += 7
        }
        guard terminated, mark & 3 == 0 else { throw ProtoCacheError.invalidHeader }
        let length = mark >> 2
        guard used + length <= bytes.count else { throw ProtoCacheError.invalidHeader }
        return (used + length + 3) / 4
    }

    private static func messageWordCount(
        _ bytes: ProtoCacheBytes,
        layout: _ProtoCacheLayout,
        depth: Int
    ) throws -> Int {
        let head = bytes.loadUInt32(wordOffset: 0)
        let sectionCount = Int(head & 0xff)
        let headWords = 1 + sectionCount * 2
        guard headWords <= bytes.count / 4 else { throw ProtoCacheError.invalidHeader }

        var bodyWords = 0
        for index in 0..<12 {
            bodyWords += Int((head >> UInt32(8 + index * 2)) & 3)
        }
        for section in 0..<sectionCount {
            let vector = bytes.loadUInt64(wordOffset: 1 + section * 2)
            for index in 0..<25 {
                bodyWords += Int((vector >> UInt64(index * 2)) & 3)
            }
        }

        var total = headWords + bodyWords
        guard total <= bytes.count / 4 else { throw ProtoCacheError.invalidHeader }
        let view = MessageView(bytes)
        for layoutField in layout.fields {
            guard let field = view.field(layoutField.number - 1) else { continue }
            total = max(total, try referencedEnd(
                field,
                in: bytes,
                kind: layoutField.kind,
                depth: depth
            ))
        }
        return total
    }

    private static func arrayWordCount(
        _ bytes: ProtoCacheBytes,
        element: _ProtoCacheFieldKind,
        depth: Int
    ) throws -> Int {
        let head = bytes.loadUInt32(wordOffset: 0)
        let count = Int(head >> 2)
        let width = Int(head & 3)
        guard width > 0 else { throw ProtoCacheError.invalidHeader }
        var total = 1 + count * width
        guard total <= bytes.count / 4 else { throw ProtoCacheError.invalidHeader }
        for index in 0..<count {
            let field = FieldView(tail: bytes.wordSlice(offset: 1 + index * width), width: width)
            total = max(total, try referencedEnd(field, in: bytes, kind: element, depth: depth))
        }
        return total
    }

    private static func mapWordCount(
        _ bytes: ProtoCacheBytes,
        key: _ProtoCacheFieldKind,
        value: _ProtoCacheFieldKind,
        depth: Int
    ) throws -> Int {
        let head = bytes.loadUInt32(wordOffset: 0)
        let count = Int(head & 0x0fff_ffff)
        let keyWidth = Int((head >> 30) & 3)
        let valueWidth = Int((head >> 28) & 3)
        guard keyWidth > 0, valueWidth > 0 else { throw ProtoCacheError.invalidHeader }
        let indexWords = (PerfectHashView(bytes).byteCount + 3) / 4
        let pairWidth = keyWidth + valueWidth
        var total = indexWords + count * pairWidth
        guard total <= bytes.count / 4 else { throw ProtoCacheError.invalidHeader }
        for index in 0..<count {
            let pairStart = indexWords + index * pairWidth
            let keyField = FieldView(tail: bytes.wordSlice(offset: pairStart), width: keyWidth)
            let valueField = FieldView(
                tail: bytes.wordSlice(offset: pairStart + keyWidth),
                width: valueWidth
            )
            total = max(total, try referencedEnd(keyField, in: bytes, kind: key, depth: depth))
            total = max(total, try referencedEnd(valueField, in: bytes, kind: value, depth: depth))
        }
        return total
    }

    private static func referencedEnd(
        _ field: FieldView,
        in root: ProtoCacheBytes,
        kind: _ProtoCacheFieldKind,
        depth: Int
    ) throws -> Int {
        switch kind {
        case .scalar, .enumeration:
            return 0
        default:
            break
        }
        let first = field.rawBytes.loadUInt32(wordOffset: 0)
        guard first & 3 == 3 else { return 0 }
        let cell = (field.tail.byteOffset - root.byteOffset) / 4
        let object = cell + Int(first >> 2)
        guard object >= 0, object < root.count / 4 else { throw ProtoCacheError.invalidHeader }
        let child = root.wordSlice(offset: object)
        return object + (try encodedWordCount(child, kind: kind, depth: depth + 1))
    }

    public static func embedded(_ source: ProtoCacheBytes, in buffer: _ProtoCacheBuffer) throws -> _ProtoCacheUnit {
        guard source.count > 0, source.count % 4 == 0 else { throw ProtoCacheError.invalidHeader }
        let previous = buffer.count
        let wordCount = source.count / 4
        let destination = buffer.expand(wordCount)
        source.withUnsafeBytes { raw in
            for index in 0..<wordCount {
                destination[index] = UInt32(littleEndian: raw.baseAddress!.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
            }
        }
        return _ProtoCacheUnit(segment: .init(position: buffer.count, count: buffer.count - previous))
    }

    public static func boolArray(_ values: [Bool], in buffer: _ProtoCacheBuffer) throws -> _ProtoCacheUnit {
        let raw = values.map { UInt8($0 ? 1 : 0) }
        return try raw.withUnsafeBytes { try bytes($0, in: buffer) }
    }

    public static func byteArray(_ values: [UInt8], in buffer: _ProtoCacheBuffer) throws -> _ProtoCacheUnit {
        try values.withUnsafeBytes { try bytes($0, in: buffer) }
    }

    public static func fold(_ unit: inout _ProtoCacheUnit, in buffer: _ProtoCacheBuffer) {
        guard unit.isSegment, unit.segment.count < 4, unit.segment.position == buffer.count else { return }
        let words = (0..<unit.segment.count).map { buffer.activeWord($0) }
        unit = _ProtoCacheUnit(inline: words)
        buffer.shrink(words.count)
    }

    public static func message(_ fields: inout [_ProtoCacheUnit], in buffer: _ProtoCacheBuffer, since checkpoint: Int? = nil) throws -> _ProtoCacheUnit {
        guard !fields.isEmpty else { throw ProtoCacheError.invalidSchema("empty message") }
        let last = checkpoint ?? buffer.count
        let usedCount = (fields.lastIndex(where: { !$0.isEmpty }) ?? -1) + 1
        if usedCount == 0 {
            let before = buffer.count; buffer.put(0)
            return _ProtoCacheUnit(segment: .init(position: buffer.count, count: buffer.count - before))
        }
        fields.removeSubrange(usedCount..<fields.count)
        var bodyCount = 0
        for field in fields { bodyCount += field.inlineCount > 0 ? field.inlineCount : field.isSegment ? 1 : 0 }
        let sections = (fields.count + 12) / 25
        guard sections <= 255 else { throw ProtoCacheError.integerOverflow }
        let headCount = 1 + sections * 2
        let currentCount = buffer.count
        let totalCount = currentCount + headCount + bodyCount
        let block = buffer.expand(headCount + bodyCount)
        var bodyIndex = headCount
        var position = totalCount - headCount
        var consumed: UInt32 = 0
        block[0] = UInt32(sections)

        func write(_ field: _ProtoCacheUnit, markIndex: Int, shift: Int, extended: Bool) {
            if field.inlineCount > 0 {
                if extended {
                    var mark = UInt64(block[markIndex]) | UInt64(block[markIndex + 1]) << 32
                    mark |= UInt64(field.inlineCount) << UInt64(shift)
                    block[markIndex] = UInt32(truncatingIfNeeded: mark); block[markIndex + 1] = UInt32(truncatingIfNeeded: mark >> 32)
                } else { block[0] |= UInt32(field.inlineCount) << UInt32(8 + shift) }
                for index in 0..<field.inlineCount { block[bodyIndex] = field.inlineWord(index); bodyIndex += 1; position -= 1 }
                consumed += UInt32(field.inlineCount)
            } else if field.isSegment {
                if extended {
                    var mark = UInt64(block[markIndex]) | UInt64(block[markIndex + 1]) << 32
                    mark |= UInt64(1) << UInt64(shift)
                    block[markIndex] = UInt32(truncatingIfNeeded: mark); block[markIndex + 1] = UInt32(truncatingIfNeeded: mark >> 32)
                } else { block[0] |= UInt32(1) << UInt32(8 + shift) }
                block[bodyIndex] = offset(position - field.segment.position); bodyIndex += 1; position -= 1; consumed += 1
            }
        }

        for index in 0..<min(12, fields.count) { write(fields[index], markIndex: 0, shift: index * 2, extended: false) }
        if sections > 0 {
            for section in 0..<sections {
                let markIndex = 1 + section * 2
                var mark = UInt64(consumed) << 50
                block[markIndex] = UInt32(truncatingIfNeeded: mark); block[markIndex + 1] = UInt32(truncatingIfNeeded: mark >> 32)
                let begin = 12 + section * 25, end = min(fields.count, begin + 25)
                if begin < end { for index in begin..<end { write(fields[index], markIndex: markIndex, shift: (index - begin) * 2, extended: true) } }
                mark = UInt64(block[markIndex]) | UInt64(block[markIndex + 1]) << 32
                block[markIndex] = UInt32(truncatingIfNeeded: mark); block[markIndex + 1] = UInt32(truncatingIfNeeded: mark >> 32)
            }
        }
        return _ProtoCacheUnit(segment: .init(position: buffer.count, count: buffer.count - last))
    }

    public static func array(_ elements: [_ProtoCacheUnit], in buffer: _ProtoCacheBuffer, since checkpoint: Int? = nil) throws -> _ProtoCacheUnit {
        if elements.isEmpty { return _ProtoCacheUnit(inline: [1]) }
        let last = checkpoint ?? buffer.count
        let width = bestWidth(elements)
        var payload: [UInt32] = []
        var cells = [UInt32](repeating: 0, count: elements.count * width)
        for (index, element) in elements.enumerated() {
            guard let words = buffer.unitWords(element) else { throw ProtoCacheError.invalidHeader }
            let cellStart = index * width
            if words.count <= width {
                for offset in words.indices { cells[cellStart + offset] = words[offset] }
            } else {
                cells[cellStart] = offset(cells.count + payload.count - cellStart)
                payload += words
            }
        }
        buffer.shrink(buffer.count - last)
        buffer.put(payload); buffer.put(cells); buffer.put((UInt32(elements.count) << 2) | UInt32(width))
        return _ProtoCacheUnit(segment: .init(position: buffer.count, count: buffer.count - last))
    }

    public static func map(keys: [[UInt8]], keyUnits: [_ProtoCacheUnit], valueUnits: [_ProtoCacheUnit], in buffer: _ProtoCacheBuffer, since checkpoint: Int? = nil) throws -> _ProtoCacheUnit {
        guard keys.count == keyUnits.count && keys.count == valueUnits.count else { throw ProtoCacheError.typeMismatch("map pair count") }
        if keys.isEmpty { return _ProtoCacheUnit(inline: [5 << 28]) }
        let last = checkpoint ?? buffer.count
        let built = try PerfectHash.build(keys)
        var orderedKeys = [_ProtoCacheUnit](repeating: .empty, count: keys.count)
        var orderedValues = orderedKeys
        for index in keys.indices { orderedKeys[built.positions[index]] = keyUnits[index]; orderedValues[built.positions[index]] = valueUnits[index] }
        let keyWidth = bestWidth(orderedKeys), valueWidth = bestWidth(orderedValues)
        var payload: [UInt32] = [], cells = [UInt32](repeating: 0, count: keys.count * (keyWidth + valueWidth))
        for index in keys.indices {
            for (unit, cellStart, width) in [(orderedKeys[index], index * (keyWidth + valueWidth), keyWidth), (orderedValues[index], index * (keyWidth + valueWidth) + keyWidth, valueWidth)] {
                guard let words = buffer.unitWords(unit) else { throw ProtoCacheError.invalidHeader }
                if words.count <= width { for offset in words.indices { cells[cellStart + offset] = words[offset] } }
                else { cells[cellStart] = offset(cells.count + payload.count - cellStart); payload += words }
            }
        }
        buffer.shrink(buffer.count - last); buffer.put(payload); buffer.put(cells)
        var indexBytes = built.index
        let indexWords = (indexBytes.count + 3) / 4
        indexBytes += [UInt8](repeating: 0, count: indexWords * 4 - indexBytes.count)
        indexBytes.withUnsafeBytes { raw in
            var words = (0..<indexWords).map { UInt32(littleEndian: raw.baseAddress!.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
            words[0] |= UInt32(keyWidth) << 30 | UInt32(valueWidth) << 28
            buffer.put(words)
        }
        return _ProtoCacheUnit(segment: .init(position: buffer.count, count: buffer.count - last))
    }

    private static func bestWidth(_ units: [_ProtoCacheUnit]) -> Int {
        var sizes = [0, 0, 0]
        for unit in units {
            for width in 1...3 { sizes[width - 1] += width + (unit.count > width ? unit.count : 0) }
        }
        return (0..<3).min(by: { sizes[$0] < sizes[$1] })! + 1
    }
}
