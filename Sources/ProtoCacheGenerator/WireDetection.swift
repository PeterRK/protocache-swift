extension Generator {
    static func detectValue(
        _ field: FieldProto,
        source: String,
        depth: String,
        index: SchemaIndex
    ) throws -> String {
        if let entry = mapEntry(field, index: index) {
            let keyReferenced = isBaseReference(entry.field[0])
            let valueReferenced = isBaseReference(entry.field[1])
            let keyDetector = keyReferenced
                ? "{ child in \(try detectBase(entry.field[0], source: "child", depth: "\(depth) + 1")) }"
                : "{ _ in 0 }"
            let valueDetector = valueReferenced
                ? "{ child in \(try detectBase(entry.field[1], source: "child", depth: "\(depth) + 1")) }"
                : "{ _ in 0 }"
            return "try _ProtoCacheEncoding._detectMapWords(\(source), keyIsReferenced: \(keyReferenced), detectKey: \(keyDetector), valueIsReferenced: \(valueReferenced), detectValue: \(valueDetector))"
        }
        if field.label == .repeated {
            if field.type == .bool {
                return "try _ProtoCacheEncoding._detectStringWords(\(source))"
            }
            guard isBaseReference(field) else {
                return "try _ProtoCacheEncoding._detectArrayBaseWords(\(source))"
            }
            let element = try detectBase(
                field,
                source: "child",
                depth: "\(depth) + 1"
            )
            return "try _ProtoCacheEncoding._detectArrayWords(\(source)) { child in \(element) }"
        }
        return try detectBase(field, source: source, depth: depth)
    }

    static func detectBase(
        _ field: FieldProto,
        source: String,
        depth: String
    ) throws -> String {
        switch field.type {
        case .string, .bytes:
            return "try _ProtoCacheEncoding._detectStringWords(\(source))"
        case .message:
            return "try \(swiftType(field.typeName))View._detectProtoCacheWords(\(source), depth: \(depth))"
        case .double, .float, .int64, .uint64, .int32, .uint32, .fixed64, .fixed32,
             .bool, .enum, .sfixed32, .sfixed64, .sint32, .sint64:
            return "1"
        default:
            throw GenError.schema("unsupported field type \(field.type)")
        }
    }

    static func isReference(_ field: FieldProto, index: SchemaIndex) -> Bool {
        mapEntry(field, index: index) != nil || field.label == .repeated || isBaseReference(field)
    }

    static func isBaseReference(_ field: FieldProto) -> Bool {
        field.type == .string || field.type == .bytes || field.type == .message
    }
}
