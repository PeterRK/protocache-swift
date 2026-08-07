struct Segment: Sendable {
    let position: Int
    let count: Int
}

/// An intermediate encoded value used while assembling ProtoCache objects.
///
/// A unit stores either one to three inline words or the position and length
/// of a segment in the reverse-growing encoding buffer. The two states share
/// the same 16-byte storage.
public struct Unit: Sendable {
    private var storedInlineCount: UInt32
    var word0: UInt32
    var word1: UInt32
    var word2: UInt32

    var inlineCount: Int { Int(storedInlineCount) }
    var segmentPosition: Int {
        get { Int(word0) }
        set { word0 = UInt32(newValue) }
    }
    var segmentCount: Int { Int(word1) }
    var segmentEnd: Int { segmentPosition - segmentCount }

    public static var empty: Self { Self() }

    private init() {
        storedInlineCount = 0
        word0 = 0
        word1 = 0
        word2 = 0
    }

    public init(inline word: UInt32) {
        storedInlineCount = 1
        word0 = word
        word1 = 0
        word2 = 0
    }

    public init(inline word0: UInt32, _ word1: UInt32) {
        storedInlineCount = 2
        self.word0 = word0
        self.word1 = word1
        word2 = 0
    }

    public init(inline word0: UInt32, _ word1: UInt32, _ word2: UInt32) {
        storedInlineCount = 3
        self.word0 = word0
        self.word1 = word1
        self.word2 = word2
    }

    public init(inline words: [UInt32]) {
        precondition(words.count <= 3)
        storedInlineCount = UInt32(words.count)
        word0 = words.indices.contains(0) ? words[0] : 0
        word1 = words.indices.contains(1) ? words[1] : 0
        word2 = words.indices.contains(2) ? words[2] : 0
    }

    init(segment: Segment) {
        storedInlineCount = 0
        word0 = UInt32(segment.position)
        word1 = UInt32(segment.count)
        word2 = 0
    }

    public var count: Int { storedInlineCount == 0 ? segmentCount : inlineCount }
    public var isEmpty: Bool { count == 0 }
    var isSegment: Bool { storedInlineCount == 0 && segmentCount != 0 }
    func inlineWord(_ index: Int) -> UInt32 {
        switch index { case 0: word0; case 1: word1; default: word2 }
    }
}

public struct _ProtoCacheMapEntry: Sendable {
    public let key: [UInt8]
    public var keyUnit: Unit
    public var valueUnit: Unit

    public init(key: [UInt8], keyUnit: Unit, valueUnit: Unit) {
        self.key = key
        self.keyUnit = keyUnit
        self.valueUnit = valueUnit
    }

    static var empty: Self { .init(key: [], keyUnit: .empty, valueUnit: .empty) }
}

public final class _ProtoCacheBuffer {
    private var pointer: UnsafeMutablePointer<UInt32>?
    private var capacity: Int
    private var start: Int

