import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

enum GeneratorFailure: Error, CustomStringConvertible {
    case schema(String)
    var description: String { switch self { case .schema(let message): message } }
}

struct ProtoCacheSwiftGenerator {
    typealias Request = Google_Protobuf_Compiler_CodeGeneratorRequest
    typealias Response = Google_Protobuf_Compiler_CodeGeneratorResponse
    typealias FileProto = Google_Protobuf_FileDescriptorProto
    typealias MessageProto = Google_Protobuf_DescriptorProto
    typealias FieldProto = Google_Protobuf_FieldDescriptorProto
    typealias EnumProto = Google_Protobuf_EnumDescriptorProto

    static func generate(_ request: Request) -> Response {
        var response = Response()
        response.supportedFeatures = UInt64(Response.Feature.proto3Optional.rawValue)
        do {
            guard request.parameter.isEmpty || request.parameter == "extra" else {
                throw GeneratorFailure.schema("unsupported parameter '\(request.parameter)'; expected empty or 'extra'")
            }
            let requested = Set(request.fileToGenerate)
            let index = SchemaIndex(files: request.protoFile)
            for file in request.protoFile where requested.contains(file.name) {
                try validate(file: file, index: index)
                var output = Response.File()
                output.name = outputName(file.name, suffix: ".pc.swift")
                output.content = try renderReadonly(file: file, index: index)
                response.file.append(output)
                if request.parameter == "extra" {
                    var extra = Response.File()
                    extra.name = outputName(file.name, suffix: ".pc-ex.swift")
                    extra.content = try renderExtra(file: file, index: index)
                    response.file.append(extra)
                }
            }
        } catch {
            response.error = String(describing: error)
            response.file.removeAll()
        }
        return response
    }

    private struct SchemaIndex {
        var messages: [String: MessageProto] = [:]
        var enums: [String: EnumProto] = [:]

        init(files: [FileProto]) {
            for file in files {
                let scope = file.package.isEmpty ? "" : ".\(file.package)"
                for message in file.messageType { add(message, scope: scope) }
                for item in file.enumType { enums["\(scope).\(item.name)"] = item }
            }
        }

        mutating func add(_ message: MessageProto, scope: String) {
            let fullName = "\(scope).\(message.name)"
            messages[fullName] = message
            for nested in message.nestedType { add(nested, scope: fullName) }
            for item in message.enumType { enums["\(fullName).\(item.name)"] = item }
        }
    }

    private static func validate(file: FileProto, index: SchemaIndex) throws {
        guard file.syntax == "proto3" else { throw GeneratorFailure.schema("\(file.name): only proto3 syntax is supported") }
        guard file.service.isEmpty else { throw GeneratorFailure.schema("\(file.name): services/RPC are not supported") }
        guard file.`extension`.isEmpty else { throw GeneratorFailure.schema("\(file.name): extensions are not supported") }
        let scope = file.package.isEmpty ? "" : ".\(file.package)"
        for message in file.messageType { try validate(message: message, fullName: "\(scope).\(message.name)", index: index) }
    }

    private static func validate(message: MessageProto, fullName: String, index: SchemaIndex) throws {
        if message.options.mapEntry || message.options.deprecated { return }
        guard message.`extension`.isEmpty && message.extensionRange.isEmpty else { throw GeneratorFailure.schema("\(fullName): extensions are not supported") }
        let alias = isAlias(message)
        guard alias || !message.field.isEmpty else { throw GeneratorFailure.schema("\(fullName): empty ordinary message") }
        var numbers = Set<Int32>()
        var names = Set<String>()
        let declared = message.field
        for field in declared {
            guard (1...6387).contains(field.number) else { throw GeneratorFailure.schema("\(fullName).\(field.name): field number outside 1...6387") }
            guard numbers.insert(field.number).inserted, names.insert(field.name).inserted else { throw GeneratorFailure.schema("\(fullName).\(field.name): duplicate name or number") }
            if field.name == "_" && !alias { throw GeneratorFailure.schema("\(fullName)._ is reserved for alias messages") }
            try validate(field: field, owner: fullName, index: index)
        }
        if alias {
            let field = declared[0]
            guard field.number == 1 && field.label == .repeated else { throw GeneratorFailure.schema("\(fullName): alias '_' must be repeated field 1") }
        } else if let maximum = declared.map(\.number).max() {
            let count = Int32(declared.count)
            guard maximum - count <= 6 || maximum <= count * 2 else { throw GeneratorFailure.schema("\(fullName): fields violate ProtoCache density rule") }
        }
        for nested in message.nestedType where !nested.options.mapEntry {
            try validate(message: nested, fullName: "\(fullName).\(nested.name)", index: index)
        }
    }

