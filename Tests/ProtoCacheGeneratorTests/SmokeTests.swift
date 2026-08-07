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
    #expect(!extra.contains("public func serialized()"))
    #expect(extra.contains("private var _source: Bytes"))
    #expect(!extra.contains("private var _source: Bytes?"))
    #expect(extra.contains("public init() { _source = .empty }"))
    #expect(extra.contains("InlineArray<1, UInt64>"))
    #expect(extra.contains("mutating _read"))
    #expect(extra.contains("yield _child"))
    #expect(!extra.contains("_ProtoCacheBox<Sample_ChildMutable>"))
    #expect(extra.contains("yield _values"))
    #expect(!extra.contains("_ProtoCacheAccessed"))
    #expect(extra.contains("else if let original"))
    #expect(!extra.contains("copy(original, kind:"))
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
    #expect(extra.contains("_ProtoCacheBox<Sample_CyclicBMutable>"))
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
