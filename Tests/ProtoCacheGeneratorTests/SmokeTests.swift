import Testing
import SwiftProtobuf
import SwiftProtobufPluginLibrary
@testable import ProtoCacheGenerator

private func field(
    _ name: String,
    _ number: Int32,
    _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
    label: Google_Protobuf_FieldDescriptorProto.Label = .optional,
    typeName: String = ""
) -> Google_Protobuf_FieldDescriptorProto {
    var field = Google_Protobuf_FieldDescriptorProto()
    field.name = name
    field.number = number
    field.type = type
    field.label = label
    field.typeName = typeName
    return field
}

private func request(parameter: String = "") -> Generator.Request {
    var child = Google_Protobuf_DescriptorProto()
    child.name = "Child"
    child.field = [field("value", 1, .int64)]

    var alias = Google_Protobuf_DescriptorProto()
    alias.name = "Floats"
    alias.field = [field("_", 1, .float, label: .repeated)]

    var mode = Google_Protobuf_EnumDescriptorProto()
    mode.name = "Mode"
    var zero = Google_Protobuf_EnumValueDescriptorProto(); zero.name = "MODE_ZERO"; zero.number = 0
    var one = Google_Protobuf_EnumValueDescriptorProto(); one.name = "MODE_ONE"; one.number = 1
    mode.value = [zero, one]

    var root = Google_Protobuf_DescriptorProto()
    root.name = "Root"
    root.field = [
        field("count", 1, .int32),
        field("name", 2, .string),
        field("child", 3, .message, typeName: ".sample.Child"),
        field("values", 4, .uint64, label: .repeated),
        field("mode", 5, .enum, typeName: ".sample.Mode"),
    ]

    var file = Google_Protobuf_FileDescriptorProto()
    file.name = "sample.proto"
    file.package = "sample"
    file.syntax = "proto3"
    file.messageType = [child, alias, root]
    file.enumType = [mode]

    var request = Generator.Request()
    request.fileToGenerate = [file.name]
    request.protoFile = [file]
    request.parameter = parameter
    return request
}

@Test func readonlyGenerationIsDeterministicAndProtobufFree() {
    let first = Generator.generate(request())
    let second = Generator.generate(request())
    #expect(first.error.isEmpty)
    #expect(first.file.count == 1)
    #expect(first.file[0].name == "sample.pc.swift")
    #expect(first.file[0].content == second.file[0].content)
    #expect(first.file[0].content.contains("public struct Sample_RootView"))
    #expect(first.file[0].content.contains("public struct Sample_ModeValue"))
    #expect(first.file[0].content.contains("isAlias: true"))
    #expect(first.file[0].content.contains("runtimeABI: 7"))
    #expect(first.file[0].content.contains("_detectProtoCacheWords"))
    #expect(first.file[0].content.contains("import ProtoCacheCore"))
    #expect(!first.file[0].content.contains("SwiftProtobuf"))
}

@Test func extraParameterAddsSeparateMutableFile() {
    let response = Generator.generate(request(parameter: "extra"))
    #expect(response.error.isEmpty)
    #expect(response.file.map(\.name) == ["sample.pc.swift", "sample.pc-ex.swift"])
    let extra = response.file[1].content
    #expect(extra.contains("public struct Sample_RootMutable: _ProtoCacheMutableEncoding"))
    #expect(extra.contains("public struct Sample_FloatsMutable: _ProtoCacheMutableEncoding"))
    #expect(!extra.contains("SwiftProtobuf"))
}

@Test func extraMapUsesEagerMutableHashContainer() {
    var input = request(parameter: "extra")
    var entry = Google_Protobuf_DescriptorProto()
    entry.name = "LabelsEntry"
    entry.options.mapEntry = true
    entry.field = [field("key", 1, .string), field("value", 2, .int32)]
    input.protoFile[0].messageType[2].nestedType = [entry]
    input.protoFile[0].messageType[2].field.append(
        field(
            "labels", 6, .message,
            label: .repeated,
            typeName: ".sample.Root.LabelsEntry"
        )
    )

    let response = Generator.generate(input)
    #expect(response.error.isEmpty)
    guard response.file.count == 2 else { return }
    let extra = response.file[1].content
    #expect(extra.contains("MutableMap<String, Int32>"))
    #expect(extra.contains("var result = MutableMap<String, Int32>()"))
    #expect(extra.contains("try value._withDictionary { value in"))
    #expect(extra.contains("mutating _read"))
}