    private static func validate(field: FieldProto, owner: String, index: SchemaIndex) throws {
        guard field.label != .required else { throw GeneratorFailure.schema("\(owner).\(field.name): required fields are unsupported") }
        guard field.type != .group else { throw GeneratorFailure.schema("\(owner).\(field.name): groups are unsupported") }
        if field.type == .message, let target = index.messages[field.typeName], target.options.mapEntry {
            guard target.field.count == 2 else { throw GeneratorFailure.schema("\(owner).\(field.name): invalid map entry") }
            guard mapKeyType(target.field[0].type) != nil else { throw GeneratorFailure.schema("\(owner).\(field.name): unsupported map key") }
        }
    }

    private static func renderReadonly(file: FileProto, index: SchemaIndex) throws -> String {
        var output = "// Generated by protoc-gen-pcsw. DO NOT EDIT.\nimport ProtoCacheCore\n\n"
        let scope = file.package.isEmpty ? "" : ".\(file.package)"
        for item in file.enumType where !item.options.deprecated { output += render(enum: item, fullName: "\(scope).\(item.name)") }
        for message in file.messageType where !message.options.deprecated {
            output += try renderReadonly(message: message, fullName: "\(scope).\(message.name)", index: index)
        }
        return String(output.dropLast())
    }

    private static func render(enum item: EnumProto, fullName: String) -> String {
        let name = "\(swiftType(fullName))Value"
        var output = "public struct \(name): RawRepresentable, Hashable, Sendable, ProtoCacheDecodable {\n"
        output += "    public let rawValue: Int32\n    @inlinable @inline(__always) public init(rawValue: Int32) { self.rawValue = rawValue }\n"
        for value in item.value where !value.options.deprecated {
            output += "    public static let \(identifier(lowerCamel(value.name))) = Self(rawValue: \(value.number))\n"
        }
        output += "    @inlinable @inline(__always) public static func _decodeProtoCache(from field: FieldView) -> Self? { guard let value = field.scalar(Int32.self) else { return nil }; return Self(rawValue: value) }\n"
        output += "    @inlinable @inline(__always) public static func _decodeProtoCache(fromRawWords baseAddress: UnsafeRawPointer, availableByteCount: Int, width: Int, owner: borrowing Span) -> Self? { guard let value = Int32._decodeProtoCache(fromRawWords: baseAddress, availableByteCount: availableByteCount, width: width, owner: owner) else { return nil }; return Self(rawValue: value) }\n}\n\n"
        return output
    }