    public init(minimumCapacityWords: Int = 64) {
        capacity = max(8, minimumCapacityWords)
        pointer = .allocate(capacity: capacity)
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

    func expandForOverwrite(_ words: Int) -> UnsafeMutableBufferPointer<UInt32> {
        precondition(words >= 0)
        if start < words { grow(minimum: count + words) }
        start -= words
        return UnsafeMutableBufferPointer(start: pointer!.advanced(by: start), count: words)
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

    func copyWords(
        of unit: Unit,
        to destination: UnsafeMutableBufferPointer<UInt32>,
        at destinationOffset: Int
    ) -> Bool {
        guard destinationOffset >= 0, destinationOffset + unit.count <= destination.count else { return false }
        if unit.inlineCount > 0 {
            for index in 0..<unit.inlineCount {
                destination[destinationOffset + index] = unit.inlineWord(index)
            }
            return true
        }
        if unit.segmentCount == 0 { return true }
        let sourceOffset = count - unit.segmentPosition
        guard sourceOffset >= 0, sourceOffset + unit.segmentCount <= count else { return false }
        for index in 0..<unit.segmentCount {
            destination[destinationOffset + index] = activeWord(sourceOffset + index)
        }
        return true
    }

    func compactionTail(since checkpoint: Int) -> Int {
        precondition(checkpoint >= 0 && checkpoint <= count)
        return capacity - checkpoint
    }

    func materialize(_ unit: inout Unit) {
        guard unit.inlineCount > 0 else { return }
        let previous = count
        let destination = expand(unit.inlineCount)
        for index in 0..<unit.inlineCount {
            destination[index] = unit.inlineWord(index)
        }
        unit = Unit(segment: .init(position: count, count: count - previous))
    }

    func compact(_ unit: inout Unit, toward tail: inout Int, inlineWidth: Int) -> Bool {
        guard unit.inlineCount == 0, unit.segmentCount > 0 else { return true }
        let length = unit.segmentCount
        let sourceStart = capacity - unit.segmentPosition
        guard sourceStart >= start, sourceStart + length <= capacity else { return false }
        if length <= inlineWidth {
            switch length {
            case 1:
                unit = Unit(inline: pointer![sourceStart])
            case 2:
                unit = Unit(inline: pointer![sourceStart], pointer![sourceStart + 1])
            case 3:
                unit = Unit(
                    inline: pointer![sourceStart], pointer![sourceStart + 1], pointer![sourceStart + 2]
                )
            default:
                return false
            }
            return true
        }

        var source = sourceStart + length
        if tail > source {
            let destinationStart = tail - length
            while tail > destinationStart {
                tail -= 1
                source -= 1
                pointer![tail] = pointer![source]
            }
            unit.segmentPosition -= tail - source
        } else {
            tail -= length
        }
        return tail >= start
    }

    func finishCompaction(at tail: Int) -> Bool {
        guard tail >= start, tail <= capacity else { return false }
        shrink(tail - start)
        return true
    }

    public func finish(_ root: Unit) throws -> Bytes {
        if root.inlineCount > 0 {
            let destination = expand(root.inlineCount)
            for index in 0..<root.inlineCount { destination[index] = root.inlineWord(index) }
        }
        guard root.count > 0 else { throw ProtoCacheError.invalidHeader }
        let base = pointer!
        let byteOffset = start * 4
        let byteCount = count * 4
        let storage = Storage(
            baseAddress: UnsafeRawPointer(base),
            mutableBaseAddress: UnsafeMutableRawPointer(base),
            byteCount: capacity * 4,
            deallocator: { pointer, _ in pointer.deallocate() }
        )
        pointer = nil
        return Bytes(storage: storage, byteOffset: byteOffset, count: byteCount)
    }

    @usableFromInline
    package func withBorrowedOutput<Result>(
        _ root: Unit,
        _ body: (borrowing Span) throws -> Result
    ) throws -> Result {
        if root.inlineCount > 0 {
            let destination = expand(root.inlineCount)
            for index in 0..<root.inlineCount { destination[index] = root.inlineWord(index) }
        }
        guard root.count > 0 else { throw ProtoCacheError.invalidHeader }
        let bytes = UnsafeRawBufferPointer(
            start: pointer!.advanced(by: start),
            count: count * MemoryLayout<UInt32>.stride
        )
        return try body(Span(unsafeBorrowing: bytes))
    }

    private func grow(minimum: Int) {
        var newCapacity = capacity
        while newCapacity < minimum { newCapacity = newCapacity.multipliedReportingOverflow(by: 2).overflow ? minimum : newCapacity * 2 }
        let replacement = UnsafeMutablePointer<UInt32>.allocate(capacity: newCapacity)
        let active = count
        replacement.advanced(by: newCapacity - active).initialize(
            from: pointer!.advanced(by: start), count: active
        )
        pointer!.deallocate()
        pointer = replacement
        capacity = newCapacity
        start = newCapacity - active
    }
}

public enum _ProtoCacheEncoding {
    @inline(__always) static func offset(_ words: Int) -> UInt32 { (UInt32(words) << 2) | 3 }

    public static func scalar<T: Scalar>(_ value: T) -> Unit {
        let words = value._encodeProtoCacheWords()
        if T._protoCacheWordWidth == 1 { return Unit(inline: words.0) }
        return Unit(inline: words.0, words.1)
    }

    public static func bytes(_ source: UnsafeRawBufferPointer, in buffer: _ProtoCacheBuffer) throws -> Unit {
        guard source.count < 1 << 30 else { throw ProtoCacheError.integerOverflow }
        var value = UInt32(source.count) << 2
        var header: UInt64 = 0
        var headerCount = 0
        repeat {
            var byte = UInt8(value & 0x7f); value >>= 7
            if value != 0 { byte |= 0x80 }
            header |= UInt64(byte) << UInt64(headerCount * 8)
            headerCount += 1
        } while value != 0
        let wordCount = (headerCount + source.count + 3) / 4
        if wordCount == 1 {
            var word = UInt32(truncatingIfNeeded: header)
            withUnsafeMutableBytes(of: &word) { destination in
                if source.count > 0 {
                    destination.baseAddress!.advanced(by: headerCount).copyMemory(
                        from: source.baseAddress!,
                        byteCount: source.count
                    )
                }
            }
            return Unit(inline: UInt32(littleEndian: word))
        }
        let previous = buffer.count
        let words = buffer.expand(wordCount)
        let raw = UnsafeMutableRawBufferPointer(start: words.baseAddress, count: wordCount * 4)
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        for index in 0..<headerCount {
            raw[index] = UInt8(truncatingIfNeeded: header >> UInt64(index * 8))
        }
        if source.count > 0 {
            raw.baseAddress!.advanced(by: headerCount).copyMemory(
                from: source.baseAddress!,
                byteCount: source.count
            )
        }
        return Unit(segment: .init(position: buffer.count, count: buffer.count - previous))
    }

    public static func string(_ value: String, in buffer: _ProtoCacheBuffer) throws -> Unit {
        try value.utf8.withContiguousStorageIfAvailable { storage in
            try bytes(UnsafeRawBufferPointer(storage), in: buffer)
        } ?? Array(value.utf8).withUnsafeBytes { try bytes($0, in: buffer) }
    }

    public static func copy(
        _ field: FieldView,
        kind: _ProtoCacheFieldKind,
        in buffer: _ProtoCacheBuffer
    ) throws -> Unit {
        let raw = field.rawBytes
        switch kind {
        case .scalar, .enumeration:
            return inlineUnit(raw, width: field.width)
        default:
            break
        }
        guard raw.loadUInt32(wordOffset: 0) & 3 == 3 else {
            return inlineUnit(raw, width: field.width)
        }
        let source = field.objectBytes
        let words = try encodedWordCount(source, kind: kind, depth: 0)
        return try embedded(source.slice(byteOffset: 0, count: words * 4), in: buffer)
    }

    private static func encodedWordCount(
        _ bytes: Span,
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
            return try arrayWordCount(bytes, element: element, depth: depth + 1)
        case .map(let key, let value):
            return try mapWordCount(bytes, key: key, value: value, depth: depth + 1)
        }
    }

    private static func stringWordCount(_ bytes: Span) throws -> Int {
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
        _ bytes: Span,
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
        for layoutField in layout.fields where hasReferencedObject(layoutField.kind) {
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
        _ bytes: Span,
        element: _ProtoCacheFieldKind,
        depth: Int
    ) throws -> Int {
        let head = bytes.loadUInt32(wordOffset: 0)
        let count = Int(head >> 2)
        let width = Int(head & 3)
        guard width > 0 else { throw ProtoCacheError.invalidHeader }
        var total = 1 + count * width
        guard total <= bytes.count / 4 else { throw ProtoCacheError.invalidHeader }
        switch element {
        case .scalar, .enumeration:
            return total
        default:
            break
        }
        for index in 0..<count {
            let field = FieldView(tail: bytes.wordSlice(offset: 1 + index * width), width: width)
            total = max(total, try referencedEnd(field, in: bytes, kind: element, depth: depth))
        }
        return total
    }

    private static func mapWordCount(
        _ bytes: Span,
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
        let keyHasReference = hasReferencedObject(key)
        let valueHasReference = hasReferencedObject(value)
        if !keyHasReference && !valueHasReference { return total }
        for index in 0..<count {
            let pairStart = indexWords + index * pairWidth
            if keyHasReference {
                let field = FieldView(tail: bytes.wordSlice(offset: pairStart), width: keyWidth)
                total = max(total, try referencedEnd(field, in: bytes, kind: key, depth: depth))
            }
            if valueHasReference {
                let field = FieldView(
                    tail: bytes.wordSlice(offset: pairStart + keyWidth),
                    width: valueWidth
                )
                total = max(total, try referencedEnd(field, in: bytes, kind: value, depth: depth))
            }
        }
        return total
    }

    @inline(__always)
    private static func hasReferencedObject(_ kind: _ProtoCacheFieldKind) -> Bool {
        switch kind {
        case .scalar, .enumeration: false
        default: true
        }
    }

    private static func referencedEnd(
        _ field: FieldView,
        in root: Span,
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
        let cell = root.rawBaseAddress.distance(to: field.tail.rawBaseAddress) / 4
        let object = cell + Int(first >> 2)
        guard object >= 0, object < root.count / 4 else { throw ProtoCacheError.invalidHeader }
        let child = root.wordSlice(offset: object)
        return object + (try encodedWordCount(child, kind: kind, depth: depth + 1))
    }

    public static func _copyInline(_ field: FieldView) -> Unit {
        inlineUnit(field.rawBytes, width: field.width)
    }

    public static func copy(
        _ field: FieldView,
        in buffer: _ProtoCacheBuffer,
        detect: (borrowing Span) throws -> Int
    ) throws -> Unit {
        let raw = field.rawBytes
        guard raw.loadUInt32(wordOffset: 0) & 3 == 3 else {
            return inlineUnit(raw, width: field.width)
        }
        let objectOffset = Int(raw.loadUInt32(wordOffset: 0) >> 2)
        guard objectOffset < field.tail.count / 4 else {
            throw ProtoCacheError.invalidHeader
        }
        let source = field.tail.wordSlice(offset: objectOffset)
        let wordCount = try detect(source)
        guard wordCount > 0, wordCount <= source.count / 4 else {
            throw ProtoCacheError.invalidHeader
        }
        return try embedded(source.slice(byteOffset: 0, count: wordCount * 4), in: buffer)
    }

    public static func _detectStringWords(_ bytes: Span) throws -> Int {
        try stringWordCount(bytes)
    }

    public static func _detectMessageBaseWords(_ bytes: Span) throws -> Int {
        guard bytes.count >= 4 else { throw ProtoCacheError.invalidHeader }
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
        let total = headWords + bodyWords
        guard total <= bytes.count / 4 else { throw ProtoCacheError.invalidHeader }
        return total
    }

    public static func _detectReferencedEnd(
        _ field: FieldView,
        in root: Span,
        detect: (borrowing Span) throws -> Int
    ) throws -> Int {
        let byteOffset = root.rawBaseAddress.distance(to: field.tail.rawBaseAddress)
        guard byteOffset >= 0, byteOffset & 3 == 0 else {
            throw ProtoCacheError.invalidHeader
        }
        return try detectReferencedEnd(at: byteOffset / 4, in: root, detect: detect)
    }

    private static func detectReferencedEnd(
        at cell: Int,
        in root: Span,
        detect: (borrowing Span) throws -> Int
    ) throws -> Int {
        guard cell >= 0, cell < root.count / 4 else {
            throw ProtoCacheError.invalidHeader
        }
        let first = root.loadUInt32(wordOffset: cell)
        guard first & 3 == 3 else { return 0 }
        let object = cell + Int(first >> 2)
        guard object >= 0, object < root.count / 4 else {
            throw ProtoCacheError.invalidHeader
        }
        let child = root.wordSlice(offset: object)
        let childWords = try detect(child)
        guard childWords > 0, childWords <= child.count / 4 else {
            throw ProtoCacheError.invalidHeader
        }
        return object + childWords
    }

    public static func _detectArrayBaseWords(_ bytes: Span) throws -> Int {
        try detectArrayBase(bytes).words
    }

    private static func detectArrayBase(
        _ bytes: Span
    ) throws -> (words: Int, count: Int, width: Int) {
        guard bytes.count >= 4 else { throw ProtoCacheError.invalidHeader }
        let head = bytes.loadUInt32(wordOffset: 0)
        let count = Int(head >> 2)
        let width = Int(head & 3)
        guard width > 0 else { throw ProtoCacheError.invalidHeader }
        let product = count.multipliedReportingOverflow(by: width)
        guard !product.overflow else { throw ProtoCacheError.integerOverflow }
        let total = 1 + product.partialValue
        guard total <= bytes.count / 4 else { throw ProtoCacheError.invalidHeader }
        return (total, count, width)
    }

    public static func _detectArrayWords(
        _ bytes: Span,
        detectElement: (borrowing Span) throws -> Int
    ) throws -> Int {
        let base = try detectArrayBase(bytes)
        let baseWords = base.words
        let count = base.count
        guard count > 0 else { return baseWords }
        let width = base.width
        var detectedWords = baseWords
        for index in stride(from: count - 1, through: 0, by: -1) {
            let cell = 1 + index * width
            let end = try detectReferencedEnd(at: cell, in: bytes, detect: detectElement)
            if end == bytes.count / 4 { return end }
            if end > detectedWords { detectedWords = end }
        }
        return detectedWords
    }

    public static func _detectMapBaseWords(_ bytes: Span) throws -> Int {
        try detectMapBase(bytes).words
    }

    private static func detectMapBase(
        _ bytes: Span
    ) throws -> (words: Int, count: Int, keyWidth: Int, valueWidth: Int) {
        guard bytes.count >= 4 else { throw ProtoCacheError.invalidHeader }
        let head = bytes.loadUInt32(wordOffset: 0)
        let count = Int(head & 0x0fff_ffff)
        let keyWidth = Int((head >> 30) & 3)
        let valueWidth = Int((head >> 28) & 3)
        guard keyWidth > 0, valueWidth > 0 else { throw ProtoCacheError.invalidHeader }
        let indexByteCount = PerfectHashView.encodedByteCount(for: count)
        guard indexByteCount <= bytes.count else { throw ProtoCacheError.invalidHeader }
        let indexWords = (indexByteCount + 3) / 4
        let product = count.multipliedReportingOverflow(by: keyWidth + valueWidth)
        guard !product.overflow else { throw ProtoCacheError.integerOverflow }
        let total = indexWords + product.partialValue
        guard total <= bytes.count / 4 else { throw ProtoCacheError.invalidHeader }
        return (total, count, keyWidth, valueWidth)
    }

    public static func _detectMapWords(
        _ bytes: Span,
        keyIsReferenced: Bool,
        detectKey: (borrowing Span) throws -> Int,
        valueIsReferenced: Bool,
        detectValue: (borrowing Span) throws -> Int
    ) throws -> Int {
        let base = try detectMapBase(bytes)
        let baseWords = base.words
        guard keyIsReferenced || valueIsReferenced else { return baseWords }
        let count = base.count
        guard count > 0 else { return baseWords }
        let keyWidth = base.keyWidth
        let valueWidth = base.valueWidth
        let pairWidth = keyWidth + valueWidth
        let pairStart = baseWords - count * pairWidth
        var detectedWords = baseWords
        for index in stride(from: count - 1, through: 0, by: -1) {
            let start = pairStart + index * pairWidth
            if valueIsReferenced {
                let end = try detectReferencedEnd(
                    at: start + keyWidth,
                    in: bytes,
                    detect: detectValue
                )
                if end == bytes.count / 4 { return end }
                if end > detectedWords { detectedWords = end }
            }
            if keyIsReferenced {
                let end = try detectReferencedEnd(at: start, in: bytes, detect: detectKey)
                if end == bytes.count / 4 { return end }
                if end > detectedWords { detectedWords = end }
            }
        }
        return detectedWords
    }

    public static func embedded(_ source: Span, in buffer: _ProtoCacheBuffer) throws -> Unit {
        guard source.count > 0, source.count % 4 == 0 else { throw ProtoCacheError.invalidHeader }
        let previous = buffer.count
        let wordCount = source.count / 4
        let destination = buffer.expandForOverwrite(wordCount)
        source.withUnsafeBytes { raw in
            UnsafeMutableRawPointer(destination.baseAddress!).copyMemory(
                from: raw.baseAddress!,
                byteCount: raw.count
            )
        }
        return Unit(segment: .init(position: buffer.count, count: buffer.count - previous))
    }

    public static func embedded(_ source: Bytes, in buffer: _ProtoCacheBuffer) throws -> Unit {
        try source.withBorrowedSpan { try embedded($0, in: buffer) }
    }

    public static func boolArray(_ values: [Bool], in buffer: _ProtoCacheBuffer) throws -> Unit {
        guard values.count < 1 << 30 else { throw ProtoCacheError.integerOverflow }
        var value = UInt32(values.count) << 2
        var header: UInt64 = 0
        var headerCount = 0
        repeat {
            var byte = UInt8(value & 0x7f); value >>= 7
            if value != 0 { byte |= 0x80 }
            header |= UInt64(byte) << UInt64(headerCount * 8)
            headerCount += 1
        } while value != 0
        let wordCount = (headerCount + values.count + 3) / 4
        if wordCount == 1 {
            var word = UInt32(truncatingIfNeeded: header)
            withUnsafeMutableBytes(of: &word) { destination in
                for index in values.indices {
                    destination[headerCount + index] = values[index] ? 1 : 0
                }
            }
            return Unit(inline: UInt32(littleEndian: word))
        }
        let previous = buffer.count
        let words = buffer.expand(wordCount)
        let raw = UnsafeMutableRawBufferPointer(start: words.baseAddress, count: wordCount * 4)
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        for index in 0..<headerCount {
            raw[index] = UInt8(truncatingIfNeeded: header >> UInt64(index * 8))
        }
        for index in values.indices { raw[headerCount + index] = values[index] ? 1 : 0 }
        return Unit(segment: .init(position: buffer.count, count: buffer.count - previous))
    }

    public static func byteArray(_ values: [UInt8], in buffer: _ProtoCacheBuffer) throws -> Unit {
        try values.withUnsafeBytes { try bytes($0, in: buffer) }
    }

    public static func fold(_ unit: inout Unit, in buffer: _ProtoCacheBuffer) {
        guard unit.isSegment, unit.segmentCount < 4, unit.segmentPosition == buffer.count else { return }
        let count = unit.segmentCount
        switch count {
        case 1:
            unit = Unit(inline: buffer.activeWord(0))
        case 2:
            unit = Unit(inline: buffer.activeWord(0), buffer.activeWord(1))
        case 3:
            unit = Unit(
                inline: buffer.activeWord(0), buffer.activeWord(1), buffer.activeWord(2)
            )
        default:
            return
        }
        buffer.shrink(count)
    }

    public static func message(
        fieldCount: Int,
        in buffer: _ProtoCacheBuffer,
        since checkpoint: Int? = nil,
        _ encodeFields: (UnsafeMutableBufferPointer<Unit>) throws -> Void
    ) throws -> Unit {
        guard fieldCount > 0 else { throw ProtoCacheError.invalidSchema("empty message") }
        return try withUnsafeTemporaryAllocation(
            of: Unit.self,
            capacity: fieldCount
        ) { fields in
            fields.initialize(repeating: .empty)
            defer { fields.deinitialize() }
            try encodeFields(fields)
            return try message(fields, in: buffer, since: checkpoint)
        }
    }

    public static func message(
        _ fields: inout [Unit],
        in buffer: _ProtoCacheBuffer,
        since checkpoint: Int? = nil
    ) throws -> Unit {
        try fields.withUnsafeMutableBufferPointer {
            try message($0, in: buffer, since: checkpoint)
        }
    }

    public static func message(
        _ fields: UnsafeMutableBufferPointer<Unit>,
        in buffer: _ProtoCacheBuffer,
        since checkpoint: Int?
    ) throws -> Unit {
        guard !fields.isEmpty else { throw ProtoCacheError.invalidSchema("empty message") }
        let last = checkpoint ?? buffer.count
        let usedCount = (fields.lastIndex(where: { !$0.isEmpty }) ?? -1) + 1
        if usedCount == 0 {
            let before = buffer.count; buffer.put(0)
            return Unit(segment: .init(position: buffer.count, count: buffer.count - before))
        }
        var bodyCount = 0
        for index in 0..<usedCount {
            let field = fields[index]
            bodyCount += field.inlineCount > 0 ? field.inlineCount : field.isSegment ? 1 : 0
        }
        let sections = (usedCount + 12) / 25
        guard sections <= 255 else { throw ProtoCacheError.integerOverflow }
        let headCount = 1 + sections * 2
        let currentCount = buffer.count
        let totalCount = currentCount + headCount + bodyCount
        let block = buffer.expand(headCount + bodyCount)
        var bodyIndex = headCount
        var position = totalCount - headCount
        var consumed: UInt32 = 0
        block[0] = UInt32(sections)

        func write(_ field: Unit, markIndex: Int, shift: Int, extended: Bool) {
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
                block[bodyIndex] = offset(position - field.segmentPosition); bodyIndex += 1; position -= 1; consumed += 1
            }
        }

        for index in 0..<min(12, usedCount) { write(fields[index], markIndex: 0, shift: index * 2, extended: false) }
        if sections > 0 {
            for section in 0..<sections {
                let markIndex = 1 + section * 2
                var mark = UInt64(consumed) << 50
                block[markIndex] = UInt32(truncatingIfNeeded: mark); block[markIndex + 1] = UInt32(truncatingIfNeeded: mark >> 32)
                let begin = 12 + section * 25, end = min(usedCount, begin + 25)
                if begin < end { for index in begin..<end { write(fields[index], markIndex: markIndex, shift: (index - begin) * 2, extended: true) } }
                mark = UInt64(block[markIndex]) | UInt64(block[markIndex + 1]) << 32
                block[markIndex] = UInt32(truncatingIfNeeded: mark); block[markIndex + 1] = UInt32(truncatingIfNeeded: mark >> 32)
            }
        }
        return Unit(segment: .init(position: buffer.count, count: buffer.count - last))
    }

    public static func array(_ elements: [Unit], in buffer: _ProtoCacheBuffer, since checkpoint: Int? = nil) throws -> Unit {
        var elements = elements
        return try array(&elements, in: buffer, since: checkpoint)
    }

    public static func array(_ elements: inout [Unit], in buffer: _ProtoCacheBuffer, since checkpoint: Int? = nil) throws -> Unit {
        try elements.withUnsafeMutableBufferPointer {
            try array($0, in: buffer, since: checkpoint)
        }
    }

    public static func array(
        elementCount: Int,
        in buffer: _ProtoCacheBuffer,
        since checkpoint: Int? = nil,
        _ encodeElements: (UnsafeMutableBufferPointer<Unit>) throws -> Void
    ) throws -> Unit {
        guard elementCount >= 0 else { throw ProtoCacheError.integerOverflow }
        if elementCount <= 32 {
            return try withUnsafeTemporaryAllocation(
                of: Unit.self, capacity: elementCount
            ) { elements in
                elements.initialize(repeating: .empty)
                defer { elements.deinitialize() }
                try encodeElements(elements)
                return try array(elements, in: buffer, since: checkpoint)
            }
        }
        var elements = [Unit](repeating: .empty, count: elementCount)
        try elements.withUnsafeMutableBufferPointer { pointer in
            try encodeElements(pointer)
        }
        return try array(&elements, in: buffer, since: checkpoint)
    }

    public static func array(
        _ elements: UnsafeMutableBufferPointer<Unit>,
        in buffer: _ProtoCacheBuffer,
        since checkpoint: Int? = nil
    ) throws -> Unit {
        if elements.isEmpty { return Unit(inline: 1) }
        let last = checkpoint ?? buffer.count
        let width = bestWidth(elements)
        let (cellCount, overflow) = elements.count.multipliedReportingOverflow(by: width)
        guard !overflow, cellCount < 1 << 30 else { throw ProtoCacheError.integerOverflow }
        guard compactArrayPayloads(elements, width: width, in: buffer, since: last) else {
            throw ProtoCacheError.invalidHeader
        }
        let cells = buffer.expand(cellCount)
        let firstCellPosition = buffer.count
        for index in elements.indices {
            let cellStart = index * width
            guard writeCell(
                elements[index], to: cells, at: cellStart, width: width,
                position: firstCellPosition - cellStart
            ) else { throw ProtoCacheError.invalidHeader }
        }
        buffer.put((UInt32(elements.count) << 2) | UInt32(width))
        return Unit(segment: .init(position: buffer.count, count: buffer.count - last))
    }

    public static func map(keys: [[UInt8]], keyUnits: [Unit], valueUnits: [Unit], in buffer: _ProtoCacheBuffer, since checkpoint: Int? = nil) throws -> Unit {
        guard keys.count == keyUnits.count && keys.count == valueUnits.count else { throw ProtoCacheError.typeMismatch("map pair count") }
        var entries: [_ProtoCacheMapEntry] = []
        entries.reserveCapacity(keys.count)
        for index in keys.indices {
            entries.append(.init(key: keys[index], keyUnit: keyUnits[index], valueUnit: valueUnits[index]))
        }
        return try map(&entries, in: buffer, since: checkpoint)
    }

    public static func map(_ entries: [_ProtoCacheMapEntry], in buffer: _ProtoCacheBuffer, since checkpoint: Int? = nil) throws -> Unit {
        var entries = entries
        return try map(&entries, in: buffer, since: checkpoint)
    }

    public static func map(_ entries: inout [_ProtoCacheMapEntry], in buffer: _ProtoCacheBuffer, since checkpoint: Int? = nil) throws -> Unit {
        try entries.withUnsafeMutableBufferPointer {
            try map($0, in: buffer, since: checkpoint)
        }
    }

    public static func map(
        entryCount: Int,
        in buffer: _ProtoCacheBuffer,
        since checkpoint: Int? = nil,
        _ encodeEntries: (UnsafeMutableBufferPointer<_ProtoCacheMapEntry>) throws -> Void
    ) throws -> Unit {
        guard entryCount >= 0 else { throw ProtoCacheError.integerOverflow }
        if entryCount <= 16 {
            return try withUnsafeTemporaryAllocation(
                of: _ProtoCacheMapEntry.self, capacity: entryCount
            ) { entries in
                entries.initialize(repeating: .empty)
                defer { entries.deinitialize() }
                try encodeEntries(entries)
                return try map(entries, in: buffer, since: checkpoint)
            }
        }
        var entries = [_ProtoCacheMapEntry](repeating: .empty, count: entryCount)
        try entries.withUnsafeMutableBufferPointer { pointer in
            try encodeEntries(pointer)
        }
        return try map(&entries, in: buffer, since: checkpoint)
    }

    public static func map(
        _ entries: UnsafeMutableBufferPointer<_ProtoCacheMapEntry>,
        in buffer: _ProtoCacheBuffer,
        since checkpoint: Int? = nil
    ) throws -> Unit {
        if entries.isEmpty { return Unit(inline: 5 << 28) }
        let last = checkpoint ?? buffer.count
        var sortedEntries = entries
        sortedEntries.sort { $0.key.lexicographicallyPrecedes($1.key) }
        if entries.count <= 16 {
            return try withUnsafeTemporaryAllocation(of: Int.self, capacity: entries.count) { positions in
                positions.initialize(repeating: 0)
                defer { positions.deinitialize() }
                return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { index in
                    index.initialize(repeating: 0)
                    defer { index.deinitialize() }
                    let indexCount = try PerfectHash.buildSmallEntries(
                        entries, index: index, positions: positions
                    )
                    return try encodeMapBlock(
                        entries,
                        index: UnsafeBufferPointer(rebasing: index[..<indexCount]),
                        positions: UnsafeBufferPointer(positions), in: buffer, since: last
                    )
                }
            }
        }
        let built = try PerfectHash.buildEntries(entries)
        return try built.positions.withUnsafeBufferPointer { positions in
            try built.index.withUnsafeBufferPointer { index in
                try encodeMapBlock(
                    entries, index: index, positions: positions, in: buffer, since: last
                )
            }
        }
    }

    private static func encodeMapBlock(
        _ entries: UnsafeMutableBufferPointer<_ProtoCacheMapEntry>,
        index: UnsafeBufferPointer<UInt8>,
        positions: UnsafeBufferPointer<Int>,
        in buffer: _ProtoCacheBuffer,
        since last: Int
    ) throws -> Unit {
        precondition(positions.count == entries.count)
        let (keyWidth, valueWidth) = bestWidths(entries)
        let pairWidth = keyWidth + valueWidth
        let (cellCount, overflow) = entries.count.multipliedReportingOverflow(by: pairWidth)
        guard !overflow, cellCount < 1 << 30 else { throw ProtoCacheError.integerOverflow }
        var payloadCount = 0
        for entry in entries {
            if entry.keyUnit.count > keyWidth { payloadCount += entry.keyUnit.count }
            if entry.valueUnit.count > valueWidth { payloadCount += entry.valueUnit.count }
        }
        let (blockCount, blockOverflow) = cellCount.addingReportingOverflow(payloadCount)
        guard !blockOverflow, blockCount < 1 << 30 else { throw ProtoCacheError.integerOverflow }
        let block = buffer.expand(blockCount)
        var payloadOffset = cellCount
        for index in entries.indices {
            let keyStart = positions[index] * pairWidth
            let keyUnit = entries[index].keyUnit
            if keyUnit.count <= keyWidth {
                guard buffer.copyWords(of: keyUnit, to: block, at: keyStart) else {
                    throw ProtoCacheError.invalidHeader
                }
            } else {
                block[keyStart] = offset(payloadOffset - keyStart)
                guard buffer.copyWords(of: keyUnit, to: block, at: payloadOffset) else {
                    throw ProtoCacheError.invalidHeader
                }
                payloadOffset += keyUnit.count
            }
            let valueStart = keyStart + keyWidth
            let valueUnit = entries[index].valueUnit
            if valueUnit.count <= valueWidth {
                guard buffer.copyWords(of: valueUnit, to: block, at: valueStart) else {
                    throw ProtoCacheError.invalidHeader
                }
            } else {
                block[valueStart] = offset(payloadOffset - valueStart)
                guard buffer.copyWords(of: valueUnit, to: block, at: payloadOffset) else {
                    throw ProtoCacheError.invalidHeader
                }
                payloadOffset += valueUnit.count
            }
        }
        var blockUnit = Unit(segment: .init(position: buffer.count, count: blockCount))
        var tail = buffer.compactionTail(since: last)
        guard buffer.compact(&blockUnit, toward: &tail, inlineWidth: 0),
              buffer.finishCompaction(at: tail) else {
            throw ProtoCacheError.invalidHeader
        }
        let indexWords = (index.count + 3) / 4
        let words = buffer.expand(indexWords)
        let raw = UnsafeMutableRawBufferPointer(start: words.baseAddress, count: indexWords * 4)
        for position in index.indices {
            raw[position] = index[position]
        }
        words[0] |= UInt32(keyWidth) << 30 | UInt32(valueWidth) << 28
        return Unit(segment: .init(position: buffer.count, count: buffer.count - last))
    }

    private static func writeCell(
        _ unit: Unit,
        to destination: UnsafeMutableBufferPointer<UInt32>,
        at start: Int,
        width: Int,
        position: Int
    ) -> Bool {
        guard start >= 0, width > 0, start + width <= destination.count else { return false }
        if unit.inlineCount > 0 {
            guard unit.inlineCount <= width else { return false }
            for index in 0..<unit.inlineCount { destination[start + index] = unit.inlineWord(index) }
            return true
        }
        if unit.segmentCount == 0 { return true }
        let displacement = position - unit.segmentPosition
        guard displacement > 0, displacement < 1 << 30 else { return false }
        destination[start] = offset(displacement)
        return true
    }

    private static func compactArrayPayloads(
        _ elements: UnsafeMutableBufferPointer<Unit>,
        width: Int,
        in buffer: _ProtoCacheBuffer,
        since checkpoint: Int
    ) -> Bool {
        var materializedInlineUnit = false
        for index in elements.indices where elements[index].inlineCount > width {
            buffer.materialize(&elements[index])
            materializedInlineUnit = true
        }
        if !materializedInlineUnit {
            var tail = buffer.compactionTail(since: checkpoint)
            for index in elements.indices {
                guard buffer.compact(&elements[index], toward: &tail, inlineWidth: width) else {
                    return false
                }
            }
            return buffer.finishCompaction(at: tail)
        }
        if elements.count > 64 {
            return compactLargeArrayPayloads(
                elements, width: width, in: buffer, since: checkpoint
            )
        }
        var tail = buffer.compactionTail(since: checkpoint)
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: elements.count) { order in
            order.initialize(repeating: 0)
            defer { order.deinitialize() }
            var count = 0
            for index in elements.indices {
                if elements[index].isSegment, elements[index].segmentCount <= width {
                    guard buffer.compact(&elements[index], toward: &tail, inlineWidth: width) else {
                        return false
                    }
                }
                if elements[index].isSegment {
                    order[count] = index
                    count += 1
                }
            }
            if count > 1 {
                for index in 1..<count {
                    let value = order[index]
                    let end = elements[value].segmentEnd
                    var position = index
                    while position > 0, elements[order[position - 1]].segmentEnd > end {
                        order[position] = order[position - 1]
                        position -= 1
                    }
                    order[position] = value
                }
            }
            for position in 0..<count {
                guard buffer.compact(&elements[order[position]], toward: &tail, inlineWidth: width) else {
                    return false
                }
            }
            return buffer.finishCompaction(at: tail)
        }
    }

