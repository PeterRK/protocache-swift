import struct Foundation.Data
import ProtoCacheCore
import SwiftProtobuf

public enum ProtoCache {
    public static func serialize<M: Message, View: GeneratedView>(
        _ message: borrowing M,
        as viewType: View.Type
    ) throws -> Bytes where View: ~Escapable {
        let layout = try checkedLayout(message, as: viewType)
        let buffer = _ProtoCacheBuffer()
        let encoded = try encode(message, layout: layout, buffer: buffer, depth: 0)
        return try buffer.finish(encoded.unit)
    }

    /// Serializes into reusable storage and lends the result for the duration
    /// of `body`.
    public static func withSerializedSpan<M: Message, View: GeneratedView, Result>(
        _ message: borrowing M,
        using buffer: SerializationBuffer,
        as viewType: View.Type,
        _ body: (borrowing Span) throws -> Result
    ) throws -> Result where View: ~Escapable {
        let layout = try checkedLayout(message, as: viewType)
        let storage = buffer._protoCacheStorage
        storage.clear()
        let encoded = try encode(message, layout: layout, buffer: storage, depth: 0)
        return try storage.withBorrowedOutput(encoded.unit, body)
    }

    private static func checkedLayout<M: Message, View: GeneratedView>(
        _ message: borrowing M,
        as viewType: View.Type
    ) throws -> _ProtoCacheLayout where View: ~Escapable {
        let layout = viewType._protoCacheLayout
        guard layout.runtimeABI == 6 else {
            throw ProtoCacheError.invalidSchema("unsupported generated runtime ABI \(layout.runtimeABI)")
        }
        guard M.protoMessageName == layout.fullName else {
            throw ProtoCacheError.typeMismatch("message \(M.protoMessageName) does not match \(layout.fullName)")
        }
        return layout
    }
}

private let maxDepth = 100

private struct Encoded {
    var unit: Unit
    var isEmpty: Bool
}

private func encode<M: Message>(
    _ message: borrowing M,
    layout: _ProtoCacheLayout,
    buffer: _ProtoCacheBuffer,
    depth: Int
) throws -> Encoded {
    guard depth <= maxDepth else { throw ProtoCacheError.recursionLimitExceeded }
    guard M.protoMessageName == layout.fullName else {
        throw ProtoCacheError.typeMismatch("nested message \(M.protoMessageName) does not match \(layout.fullName)")
    }
    let owned = copy message
    return try withUnsafeTemporaryAllocation(
        of: Unit.self,
        capacity: layout._fieldCount
    ) { units in
        units.initialize(repeating: .empty)
        defer { units.deinitialize() }
        var encoder = try Encoder(
            layout: layout,
            buffer: buffer,
            depth: depth,
            omitDefaults: true,
            units: units
        )
        try owned.traverse(visitor: &encoder)
        return try encoder.finish()
    }
}

private struct Encoder: Visitor {
    let layout: _ProtoCacheLayout?
    let keyKind: _ProtoCacheFieldKind?
    let valueKind: _ProtoCacheFieldKind?
    let buffer: _ProtoCacheBuffer
    let depth: Int
    let checkpoint: Int
    let omitDefaults: Bool
    let keyFieldNumber: Int?
    var units: UnsafeMutableBufferPointer<Unit>
    var keyBytes: [UInt8]?

    init(
        layout: _ProtoCacheLayout,
        buffer: _ProtoCacheBuffer,
        depth: Int,
        omitDefaults: Bool,
        keyFieldNumber: Int? = nil,
        units: UnsafeMutableBufferPointer<Unit>
    ) throws {
        guard layout.runtimeABI == 6 else {
            throw ProtoCacheError.invalidSchema("unsupported generated runtime ABI \(layout.runtimeABI)")
        }
        guard layout._hasValidFieldNumbers else {
            throw ProtoCacheError.invalidSchema("invalid or duplicate field number in \(layout.fullName)")
        }
        self.layout = layout
        self.keyKind = nil
        self.valueKind = nil
        self.buffer = buffer
        self.depth = depth
        self.checkpoint = buffer.checkpoint
        self.omitDefaults = omitDefaults
        self.keyFieldNumber = keyFieldNumber
        guard units.count == layout._fieldCount else {
            throw ProtoCacheError.invalidSchema("field scratch does not match \(layout.fullName)")
        }
        self.units = units
        self.keyBytes = nil
    }