    private static func renderReadonly(message: MessageProto, fullName: String, index: SchemaIndex) throws -> String {
        if message.options.mapEntry { return "" }
        var output = ""
        for item in message.enumType where !item.options.deprecated { output += render(enum: item, fullName: "\(fullName).\(item.name)") }
        for nested in message.nestedType where !nested.options.deprecated && !nested.options.mapEntry {
            output += try renderReadonly(message: nested, fullName: "\(fullName).\(nested.name)", index: index)
        }
        let name = "\(swiftType(fullName))View"
        if isAlias(message) {
            let field = message.field[0]
            if let entry = mapEntry(field, index: index) {
                let key = try readType(entry.field[0], index: index, repeatedElement: true)
                let value = try readType(entry.field[1], index: index, repeatedElement: true)
                output += "public struct \(name): ~Escapable, GeneratedView {\n"
                output += "    public typealias Key = \(key)\n    public typealias Value = \(value)\n"
                output += "    private let _value: MapView<Key, Value>\n"
                output += generatedViewStorage(for: "_value._protoCacheSpan", initializer: "_value = MapView(bytes)")
                output += "    public var count: Int { _value.count }\n    public var isEmpty: Bool { _value.isEmpty }\n"
                output += aliasMapAccessor(name: "key", type: "Key", borrowed: isBorrowed(entry.field[0]))
                output += aliasMapAccessor(name: "value", type: "Value", borrowed: isBorrowed(entry.field[1]))
                output += "    @_lifetime(copy self) public func value(for key: borrowing Key) -> Value? { _value.value(for: key) }\n"
                output += "    public func forEach(_ body: (borrowing Key, borrowing Value) throws -> Void) rethrows { try _value.forEach(body) }\n"
                if entry.field[0].type == .string {
                    output += "    @_lifetime(copy self) public func value(for key: String) -> Value? { guard let position = _value.position(for: key) else { return nil }; return _value.value(at: position) }\n"
                }
            } else {
                output += "public struct \(name): ~Escapable, GeneratedView {\n"
                output += "    public typealias Element = \(try readType(field, index: index, repeatedElement: true))\n"
                output += "    private let _value: ArrayView<Element>\n"
                output += generatedViewStorage(for: "_value._protoCacheSpan", initializer: "_value = ArrayView(bytes)")
                output += "    public var count: Int { _value.count }\n    public var isEmpty: Bool { _value.isEmpty }\n"
                if isBorrowed(field) {
                    output += "    public subscript(position: Int) -> Element { @_lifetime(copy self) borrowing get { _value[position] } }\n"
                } else {
                    output += "    public subscript(position: Int) -> Element { _value[position] }\n"
                }
                output += "    public func forEach(_ body: (borrowing Element) throws -> Void) rethrows { try _value.forEach(body) }\n"
            }
            output += "    public static var _protoCacheLayout: _ProtoCacheLayout { _ProtoCacheLayout(fullName: \"\(trimDot(fullName))\", fields: [\n"
            output += "        _ProtoCacheFieldLayout(number: 1, protoName: \"_\", kind: \(try metadataKind(field, index: index))),\n    ], isAlias: true) }\n}\n\n"
            return output
        }
        let fields = activeFields(message)
        output += "public struct \(name): ~Escapable, GeneratedView {\n"
        output += "    public let _protoCacheMessageView: MessageView\n"
        output += generatedViewStorage(for: "_protoCacheMessageView.bytes", initializer: "_protoCacheMessageView = MessageView(bytes)", inline: true)
        if !fields.isEmpty {
            output += "    public enum Field: Int, Sendable {\n"
            for field in fields { output += "        case \(identifier(lowerCamel(field.name))) = \(field.number - 1)\n" }
            output += "    }\n    @inlinable @inline(__always) public func hasField(_ field: Field) -> Bool { _protoCacheMessageView.hasField(field.rawValue) }\n"
        }
        for field in fields { output += try renderGetter(field, index: index) }
        output += "    public static var _protoCacheLayout: _ProtoCacheLayout { _ProtoCacheLayout(\n        fullName: \"\(trimDot(fullName))\",\n        fields: [\n"
        for field in fields {
            output += "            _ProtoCacheFieldLayout(number: \(field.number), protoName: \"\(field.name)\", kind: \(try metadataKind(field, index: index))),\n"
        }
        output += "        ]\n    ) }\n}\n\n"
        return output
    }

