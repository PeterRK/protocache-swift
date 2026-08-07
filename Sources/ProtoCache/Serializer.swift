import Foundation
import ProtoCacheCore
import SwiftProtobuf

public enum ProtoCache {
    public static func serialize<M: Message, View: GeneratedView>(
        _ message: borrowing M,
        as viewType: View.Type
    ) throws -> ProtoCacheBytes where View: ~Escapable {
        let layout = viewType._protoCacheLayout
        guard layout.runtimeABI == 1 else {
            throw ProtoCacheError.invalidSchema("unsupported generated runtime ABI \(layout.runtimeABI)")
        }
        guard M.protoMessageName == layout.fullName else {
            throw ProtoCacheError.typeMismatch("message \(M.protoMessageName) does not match \(layout.fullName)")
        }
        let buffer = _ProtoCacheBuffer()
        let encoded = try _encodeMessage(message, layout: layout, buffer: buffer, depth: 0)
        return try buffer.finish(encoded.unit)
    }
}

private let _protoCacheMaximumRecursionDepth = 100

private struct _EncodedMessage {
    var unit: _ProtoCacheUnit
    var isEmpty: Bool
}

private func _encodeMessage<M: Message>(
    _ message: borrowing M,
    layout: _ProtoCacheLayout,
    buffer: _ProtoCacheBuffer,
    depth: Int
) throws -> _EncodedMessage {
    guard depth <= _protoCacheMaximumRecursionDepth else { throw ProtoCacheError.recursionLimitExceeded }
    guard M.protoMessageName == layout.fullName else {
        throw ProtoCacheError.typeMismatch("nested message \(M.protoMessageName) does not match \(layout.fullName)")
    }
    var visitor = try _ProtoCacheVisitor(layout: layout, buffer: buffer, depth: depth, omitDefaults: true)
    try message.traverse(visitor: &visitor)
    return try visitor.finish()
}

private struct _ProtoCacheVisitor: Visitor {
    let layout: _ProtoCacheLayout
    let buffer: _ProtoCacheBuffer
    let depth: Int
    let checkpoint: Int
    let omitDefaults: Bool
    let captureKeyField: Int?
    var fieldsByNumber: [Int: _ProtoCacheFieldLayout]
    var units: [_ProtoCacheUnit]
    var canonicalKey: [UInt8]?

    init(
        layout: _ProtoCacheLayout,
        buffer: _ProtoCacheBuffer,
        depth: Int,
        omitDefaults: Bool,
        captureKeyField: Int? = nil
    ) throws {
        guard layout.runtimeABI == 1 else {
            throw ProtoCacheError.invalidSchema("unsupported generated runtime ABI \(layout.runtimeABI)")
        }
        var index: [Int: _ProtoCacheFieldLayout] = [:]
        var maximum = 1
        for field in layout.fields {
            guard (1...6387).contains(field.number), index[field.number] == nil else {
                throw ProtoCacheError.invalidSchema("invalid or duplicate field \(field.number) in \(layout.fullName)")
            }
            index[field.number] = field
            maximum = max(maximum, field.number)
        }
        self.layout = layout
        self.buffer = buffer
        self.depth = depth
        self.checkpoint = buffer.checkpoint
        self.omitDefaults = omitDefaults
        self.captureKeyField = captureKeyField
        self.fieldsByNumber = index
        self.units = [_ProtoCacheUnit](repeating: .empty, count: maximum)
        self.canonicalKey = nil
    }

    mutating func finish() throws -> _EncodedMessage {
        let isEmpty = !units.contains { !$0.isEmpty }
        if layout.isAlias {
            guard let field = fieldsByNumber[1] else { throw ProtoCacheError.invalidSchema("alias has no field 1") }
            if !units[0].isEmpty { return _EncodedMessage(unit: units[0], isEmpty: false) }
            switch field.kind {
            case .array:
                return _EncodedMessage(unit: try _ProtoCacheEncoding.array([], in: buffer, since: checkpoint), isEmpty: true)
            case .map:
                return _EncodedMessage(
                    unit: try _ProtoCacheEncoding.map(keys: [], keyUnits: [], valueUnits: [], in: buffer, since: checkpoint),
                    isEmpty: true
                )
            default:
                throw ProtoCacheError.invalidSchema("alias field is not an array or map")
            }
        }
        return _EncodedMessage(
            unit: try _ProtoCacheEncoding.message(&units, in: buffer, since: checkpoint),
            isEmpty: isEmpty
        )
    }

