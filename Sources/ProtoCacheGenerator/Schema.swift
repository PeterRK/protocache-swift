extension Generator {
    struct SchemaIndex {
        var messages: [String: MessageProto] = [:]

        init(files: [FileProto]) {
            for file in files {
                let scope = file.package.isEmpty ? "" : ".\(file.package)"
                for message in file.messageType { add(message, scope: scope) }
            }
        }

        mutating func add(_ message: MessageProto, scope: String) {
            let fullName = "\(scope).\(message.name)"
            messages[fullName] = message
            for nested in message.nestedType { add(nested, scope: fullName) }
        }
    }

    static func validate(file: FileProto, index: SchemaIndex) throws {
        guard file.syntax == "proto3" else {
            throw GenError.schema("\(file.name): only proto3 syntax is supported")
        }
        guard file.service.isEmpty else {
            throw GenError.schema("\(file.name): services/RPC are not supported")
        }
        guard file.`extension`.isEmpty else {
            throw GenError.schema("\(file.name): extensions are not supported")
        }
        let scope = file.package.isEmpty ? "" : ".\(file.package)"
        for message in file.messageType {
            try validate(message: message, fullName: "\(scope).\(message.name)", index: index)
        }
    }

    static func validate(message: MessageProto, fullName: String, index: SchemaIndex) throws {
        if message.options.mapEntry || message.options.deprecated { return }
        guard message.`extension`.isEmpty && message.extensionRange.isEmpty else {
            throw GenError.schema("\(fullName): extensions are not supported")
        }
        let alias = isAlias(message)
        guard alias || !message.field.isEmpty else {
            throw GenError.schema("\(fullName): empty ordinary message")
        }
        var numbers = Set<Int32>()
        var names = Set<String>()
        let declared = message.field
        for field in declared {
            guard (1...6387).contains(field.number) else {
                throw GenError.schema("\(fullName).\(field.name): field number outside 1...6387")
            }
            guard numbers.insert(field.number).inserted,
                  names.insert(field.name).inserted else {
                throw GenError.schema("\(fullName).\(field.name): duplicate name or number")
            }
            if field.name == "_" && !alias {
                throw GenError.schema("\(fullName)._ is reserved for alias messages")
            }
            try validate(field: field, owner: fullName, index: index)
        }
        if alias {
            let field = declared[0]
            guard field.number == 1 && field.label == .repeated else {
                throw GenError.schema("\(fullName): alias '_' must be repeated field 1")
            }
        } else if let maximum = declared.map(\.number).max() {
            let count = Int32(declared.count)
            guard maximum - count <= 6 || maximum <= count * 2 else {
                throw GenError.schema("\(fullName): fields violate ProtoCache density rule")
            }
        }
        for nested in message.nestedType where !nested.options.mapEntry {
            try validate(message: nested, fullName: "\(fullName).\(nested.name)", index: index)
        }
    }

    static func validate(field: FieldProto, owner: String, index: SchemaIndex) throws {
        guard field.label != .required else {
            throw GenError.schema("\(owner).\(field.name): required fields are unsupported")
        }
        guard field.type != .group else {
            throw GenError.schema("\(owner).\(field.name): groups are unsupported")
        }
        if field.type == .message,
           let target = index.messages[field.typeName],
           target.options.mapEntry {
            guard target.field.count == 2 else {
                throw GenError.schema("\(owner).\(field.name): invalid map entry")
            }
            guard mapKeyType(target.field[0].type) != nil else {
                throw GenError.schema("\(owner).\(field.name): unsupported map key")
            }
        }
    }

    static func readType(_ field: FieldProto) throws -> String {
        switch field.type {
        case .double: "Double"
        case .float: "Float"
        case .int64, .sint64, .sfixed64: "Int64"
        case .uint64, .fixed64: "UInt64"
        case .int32, .sint32, .sfixed32: "Int32"
        case .uint32, .fixed32: "UInt32"
        case .bool: "Bool"
        case .string: "StringView"
        case .bytes: "BytesView"
        case .enum: "\(swiftType(field.typeName))Value"
        case .message: "\(swiftType(field.typeName))View"
        default: throw GenError.schema("unsupported field type \(field.type)")
        }
    }

    static func metadataKind(_ field: FieldProto, index: SchemaIndex) throws -> String {
        if let entry = mapEntry(field, index: index) {
            return ".map(key: \(try baseMetadataKind(entry.field[0])), value: \(try baseMetadataKind(entry.field[1])))"
        }
        let base = try baseMetadataKind(field)
        return field.label == .repeated ? ".array(\(base))" : base
    }

    static func baseMetadataKind(_ field: FieldProto) throws -> String {
        switch field.type {
        case .double: ".scalar(.double)"
        case .float: ".scalar(.float)"
        case .int64, .sint64, .sfixed64: ".scalar(.int64)"
        case .uint64, .fixed64: ".scalar(.uint64)"
        case .int32, .sint32, .sfixed32: ".scalar(.int32)"
        case .uint32, .fixed32: ".scalar(.uint32)"
        case .bool: ".scalar(.bool)"
        case .string: ".string"
        case .bytes: ".bytes"
        case .enum: ".enumeration"
        case .message: ".message({ \(swiftType(field.typeName))View._protoCacheLayout })"
        default: throw GenError.schema("unsupported field type")
        }
    }

    static func mapEntry(_ field: FieldProto, index: SchemaIndex) -> MessageProto? {
        guard field.type == .message,
              let message = index.messages[field.typeName],
              message.options.mapEntry else { return nil }
        return message
    }

    static func mapKeyType(_ type: FieldProto.TypeEnum) -> String? {
        switch type {
        case .string, .int32, .sint32, .sfixed32, .uint32, .fixed32,
             .int64, .sint64, .sfixed64, .uint64, .fixed64:
            "ok"
        default:
            nil
        }
    }

    static func isAlias(_ message: MessageProto) -> Bool {
        message.field.count == 1 && message.field[0].name == "_"
    }

    static func activeFields(_ message: MessageProto) -> [FieldProto] {
        message.field.filter { !$0.options.deprecated }.sorted { $0.number < $1.number }
    }

    static func outputName(_ input: String, suffix: String) -> String {
        input.hasSuffix(".proto") ? String(input.dropLast(6)) + suffix : input + suffix
    }

    static func trimDot(_ value: String) -> String {
        value.first == "." ? String(value.dropFirst()) : value
    }

    static func swiftType(_ fullName: String) -> String {
        trimDot(fullName).split(separator: ".").map { pascal(String($0)) }.joined(separator: "_")
    }

    static func pascal(_ value: String) -> String {
        value.split(separator: "_").map { part in
            let text = String(part)
            let normalized = text == text.uppercased() ? text.lowercased() : text
            return normalized.prefix(1).uppercased() + normalized.dropFirst()
        }.joined()
    }

    static func lowerCamel(_ value: String) -> String {
        let value = pascal(value)
        return value.prefix(1).lowercased() + value.dropFirst()
    }

    static func identifier(_ value: String) -> String {
        let keywords: Set<String> = [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
            "import", "init", "inout", "internal", "let", "open", "operator", "private",
            "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias",
            "var", "break", "case", "continue", "default", "defer", "do", "else",
            "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where",
            "while", "as", "Any", "catch", "false", "is", "nil", "super", "self", "Self",
            "throw", "throws", "true", "try",
        ]
        return keywords.contains(value) ? "`\(value)`" : value
    }
}