    private static func generatedViewStorage(for span: String, initializer: String, inline: Bool = false) -> String {
        let attributes = inline ? "@inlinable @inline(__always) " : ""
        return "    public var _protoCacheSpan: Span { @_lifetime(borrow self) borrowing get { \(span) } }\n" +
            "    @_lifetime(copy bytes) \(attributes)public init(_ bytes: Span) { \(initializer) }\n" +
            "    @_lifetime(copy field) \(attributes)public static func _decodeProtoCache(from field: FieldView) -> Self? { Self(field.objectBytes) }\n" +
            "    @_lifetime(copy owner) \(attributes)public static func _decodeProtoCache(fromRawWords baseAddress: UnsafeRawPointer, availableByteCount: Int, width: Int, owner: borrowing Span) -> Self? { guard let bytes = _protoCacheObjectBytes(fromRawWords: baseAddress, availableByteCount: availableByteCount, width: width, owner: owner) else { return nil }; return Self(bytes) }\n"
    }

    private static func renderGetter(_ field: FieldProto, index: SchemaIndex) throws -> String {
        let property = identifier(lowerCamel(field.name)), id = field.number - 1
        if let entry = mapEntry(field, index: index) {
            let key = try readType(entry.field[0], index: index, repeatedElement: true)
            let value = try readType(entry.field[1], index: index, repeatedElement: true)
            return borrowedGetter(property, type: "MapView<\(key), \(value)>", expression: "_protoCacheMessageView.map(\(id))")
        }
        if field.label == .repeated {
            if field.type == .bool { return borrowedGetter(property, type: "BoolArrayView", expression: "BoolArrayView(_protoCacheMessageView.bytes(\(id)))") }
            let element = try readType(field, index: index, repeatedElement: true)
            return borrowedGetter(property, type: "ArrayView<\(element)>", expression: "_protoCacheMessageView.array(\(id))")
        }
        switch field.type {
        case .string: return borrowedGetter(property, type: "StringView", expression: "_protoCacheMessageView.string(\(id))")
        case .bytes: return borrowedGetter(property, type: "BytesView", expression: "_protoCacheMessageView.bytes(\(id))")
        case .message: return borrowedGetter(property, type: try readType(field, index: index, repeatedElement: true), expression: ".init(_protoCacheMessageView.message(\(id)).bytes)")
        case .enum: return "    @inlinable @inline(__always) public var \(property): \(try readType(field, index: index, repeatedElement: true)) { .init(rawValue: _protoCacheMessageView.scalar(\(id), as: Int32.self)) }\n"
        default:
            let type = try readType(field, index: index, repeatedElement: true)
            return "    @inlinable @inline(__always) public var \(property): \(type) { _protoCacheMessageView.scalar(\(id), as: \(type).self) }\n"
        }
    }

    private static func borrowedGetter(_ property: String, type: String, expression: String) -> String {
        "    @inlinable @inline(__always) public var \(property): \(type) { @_lifetime(copy self) borrowing get { \(expression) } }\n"
    }

    private static func aliasMapAccessor(name: String, type: String, borrowed: Bool) -> String {
        if borrowed {
            return "    @_lifetime(copy self) public func \(name)(at position: Int) -> \(type) { _value.\(name)(at: position) }\n"
        }
        return "    public func \(name)(at position: Int) -> \(type) { _value.\(name)(at: position) }\n"
    }

    private static func isBorrowed(_ field: FieldProto) -> Bool {
        field.type == .string || field.type == .bytes || field.type == .message
    }

    private static func renderExtra(file: FileProto, index: SchemaIndex) throws -> String {
        var output = "// Generated by protoc-gen-pcsw --pcsw_opt=extra. DO NOT EDIT.\nimport ProtoCacheCore\n\n"
        let scope = file.package.isEmpty ? "" : ".\(file.package)"
        for message in file.messageType where !message.options.deprecated && !message.options.mapEntry {
            output += try renderMutable(message: message, fullName: "\(scope).\(message.name)", index: index)
        }
        return String(output.dropLast())
    }