    func field(_ number: Int) -> _ProtoCacheFieldLayout? { fieldsByNumber[number] }

    mutating func store(_ unit: _ProtoCacheUnit, fieldNumber: Int) {
        var unit = unit
        _ProtoCacheEncoding.fold(&unit, in: buffer)
        units[fieldNumber - 1] = unit
    }

    func scalarKind(_ fieldNumber: Int, expected: _ProtoCacheScalarKind) throws -> Bool {
        guard let field = field(fieldNumber) else { return false }
        guard case .scalar(let actual) = field.kind, actual == expected else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected \(expected.rawValue)")
        }
        return true
    }

    mutating func recordIntegerKey<T: FixedWidthInteger>(_ value: T, fieldNumber: Int) {
        guard captureKeyField == fieldNumber else { return }
        var copy = value.littleEndian
        canonicalKey = Swift.withUnsafeBytes(of: &copy) { Array($0) }
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
        recordIntegerKey(value, fieldNumber: fieldNumber)
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .int64) else { return }
        recordIntegerKey(value, fieldNumber: fieldNumber)
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularUInt32Field(value: UInt32, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .uint32) else { return }
        recordIntegerKey(value, fieldNumber: fieldNumber)
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .uint64) else { return }
        recordIntegerKey(value, fieldNumber: fieldNumber)
        if omitDefaults && value == 0 { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {
        guard try scalarKind(fieldNumber, expected: .bool) else { return }
        if captureKeyField == fieldNumber { canonicalKey = [value ? 1 : 0] }
        if omitDefaults && !value { return }
        store(_ProtoCacheEncoding.scalar(value), fieldNumber: fieldNumber)
    }

    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .string = field.kind else { throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected string") }
        if captureKeyField == fieldNumber { canonicalKey = Array(value.utf8) }
        if omitDefaults && value.isEmpty { return }
        store(try _ProtoCacheEncoding.string(value, in: buffer), fieldNumber: fieldNumber)
    }

    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .bytes = field.kind else { throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected bytes") }
        if omitDefaults && value.isEmpty { return }
        let unit = try value.withUnsafeBytes { try _ProtoCacheEncoding.bytes($0, in: buffer) }
        store(unit, fieldNumber: fieldNumber)
    }

    mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .enumeration = field.kind else { throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected enum") }
        let raw = Int32(truncatingIfNeeded: value.rawValue)
        if omitDefaults && raw == 0 { return }
        store(_ProtoCacheEncoding.scalar(raw), fieldNumber: fieldNumber)
    }

    mutating func visitSingularMessageField<M: Message>(value: M, fieldNumber: Int) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .message(let nestedLayout) = field.kind else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected message")
        }
        let encoded = try _encodeMessage(value, layout: nestedLayout(), buffer: buffer, depth: depth + 1)
        if omitDefaults && encoded.isEmpty { return }
        store(encoded.unit, fieldNumber: fieldNumber)
    }

    mutating func repeatedScalar<T: ProtoCacheScalar>(
        _ value: [T], fieldNumber: Int, expected: _ProtoCacheScalarKind
    ) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .array(let element) = field.kind, case .scalar(let actual) = element(), actual == expected else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<\(expected.rawValue)>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        store(try _ProtoCacheEncoding.array(value.map(_ProtoCacheEncoding.scalar), in: buffer, since: start), fieldNumber: fieldNumber)
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
        guard let field = field(fieldNumber) else { return }
        guard case .array(let element) = field.kind, case .scalar(.bool) = element() else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<bool>")
        }
        guard !value.isEmpty else { return }
        store(try _ProtoCacheEncoding.boolArray(value, in: buffer), fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedStringField(value: [String], fieldNumber: Int) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .array(let element) = field.kind, case .string = element() else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<string>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let elements = try value.map { try _ProtoCacheEncoding.string($0, in: buffer) }
        store(try _ProtoCacheEncoding.array(elements, in: buffer, since: start), fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedBytesField(value: [Data], fieldNumber: Int) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .array(let element) = field.kind, case .bytes = element() else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<bytes>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let elements = try value.map { data in try data.withUnsafeBytes { try _ProtoCacheEncoding.bytes($0, in: buffer) } }
        store(try _ProtoCacheEncoding.array(elements, in: buffer, since: start), fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedEnumField<E: SwiftProtobuf.Enum>(value: [E], fieldNumber: Int) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .array(let element) = field.kind, case .enumeration = element() else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<enum>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let elements = value.map { _ProtoCacheEncoding.scalar(Int32(truncatingIfNeeded: $0.rawValue)) }
        store(try _ProtoCacheEncoding.array(elements, in: buffer, since: start), fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedMessageField<M: Message>(value: [M], fieldNumber: Int) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .array(let element) = field.kind, case .message(let nestedLayout) = element() else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected array<message>")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let childLayout = nestedLayout()
        let elements = try value.map { try _encodeMessage($0, layout: childLayout, buffer: buffer, depth: depth + 1).unit }
        store(try _ProtoCacheEncoding.array(elements, in: buffer, since: start), fieldNumber: fieldNumber)
    }

    mutating func visitMapField<KeyType, ValueType: MapValueType>(
        fieldType: _ProtobufMap<KeyType, ValueType>.Type,
        value: _ProtobufMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        try encodeMap(value, fieldNumber: fieldNumber) { key, item, visitor in
            try KeyType.visitSingular(value: key, fieldNumber: 1, with: &visitor)
            try ValueType.visitSingular(value: item, fieldNumber: 2, with: &visitor)
        }
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufEnumMap<KeyType, ValueType>.Type,
        value: _ProtobufEnumMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws where ValueType.RawValue == Int {
        try encodeMap(value, fieldNumber: fieldNumber) { key, item, visitor in
            try KeyType.visitSingular(value: key, fieldNumber: 1, with: &visitor)
            try visitor.visitSingularEnumField(value: item, fieldNumber: 2)
        }
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufMessageMap<KeyType, ValueType>.Type,
        value: _ProtobufMessageMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        try encodeMap(value, fieldNumber: fieldNumber) { key, item, visitor in
            try KeyType.visitSingular(value: key, fieldNumber: 1, with: &visitor)
            try visitor.visitSingularMessageField(value: item, fieldNumber: 2)
        }
    }

    mutating func encodeMap<K: Hashable, V>(
        _ value: [K: V],
        fieldNumber: Int,
        encodeEntry: (K, V, inout _ProtoCacheVisitor) throws -> Void
    ) throws {
        guard let field = field(fieldNumber) else { return }
        guard case .map(let keyKind, let valueKind) = field.kind else {
            throw ProtoCacheError.typeMismatch("field \(fieldNumber) expected map")
        }
        guard !value.isEmpty else { return }
        let start = buffer.checkpoint
        let entryLayout = _ProtoCacheLayout(fullName: "", fields: [
            _ProtoCacheFieldLayout(number: 1, protoName: "key", kind: keyKind()),
            _ProtoCacheFieldLayout(number: 2, protoName: "value", kind: valueKind()),
        ])
        var entries: [(key: [UInt8], keyUnit: _ProtoCacheUnit, valueUnit: _ProtoCacheUnit)] = []
        entries.reserveCapacity(value.count)
        for (key, item) in value {
            var visitor = try _ProtoCacheVisitor(
                layout: entryLayout, buffer: buffer, depth: depth + 1,
                omitDefaults: false, captureKeyField: 1
            )
            try encodeEntry(key, item, &visitor)
            guard let bytes = visitor.canonicalKey else {
                throw ProtoCacheError.typeMismatch("unsupported map key at field \(fieldNumber)")
            }
            entries.append((bytes, visitor.units[0], visitor.units[1]))
        }
        entries.sort { $0.key.lexicographicallyPrecedes($1.key) }
        store(try _ProtoCacheEncoding.map(
            keys: entries.map(\.key),
            keyUnits: entries.map(\.keyUnit),
            valueUnits: entries.map(\.valueUnit),
            in: buffer,
            since: start
        ), fieldNumber: fieldNumber)
    }

    mutating func visitExtensionFields(fields: ExtensionFieldValueSet, start: Int, end: Int) throws {}
    mutating func visitUnknown(bytes: Data) throws {}
}