    init(
        keyKind: _ProtoCacheFieldKind,
        valueKind: _ProtoCacheFieldKind,
        buffer: _ProtoCacheBuffer,
        depth: Int,
        units: UnsafeMutableBufferPointer<Unit>
    ) throws {
        guard units.count == 2 else {
            throw ProtoCacheError.invalidSchema("map entry scratch must contain two fields")
        }
        self.layout = nil
        self.keyKind = keyKind
        self.valueKind = valueKind
        self.buffer = buffer
        self.depth = depth
        self.checkpoint = buffer.checkpoint
        self.omitDefaults = false
        self.keyFieldNumber = 1
        self.units = units
        self.keyBytes = nil
    }

    mutating func finish() throws -> Encoded {
        guard let layout else {
            throw ProtoCacheError.invalidSchema("map entry encoder cannot finish a message")
        }
        let isEmpty = !units.contains { !$0.isEmpty }
        if layout.isAlias {
            guard let kind = layout._kind(1) else { throw ProtoCacheError.invalidSchema("alias has no field 1") }
            if !units[0].isEmpty { return Encoded(unit: units[0], isEmpty: false) }
            switch kind {
            case .array:
                return Encoded(unit: try _ProtoCacheEncoding.array([], in: buffer, since: checkpoint), isEmpty: true)
            case .map:
                return Encoded(
                    unit: try _ProtoCacheEncoding.map(keys: [], keyUnits: [], valueUnits: [], in: buffer, since: checkpoint),
                    isEmpty: true
                )
            default:
                throw ProtoCacheError.invalidSchema("alias field is not an array or map")
            }
        }
        return Encoded(
            unit: try _ProtoCacheEncoding.message(units, in: buffer, since: checkpoint),
            isEmpty: isEmpty
        )
    }

    func kind(_ number: Int) -> _ProtoCacheFieldKind? {
        if let layout { return layout._kind(number) }
        switch number {
        case 1: return keyKind
        case 2: return valueKind
        default: return nil
        }
    }

    mutating func store(_ unit: Unit, fieldNumber: Int) {
        var unit = unit
        _ProtoCacheEncoding.fold(&unit, in: buffer)
        units[fieldNumber - 1] = unit
    }