    @inline(never)
    private static func compactLargeArrayPayloads(
        _ elements: UnsafeMutableBufferPointer<Unit>,
        width: Int,
        in buffer: _ProtoCacheBuffer,
        since checkpoint: Int
    ) -> Bool {
        var tail = buffer.compactionTail(since: checkpoint)
        var order: [Int] = []
        order.reserveCapacity(elements.count)
        for index in elements.indices {
            if elements[index].isSegment, elements[index].segmentCount <= width {
                guard buffer.compact(&elements[index], toward: &tail, inlineWidth: width) else {
                    return false
                }
            }
            if elements[index].isSegment { order.append(index) }
        }
        order.sort { elements[$0].segmentEnd < elements[$1].segmentEnd }
        for index in order {
            guard buffer.compact(&elements[index], toward: &tail, inlineWidth: width) else {
                return false
            }
        }
        return buffer.finishCompaction(at: tail)
    }

    private static func bestWidths(
        _ entries: UnsafeMutableBufferPointer<_ProtoCacheMapEntry>
    ) -> (Int, Int) {
        var key1 = 0, key2 = 0, key3 = 0
        var value1 = 0, value2 = 0, value3 = 0
        for entry in entries {
            let keyCount = entry.keyUnit.count
            key1 += 1 + (keyCount > 1 ? keyCount : 0)
            key2 += 2 + (keyCount > 2 ? keyCount : 0)
            key3 += 3 + (keyCount > 3 ? keyCount : 0)
            let valueCount = entry.valueUnit.count
            value1 += 1 + (valueCount > 1 ? valueCount : 0)
            value2 += 2 + (valueCount > 2 ? valueCount : 0)
            value3 += 3 + (valueCount > 3 ? valueCount : 0)
        }
        return (bestWidth(key1, key2, key3), bestWidth(value1, value2, value3))
    }