@Test func extraUsesIndirectStorageOnlyForRecursiveMessageEdges() {
    var input = request(parameter: "extra")
    var cyclicA = Google_Protobuf_DescriptorProto()
    cyclicA.name = "CyclicA"
    cyclicA.field = [field("cyclic", 1, .message, typeName: ".sample.CyclicB")]
    var cyclicB = Google_Protobuf_DescriptorProto()
    cyclicB.name = "CyclicB"
    cyclicB.field = [field("cyclic", 1, .message, typeName: ".sample.CyclicA")]
    input.protoFile[0].messageType.append(contentsOf: [cyclicA, cyclicB])

    let response = Generator.generate(input)
    #expect(response.error.isEmpty)
    guard response.file.count == 2 else { return }
    let extra = response.file[1].content
    #expect(!extra.contains("_ProtoCacheBox<Sample_ChildMutable>"))
    #expect(extra.contains("_ProtoCacheBox<Sample_CyclicBMutable>?"))
    #expect(!extra.contains("_ProtoCacheBox<Sample_CyclicBMutable>(.init())"))
    #expect(extra.contains("_ProtoCacheBox<Sample_CyclicAMutable>"))
}

@Test func extraAccessBitmapIsFixedBySchema() {
    var input = request(parameter: "extra")
    for number in 6...65 {
        input.protoFile[0].messageType[2].field.append(field("field_\(number)", Int32(number), .int32))
    }
    let response = Generator.generate(input)
    #expect(response.error.isEmpty)
    #expect(response.file.count == 2)
    guard response.file.count == 2 else { return }
    let extra = response.file[1].content
    #expect(extra.contains("InlineArray<2, UInt64>"))
    #expect(extra.contains("_accessed[0] == 0 && _accessed[1] == 0"))
    #expect(extra.contains("_accessed[1] |= UInt64(1) << 0"))
    #expect(extra.contains("_accessed[1] & (UInt64(1) << 0) != 0"))
}

@Test func unsupportedParameterAndSchemaReturnPluginErrors() {
    let option = Generator.generate(request(parameter: "core_only"))
    #expect(option.file.isEmpty)
    #expect(option.error.contains("unsupported parameter"))

    var bad = request()
    bad.protoFile[0].syntax = "proto2"
    let proto2 = Generator.generate(bad)
    #expect(proto2.file.isEmpty)
    #expect(proto2.error.contains("only proto3"))

    bad = request()
    bad.protoFile[0].messageType[2].field[0].number = 6388
    let range = Generator.generate(bad)
    #expect(range.error.contains("outside 1...6387"))
}

@Test func extensionsAndServicesAreRejected() {
    var withExtension = request()
    withExtension.protoFile[0].`extension` = [field("legacy", 100, .int32)]
    #expect(Generator.generate(withExtension).error.contains("extensions are not supported"))

    var withService = request()
    var service = Google_Protobuf_ServiceDescriptorProto(); service.name = "API"
    withService.protoFile[0].service = [service]
    #expect(Generator.generate(withService).error.contains("services/RPC are not supported"))
}

@Test(arguments: [("FooBar", "foo_bar"), ("ID", "Id")])
func collidingSwiftTypeNamesReturnPluginErrors(names: (String, String)) {
    var input = request()
    for name in [names.0, names.1] {
        var message = Google_Protobuf_DescriptorProto()
        message.name = name
        message.field = [field("id", 1, .int32)]
        input.protoFile[0].messageType.append(message)
    }
    let response = Generator.generate(input)
    #expect(response.file.isEmpty)
    #expect(response.error.contains("Swift symbol collision"))
    #expect(response.error.contains(".sample.\(names.0)"))
    #expect(response.error.contains(".sample.\(names.1)"))
}