    private static func renderMutable(message: MessageProto, fullName: String, index: SchemaIndex) throws -> String {
        var output = ""
        for nested in message.nestedType where !nested.options.deprecated && !nested.options.mapEntry {
            output += try renderMutable(message: nested, fullName: "\(fullName).\(nested.name)", index: index)
        }
        if isAlias(message) { return output + (try renderAliasMutable(message: message, fullName: fullName, index: index)) }
        let name = "\(swiftType(fullName))Mutable"
        let view = "\(swiftType(fullName))View"
        let fields = activeFields(message)
        let slotCount = max(1, Int(fields.map(\.number).max() ?? 1))
        output += "public struct \(name): Sendable {\n"
        output += "    private var _source: ProtoCacheBytes\n    private var _accessed = _ProtoCacheAccessed(fieldCount: \(slotCount))\n"
        for field in fields {
            let property = identifier(lowerCamel(field.name))
            let type = try mutableType(field, index: index)
            if field.type == .message && field.label != .repeated && mapEntry(field, index: index) == nil {
                output += "    private var _\(property): _ProtoCacheBox<\(type)>?\n"
            } else { output += "    private var _\(property): \(type)?\n" }
        }
        output += "    public init() { _source = .empty }\n    public init(_ bytes: ProtoCacheBytes) { _source = bytes }\n"
        for field in fields { output += try renderMutableProperty(field, view: view, index: index) }
        output += "    public var _isProtoCacheEmpty: Bool {\n"
        for field in fields { output += try renderEmptyCheck(field, view: view, index: index) }
        output += "        return true\n    }\n"
        output += "    public func _encodeProtoCache(in buffer: _ProtoCacheBuffer) throws -> _ProtoCacheUnit {\n"
        output += "        if _accessed.isEmpty { return try _ProtoCacheEncoding.embedded(_source, in: buffer) }\n"
        output += "        let checkpoint = buffer.checkpoint\n        var fields = [_ProtoCacheUnit](repeating: .empty, count: \(slotCount))\n"
        for field in fields { output += try renderMutableEncoding(field, view: view, index: index) }
        output += "        return try _ProtoCacheEncoding.message(&fields, in: buffer, since: checkpoint)\n    }\n"
        output += "    public func serialized() throws -> ProtoCacheBytes {\n        let buffer = _ProtoCacheBuffer()\n        return try buffer.finish(_encodeProtoCache(in: buffer))\n    }\n"
        output += "}\n\n"
        return output
    }

    private static func renderAliasMutable(message: MessageProto, fullName: String, index: SchemaIndex) throws -> String {
        let field = message.field[0]
        let name = "\(swiftType(fullName))Mutable", view = "\(swiftType(fullName))View"
        let type = try mutableType(field, index: index)
        var output = "public struct \(name): Sendable {\n    private var _source: ProtoCacheBytes?\n    private var _value: \(type)?\n"
        output += "    public init() { _source = nil }\n    public init(_ bytes: ProtoCacheBytes) { _source = .init(bytes) }\n"
        let decoded = try aliasOwnedExpression(field, view: view, index: index)
        output += "    public var value: \(type) {\n        get { _value ?? (\(decoded)) }\n        set { _value = newValue }\n        _modify {\n            if _value == nil { _value = \(decoded) }\n            yield &_value!\n        }\n    }\n"
        output += "    public var _isProtoCacheEmpty: Bool { value.isEmpty }\n"
        output += "    public func _encodeProtoCache(in buffer: _ProtoCacheBuffer) throws -> _ProtoCacheUnit {\n"
        output += "        if _value == nil, let source = _source { return try _ProtoCacheEncoding.embedded(source, in: buffer) }\n"
        output += try renderContainerEncoding(field, value: "value", target: "return", index: index, indent: "        ")
        output += "    }\n    public func serialized() throws -> ProtoCacheBytes { let buffer = _ProtoCacheBuffer(); return try buffer.finish(_encodeProtoCache(in: buffer)) }\n}\n\n"
        return output
    }