    func scalarKind(_ fieldNumber: Int, expected: _ProtoCacheScalarKind) throws -> Bool {
        guard let kind = kind(fieldNumber) else { return false }
        guard case .scalar(let actual) = kind, actual == expected else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected \(expected.rawValue)")
        }
        return true
    }

    mutating func recordKey<T: FixedWidthInteger>(_ value: T, fieldNumber: Int) {
        guard keyFieldNumber == fieldNumber else { return }
        var copy = value.littleEndian
        keyBytes = Swift.withUnsafeBytes(of: &copy) { Array($0) }
    }

    mutating func visitSingularFloatField(value: Float, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .float) else { return }
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .double) else { return }
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularInt32Field(value: Int32, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .int32) else { return }
        recordKey(value, fieldNumber: fieldNumber)
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .int64) else { return }
        recordKey(value, fieldNumber: fieldNumber)
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularUInt32Field(value: UInt32, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .uint32) else { return }
        recordKey(value, fieldNumber: fieldNumber)
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .uint64) else { return }
        recordKey(value, fieldNumber: fieldNumber)
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .bool) else { return }
        if keyFieldNumber == fieldNumber { keyBytes = [value ? 1 : 0] }
        if omitDefaults && !value { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .string = kind else { throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected string") }
        if keyFieldNumber == fieldNumber { keyBytes = Array(value.utf8) }
        if omitDefaults && value.isEmpty { return }
        store(try _ProtoCacheEncoding.string(value, in: buffer), fieldNumber: fieldNumber)
    }

    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .bytes = kind else { throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected bytes") }
        if omitDefaults && value.isEmpty { return }
        let unit = try value.withUnsafeBytes { try _ProtoCacheEncoding.bytes($0, in: buffer) }
        store(unit, fieldNumber: fieldNumber)
    }

    mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .enumeration = kind else { throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected enum") }
        let raw = Int32(truncatingIfNeeded: value.rawValue)
        if omitDefaults && raw == 0 { return }
        store(_ProtoCacheEncoding.scalar(raw), fieldNumber: fieldNumber)
    }

    mutating func visitSingularMessageField<M: Message>(value: M, fieldNumber: Int) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .message(let nestedLayout) = kind else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected message")
        }
        let encoded = try encode(value, layout: nestedLayout(), buffer: buffer, depth: depth + 1)
        if omitDefaults && encoded.isEmpty { return }
        store(encoded.unit, fieldNumber: fieldNumber)
    }

    mutating func repeatedScalar<T: Scalar>(
        _ value: [T], fieldNumber: Int, expected: _ProtoCacheScalarKind
    ) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .array(let element) = kind, case .scalar(let actual) = element, actual == expected else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<\(expected.rawValue)>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let encoded = try _ProtoCacheEncoding.array(
            elementCount: value.count, in: buffer, since: start
        ) { elements in
            for index in value.indices {
                elements[index] = _ProtoCacheEncoding.scalar(value[index])
            }
        }
        store(encoded, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedFloatField(value: [Float], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .float) }
    mutating func visitRepeatedDoubleField(value: [Double], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .double) }
    mutating func visitRepeatedInt32Field(value: [Int32], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .int32) }
    mutating func visitRepeatedInt64Field(value: [Int64], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .int64) }
    mutating func visitRepeatedUInt32Field(value: [UInt32], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .uint32) }
    mutating func visitRepeatedUInt64Field(value: [UInt64], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .uint64) }
    mutating func visitRepeatedSInt32Field(value: [Int32], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .int32) }
    mutating func visitRepeatedSInt64Field(value: [Int64], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .int64) }
    mutating func visitRepeatedFixed32Field(value: [UInt32], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .uint32) }
    mutating func visitRepeatedFixed64Field(value: [UInt64], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .uint64) }
    mutating func visitRepeatedSFixed32Field(value: [Int32], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .int32) }
    mutating func visitRepeatedSFixed64Field(value: [Int64], fieldNumber: Int) throws { try repeatedScalar(value, fieldNumber: fieldNumber, expected: .int64) }

    mutating func visitRepeatedBoolField(value: [Bool], fieldNumber: Int) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .array(let element) = kind, case .scalar(.bool) = element else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<bool>")
        }
        guard !value.isEmpty else { return }
        store(try _ProtoCacheEncoding.boolArray(value, in: buffer), fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedStringField(value: [String], fieldNumber: Int) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .array(let element) = kind, case .string = element else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<string>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let encoded = try _ProtoCacheEncoding.array(
            elementCount: value.count, in: buffer, since: start
        ) { elements in
            for index in value.indices {
                elements[index] = try _ProtoCacheEncoding.string(value[index], in: buffer)
            }
        }
        store(encoded, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedBytesField(value: [Data], fieldNumber: Int) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .array(let element) = kind, case .bytes = element else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<bytes>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let encoded = try _ProtoCacheEncoding.array(
            elementCount: value.count, in: buffer, since: start
        ) { elements in
            for index in value.indices {
                elements[index] = try value[index].withUnsafeBytes {
                    try _ProtoCacheEncoding.bytes($0, in: buffer)
                }
            }
        }
        store(encoded, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedEnumField<E: SwiftProtobuf.Enum>(value: [E], fieldNumber: Int) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .array(let element) = kind, case .enumeration = element else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<enum>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let encoded = try _ProtoCacheEncoding.array(
            elementCount: value.count, in: buffer, since: start
        ) { elements in
            for index in value.indices {
                elements[index] = _ProtoCacheEncoding.scalar(
                    Int32(truncatingIfNeeded: value[index].rawValue)
                )
            }
        }
        store(encoded, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedMessageField<M: Message>(value: [M], fieldNumber: Int) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .array(let element) = kind, case .message(let nestedLayout) = element else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<message>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let childLayout = nestedLayout()
        let encoded = try _ProtoCacheEncoding.array(
            elementCount: value.count, in: buffer, since: start
        ) { elements in
            for index in value.indices {
                elements[index] = try encode(
                    value[index], layout: childLayout, buffer: buffer, depth: depth + 1
                ).unit
            }
        }
        store(encoded, fieldNumber: fieldNumber)
    }

    mutating func visitMapField<KeyType, ValueType: MapValueType>(
        fieldType: _ProtobufMap<KeyType, ValueType>.Type,
        value: _ProtobufMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        try encodeMap(value, fieldNumber: fieldNumber) { key, item, encoder in
            try KeyType.visitSingular(value: key, fieldNumber: 1, with: &encoder)
            try ValueType.visitSingular(value: item, fieldNumber: 2, with: &encoder)
        }
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufEnumMap<KeyType, ValueType>.Type,
        value: _ProtobufEnumMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws where ValueType.RawValue == Int {
        try encodeMap(value, fieldNumber: fieldNumber) { key, item, encoder in
            try KeyType.visitSingular(value: key, fieldNumber: 1, with: &encoder)
            try encoder.visitSingularEnumField(value: item, fieldNumber: 2)
        }
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufMessageMap<KeyType, ValueType>.Type,
        value: _ProtobufMessageMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        try encodeMap(value, fieldNumber: fieldNumber) { key, item, encoder in
            try KeyType.visitSingular(value: key, fieldNumber: 1, with: &encoder)
            try encoder.visitSingularMessageField(value: item, fieldNumber: 2)
        }
    }

    mutating func encodeMap<K: Hashable, V>(
        _ value: [K: V],
        fieldNumber: Int,
        encodeEntry: (K, V, inout Encoder) throws -> Void
    ) throws {
        guard let kind = kind(fieldNumber) else { return }
        guard case .map(let keyKind, let valueKind) = kind else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected map")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let encoded = try _ProtoCacheEncoding.map(
            entryCount: value.count, in: buffer, since: start
        ) { entries in
            try withUnsafeTemporaryAllocation(of: Unit.self, capacity: 2) { units in
                units.initialize(repeating: .empty)
                defer { units.deinitialize() }
                var entryIndex = 0
                for (key, item) in value {
                    units[0] = .empty
                    units[1] = .empty
                    var encoder = try Encoder(
                        keyKind: keyKind,
                        valueKind: valueKind,
                        buffer: buffer,
                        depth: depth + 1,
                        units: units
                    )
                    try encodeEntry(key, item, &encoder)
                    guard let keyBytes = encoder.keyBytes else {
                        throw ProtoCacheError.typeMismatch(
                            "unsupported map key at field \(fieldNumber)"
                        )
                    }
                    entries[entryIndex] = _ProtoCacheMapEntry(
                        key: keyBytes, keyUnit: units[0], valueUnit: units[1]
                    )
                    entryIndex += 1
                }
            }
        }
        store(encoded, fieldNumber: fieldNumber)
    }

    mutating func visitExtensionFields(fields: ExtensionFieldValueSet, start: Int, end: Int) throws {}
    mutating func visitUnknown(bytes: Data) throws {}
}