@Test func nestedAndImportedPackageNamesCannotCollide() {
    var input = request()
    input.protoFile[0].package = "foo"
    var parent = Google_Protobuf_DescriptorProto()
    parent.name = "Bar"
    parent.field = [field("id", 1, .int32)]
    parent.nestedType = [input.protoFile[0].messageType[0]]
    input.protoFile[0].messageType = [parent]
    input.protoFile[0].enumType = []
    var imported = input.protoFile[0]
    imported.name = "imported.proto"
    imported.package = "foo.bar"
    imported.messageType = parent.nestedType
    input.protoFile.append(imported)
    let response = Generator.generate(input)
    #expect(response.file.isEmpty)
    #expect(response.error.contains(".foo.Bar.Child"))
    #expect(response.error.contains(".foo.bar.Child"))
}

@Test func collidingSwiftEnumNamesReturnPluginErrors() {
    var input = request()
    var first = input.protoFile[0].enumType[0]
    first.name = "FooBar"
    first.value = Array(first.value.prefix(1))
    first.value[0].name = "FIRST_ZERO"
    var second = first
    second.name = "foo_bar"
    second.value[0].name = "SECOND_ZERO"
    input.protoFile[0].enumType.append(contentsOf: [first, second])
    let response = Generator.generate(input)
    #expect(response.file.isEmpty)
    #expect(response.error.contains("Swift symbol collision 'Sample_FooBarValue'"))
}

@Test func collidingSwiftFieldNamesReturnPluginErrors() {
    var input = request()
    input.protoFile[0].messageType[2].field = [field("ID", 1, .int32), field("Id", 2, .int32)]
    let response = Generator.generate(input)
    #expect(response.file.isEmpty)
    #expect(response.error.contains("duplicate Swift field 'id'"))
}

@Test func numericTypeNamesRetainTheirProtobufIdentity() {
    var input = request(parameter: "extra")
    input.protoFile[0].package = ""
    input.protoFile[0].messageType = [input.protoFile[0].messageType[0]]
    input.protoFile[0].messageType[0].name = "_123"
    input.protoFile[0].enumType = []
    let response = Generator.generate(input)
    #expect(response.error.isEmpty)
    guard response.file.count == 2 else { Issue.record("missing generated files"); return }
    #expect(response.file[0].content.contains("public struct _123View"))
    #expect(response.file[0].content.contains("fullName: \"_123\""))
    #expect(response.file[1].content.contains("public struct _123Mutable"))
}

@Test func unqualifiedTypesCannotShadowCoreViews() {
    for name in ["Field", "Message", "Bytes", "String", "BoolArray", "Array", "Map", "PerfectHash", "Generated"] {
        var input = request()
        input.protoFile[0].package = ""
        input.protoFile[0].messageType = [input.protoFile[0].messageType[0]]
        input.protoFile[0].messageType[0].name = name
        input.protoFile[0].enumType = []
        let response = Generator.generate(input)
        #expect(response.file.isEmpty)
        #expect(response.error.contains("ProtoCacheCore.\(name)View"))
        #expect(response.error.contains("Swift symbol collision"))
    }
}

@Test func keywordAndRuntimeStorageNamesAreIndependent() {
    var input = request(parameter: "extra")
    input.protoFile[0].messageType[2].field = [
        field("class", 1, .int32), field("source", 2, .int32), field("accessed", 3, .int32),
    ]
    let response = Generator.generate(input)
    #expect(response.error.isEmpty)
    guard response.file.count == 2 else { Issue.record("missing generated files"); return }
    let extra = response.file[1].content
    #expect(extra.contains("public var `class`: Int32"))
    #expect(extra.contains("private var _class: Int32"))
    #expect(extra.contains("private var _source_: Int32"))
    #expect(extra.contains("private var _accessed_: Int32"))
    #expect(!extra.contains("_`class`"))
}

@Test func deprecatedReferencedMessagesAndEnumsAreRejected() {
    for enumReference in [false, true] {
        var input = request()
        if enumReference {
            input.protoFile[0].enumType[0].options.deprecated = true
        } else {
            input.protoFile[0].messageType[0].options.deprecated = true
        }
        let response = Generator.generate(input)
        #expect(response.file.isEmpty)
        #expect(response.error.contains("filtered as deprecated"))
    }
}