    private static func renderMutableProperty(_ field: FieldProto, view: String, index: SchemaIndex) throws -> String {
        let property = identifier(lowerCamel(field.name)), id = field.number - 1
        let type = try mutableType(field, index: index)
        let decoded = try sourceOwnedExpression(field, view: view, property: property, index: index)
        var output = "    public var \(property): \(type) {\n"
        if field.type == .message && field.label != .repeated && mapEntry(field, index: index) == nil {
            output += "        get { _\(property)?.value ?? (\(decoded)) }\n"
            output += "        set { _\(property) = _ProtoCacheBox(newValue); _accessed.insert(\(id)) }\n"
            output += "        _modify {\n            if _\(property) == nil { _\(property) = _ProtoCacheBox(\(decoded)) }\n            var box = _\(property)!\n            _protoCacheEnsureUnique(&box)\n            _\(property) = box\n            _accessed.insert(\(id))\n            yield &_\(property)!.value\n        }\n"
        } else {
            output += "        get { _\(property) ?? (\(decoded)) }\n"
            output += "        set { _\(property) = newValue; _accessed.insert(\(id)) }\n"
            output += "        _modify {\n            if _\(property) == nil { _\(property) = \(decoded) }\n            _accessed.insert(\(id))\n            yield &_\(property)!\n        }\n"
        }
        return output + "    }\n"
    }

    private static func renderEmptyCheck(_ field: FieldProto, view: String, index: SchemaIndex) throws -> String {
        let property = identifier(lowerCamel(field.name)), id = field.number - 1
        let nonempty: String
        if field.type == .message && field.label != .repeated && mapEntry(field, index: index) == nil {
            return "        if let value = _\(property) { if !value.value._isProtoCacheEmpty { return false } } else if _source.withView(\(view).self, { $0._protoCacheMessageView.hasField(\(id)) }) { return false }\n"
        }
        if field.label == .repeated || mapEntry(field, index: index) != nil || field.type == .string || field.type == .bytes { nonempty = "!value.isEmpty" }
        else if field.type == .enum { nonempty = "value.rawValue != 0" }
        else if field.type == .bool { nonempty = "value" }
        else { nonempty = "value != 0" }
        return "        if let value = _\(property) { if \(nonempty) { return false } } else if _source.withView(\(view).self, { $0._protoCacheMessageView.hasField(\(id)) }) { return false }\n"
    }

    private static func renderMutableEncoding(_ field: FieldProto, view: String, index: SchemaIndex) throws -> String {
        let property = identifier(lowerCamel(field.name)), id = field.number - 1
        var output = "        if _accessed.contains(\(id)) {\n"
        if field.type == .message && field.label != .repeated && mapEntry(field, index: index) == nil {
            output += "            let value = _\(property)!.value\n            if !value._isProtoCacheEmpty { fields[\(id)] = try value._encodeProtoCache(in: buffer) }\n"
        } else if field.label == .repeated || mapEntry(field, index: index) != nil {
            output += "            let value = _\(property)!\n            if !value.isEmpty {\n"
            output += try renderContainerEncoding(field, value: "value", target: "fields[\(id)] =", index: index, indent: "                ")
            output += "            }\n"
        } else {
            let condition: String
            if field.type == .string || field.type == .bytes { condition = "!value.isEmpty" }
            else if field.type == .enum { condition = "value.rawValue != 0" }
            else if field.type == .bool { condition = "value" }
            else { condition = "value != 0" }
            output += "            let value = _\(property)!\n            if \(condition) { fields[\(id)] = \(try encodeExpression(field, value: "value", index: index)) }\n"
        }
        let kind = try metadataKind(field, index: index)
        output += "        } else {\n"
        output += "            fields[\(id)] = try _source.withView(\(view).self) { source in\n"
        output += "                guard let original = source._protoCacheMessageView.field(\(id)) else { return .empty }\n"
        output += "                return try _ProtoCacheEncoding.copy(original, kind: \(kind), in: buffer)\n"
        output += "            }\n        }\n"
        output += "        _ProtoCacheEncoding.fold(&fields[\(id)], in: buffer)\n"
        return output
    }