    private static func bestWidth(_ size1: Int, _ size2: Int, _ size3: Int) -> Int {
        if size1 <= size2, size1 <= size3 { return 1 }
        return size2 <= size3 ? 2 : 3
    }

    private static func bestWidth(_ units: UnsafeMutableBufferPointer<Unit>) -> Int {
        var size1 = 0, size2 = 0, size3 = 0
        for unit in units {
            size1 += 1 + (unit.count > 1 ? unit.count : 0)
            size2 += 2 + (unit.count > 2 ? unit.count : 0)
            size3 += 3 + (unit.count > 3 ? unit.count : 0)
        }
        return bestWidth(size1, size2, size3)
    }

    private static func inlineUnit(_ raw: Span, width: Int) -> Unit {
        switch width {
        case 1:
            return Unit(inline: raw.loadUInt32(wordOffset: 0))
        case 2:
            return Unit(
                inline: raw.loadUInt32(wordOffset: 0), raw.loadUInt32(wordOffset: 1)
            )
        case 3:
            return Unit(
                inline: raw.loadUInt32(wordOffset: 0),
                raw.loadUInt32(wordOffset: 1),
                raw.loadUInt32(wordOffset: 2)
            )
        default:
            preconditionFailure("inline ProtoCache unit width exceeds 3")
        }
    }
}