@Test func deprecatedAncestorsSuppressNestedReferenceTargets() {
    var input = request()
    var parent = Google_Protobuf_DescriptorProto()
    parent.name = "Old"
    parent.options.deprecated = true
    parent.nestedType = [input.protoFile[0].messageType[0]]
    parent.enumType = input.protoFile[0].enumType
    input.protoFile[0].messageType.append(parent)
    for (type, name) in [(Google_Protobuf_FieldDescriptorProto.TypeEnum.message, "Child"), (.enum, "Mode")] {
        input.protoFile[0].messageType[2].field = [field("old", 1, type, typeName: ".sample.Old.\(name)")]
        let response = Generator.generate(input)
        #expect(response.file.isEmpty)
        #expect(response.error.contains(".sample.Old.\(name)"))
        #expect(response.error.contains("filtered as deprecated"))
    }
}

@Test func mapValuesCannotReferenceDeprecatedTypes() {
    for enumReference in [false, true] {
        var input = request()
        var entry = Google_Protobuf_DescriptorProto()
        entry.name = "LabelsEntry"
        entry.options.mapEntry = true
        entry.field = [field("key", 1, .string), field("value", 2, enumReference ? .enum : .message,
            typeName: enumReference ? ".sample.Mode" : ".sample.Child")]
        input.protoFile[0].messageType[2].nestedType = [entry]
        input.protoFile[0].messageType[2].field = [field("labels", 1, .message, label: .repeated,
            typeName: ".sample.Root.LabelsEntry")]
        if enumReference { input.protoFile[0].enumType[0].options.deprecated = true }
        else { input.protoFile[0].messageType[0].options.deprecated = true }
        let response = Generator.generate(input)
        #expect(response.file.isEmpty)
        #expect(response.error.contains("filtered as deprecated"))
    }
}

@Test func filteredFieldsDoNotRequireTheirReferenceTargets() {
    var input = request()
    input.protoFile[0].messageType[0].options.deprecated = true
    input.protoFile[0].messageType[2].field[2].options.deprecated = true
    #expect(Generator.generate(input).error.isEmpty)
}

@Test func unresolvedTypesReturnPluginErrors() {
    var input = request()
    input.protoFile[0].messageType[2].field[2].typeName = ".other.Missing"
    let response = Generator.generate(input)
    #expect(response.file.isEmpty)
    #expect(response.error.contains("unresolved type '.other.Missing'"))
}

@Test func convergingDirectMessagePathsDoNotRequireBoxes() throws {
    var input = request(parameter: "extra")
    input.protoFile[0].messageType = (0..<40).map { number in
        var message = Google_Protobuf_DescriptorProto()
        message.name = "Node\(number)"
        message.field = [field("id", 1, .int32)]
        for next in (number + 1)...(number + 2) where next < 40 {
            message.field.append(field("child\(next)", Int32(message.field.count + 1), .message,
                typeName: ".sample.Node\(next)"))
        }
        return message
    }
    let index = try Generator.SchemaIndex(files: input.protoFile)
    #expect(!index.hasDirectPath(from: ".sample.Node1", to: ".sample.Node0"))
    #expect(index.hasDirectPath(from: ".sample.Node0", to: ".sample.Node39"))
    let response = Generator.generate(input)
    #expect(response.error.isEmpty)
    guard response.file.count == 2 else { Issue.record("missing generated files"); return }
    #expect(!response.file[1].content.contains("_ProtoCacheBox<"))
}

@Test func containerAndFilteredEdgesBreakDirectMessageCycles() throws {
    var input = request()
    let target = ".sample.Root"
    var child = input.protoFile[0].messageType[0]
    for kind in 0..<3 {
        child.field = [field("parent", 1, .message, label: kind == 0 ? .repeated : .optional, typeName: target)]
        if kind == 1 { child.field[0].options.deprecated = true }
        if kind == 2 { child.field[0].name = "_"; child.field[0].label = .repeated }
        input.protoFile[0].messageType[0] = child
        let index = try Generator.SchemaIndex(files: input.protoFile)
        #expect(!Generator.isIndirect(owner: target, field: input.protoFile[0].messageType[2].field[2], index: index))
    }
}