    private static func renderContainerEncoding(_ field: FieldProto, value: String, target: String, index: SchemaIndex, indent: String) throws -> String {
        if let entry = mapEntry(field, index: index) {
            var output = "\(indent)let entries = \(value).map { (bytes: $0.key._protoCacheKeyBytes, key: $0.key, value: $0.value) }.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }\n"
            output += "\(indent)let checkpoint = buffer.checkpoint\n"
            let keyTry = encodingExpressionThrows(entry.field[0]) ? "try " : ""
            let valueTry = encodingExpressionThrows(entry.field[1]) ? "try " : ""
            output += "\(indent)let keys = \(keyTry)entries.map { \(try encodeExpression(entry.field[0], value: "$0.key", index: index)) }\n"
            output += "\(indent)let values = \(valueTry)entries.map { \(try encodeExpression(entry.field[1], value: "$0.value", index: index)) }\n"
            output += "\(indent)\(target) try _ProtoCacheEncoding.map(keys: entries.map { $0.bytes }, keyUnits: keys, valueUnits: values, in: buffer, since: checkpoint)\n"
            return output
        }
        if field.type == .bool {
            return "\(indent)\(target) try _ProtoCacheEncoding.boolArray(\(value), in: buffer)\n"
        }
        var output = "\(indent)let checkpoint = buffer.checkpoint\n"
        let mapTry = encodingExpressionThrows(field) ? "try " : ""
        output += "\(indent)let elements = \(mapTry)\(value).map { \(try encodeExpression(field, value: "$0", index: index)) }\n"
        output += "\(indent)\(target) try _ProtoCacheEncoding.array(elements, in: buffer, since: checkpoint)\n"
        return output
    }

    private static func encodeExpression(_ field: FieldProto, value: String, index: SchemaIndex) throws -> String {
        switch field.type {
        case .string: "try _ProtoCacheEncoding.string(\(value), in: buffer)"
        case .bytes: "try _ProtoCacheEncoding.byteArray(\(value), in: buffer)"
        case .message: "try \(value)._encodeProtoCache(in: buffer)"
        case .enum: "_ProtoCacheEncoding.scalar(\(value).rawValue)"
        default: "_ProtoCacheEncoding.scalar(\(value))"
        }
    }

    private static func encodingExpressionThrows(_ field: FieldProto) -> Bool {
        switch field.type {
        case .string, .bytes, .message:
            true
        default:
            false
        }
    }

    private static func aliasOwnedExpression(_ field: FieldProto, view: String, index: SchemaIndex) throws -> String {
        let body = try containerOwnedBody(field, source: "source", owner: "bytes", resultType: try mutableType(field, index: index), index: index)
        return "_source.map { bytes in bytes.withView(\(view).self) { source in \(body) } } ?? \(mapEntry(field, index: index) == nil ? "[]" : "[:]")"
    }

    private static func sourceOwnedExpression(_ field: FieldProto, view: String, property: String, index: SchemaIndex) throws -> String {
        if field.label == .repeated || mapEntry(field, index: index) != nil {
            let body = try containerOwnedBody(field, source: "source.\(property)", owner: "_source", resultType: try mutableType(field, index: index), index: index)
            return "_source.withView(\(view).self) { source in \(body) }"
        }
        if field.type == .message {
            let mutable = "\(swiftType(field.typeName))Mutable"
            return "{ let owner = _source; let range = owner.withView(\(view).self) { source in let root = source._protoCacheSpan; let nested = source.\(property); let child = nested._protoCacheSpan; return root.byteRange(of: child) }; return \(mutable)(owner.slice(byteOffset: range.lowerBound, count: range.count)) }()"
        }
        let conversion = try ownedConversion(field, value: "source.\(property)", owner: "_source", index: index)
        return "_source.withView(\(view).self) { source in \(conversion) }"
    }

    private static func containerOwnedBody(_ field: FieldProto, source: String, owner: String, resultType: String, index: SchemaIndex) throws -> String {
        if let entry = mapEntry(field, index: index) {
            let key = try ownedConversion(entry.field[0], value: "key", owner: owner, index: index)
            let value = try ownedConversion(entry.field[1], value: "value", owner: owner, index: index)
            return "var result: \(resultType) = [:]; result.reserveCapacity(\(source).count); \(source).forEach { key, value in result[\(key)] = \(value) }; return result"
        }
        let element = try ownedConversion(field, value: "element", owner: owner, index: index)
        return "var result: \(resultType) = []; result.reserveCapacity(\(source).count); \(source).forEach { element in result.append(\(element)) }; return result"
    }

    private static func ownedConversion(_ field: FieldProto, value: String, owner: String, index: SchemaIndex) throws -> String {
        switch field.type {
        case .string: "\(value).withUnsafeUTF8 { String(decoding: $0, as: UTF8.self) }"
        case .bytes: "\(value).withUnsafeBytes { Array($0) }"
        case .message: "{ let bytes = \(owner).ownedSlice(of: \(value)._protoCacheSpan); return \(swiftType(field.typeName))Mutable(bytes) }()"
        default: value
        }
    }

    private static func mutableType(_ field: FieldProto, index: SchemaIndex) throws -> String {
        if let entry = mapEntry(field, index: index) {
            return "[\(try ownedType(entry.field[0], index: index)): \(try ownedType(entry.field[1], index: index))]"
        }
        if field.label == .repeated { return "[\(try ownedType(field, index: index))]" }
        return try ownedType(field, index: index)
    }

    private static func ownedType(_ field: FieldProto, index: SchemaIndex) throws -> String {
        switch field.type {
        case .string: "String"
        case .bytes: "[UInt8]"
        case .message: "\(swiftType(field.typeName))Mutable"
        default: try readType(field, index: index, repeatedElement: true)
        }
    }

    private static func readType(_ field: FieldProto, index: SchemaIndex, repeatedElement: Bool) throws -> String {
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
        default: throw GeneratorFailure.schema("unsupported field type \(field.type)")
        }
    }

    private static func metadataKind(_ field: FieldProto, index: SchemaIndex) throws -> String {
        if let entry = mapEntry(field, index: index) {
            return ".map(key: { \(try baseMetadataKind(entry.field[0])) }, value: { \(try baseMetadataKind(entry.field[1])) })"
        }
        let base = try baseMetadataKind(field)
        return field.label == .repeated ? ".array({ \(base) })" : base
    }

    private static func baseMetadataKind(_ field: FieldProto) throws -> String {
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
        default: throw GeneratorFailure.schema("unsupported field type")
        }
    }

    private static func mapEntry(_ field: FieldProto, index: SchemaIndex) -> MessageProto? {
        guard field.type == .message, let message = index.messages[field.typeName], message.options.mapEntry else { return nil }
        return message
    }
    private static func mapKeyType(_ type: FieldProto.TypeEnum) -> String? {
        switch type { case .string, .int32, .sint32, .sfixed32, .uint32, .fixed32, .int64, .sint64, .sfixed64, .uint64, .fixed64: "ok"; default: nil }
    }
    private static func isAlias(_ message: MessageProto) -> Bool { message.field.count == 1 && message.field[0].name == "_" }
    private static func activeFields(_ message: MessageProto) -> [FieldProto] { message.field.filter { !$0.options.deprecated }.sorted { $0.number < $1.number } }
    private static func outputName(_ input: String, suffix: String) -> String { input.hasSuffix(".proto") ? String(input.dropLast(6)) + suffix : input + suffix }
    private static func trimDot(_ value: String) -> String { value.first == "." ? String(value.dropFirst()) : value }
    private static func swiftType(_ fullName: String) -> String { trimDot(fullName).split(separator: ".").map { pascal(String($0)) }.joined(separator: "_") }
    private static func pascal(_ value: String) -> String {
        value.split(separator: "_").map { part in
            let text = String(part)
            let normalized = text == text.uppercased() ? text.lowercased() : text
            return normalized.prefix(1).uppercased() + normalized.dropFirst()
        }.joined()
    }
    private static func lowerCamel(_ value: String) -> String { let p = pascal(value); return p.prefix(1).lowercased() + p.dropFirst() }
    private static func identifier(_ value: String) -> String {
        let keywords: Set<String> = ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "Any", "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try"]
        return keywords.contains(value) ? "`\(value)`" : value
    }
}
