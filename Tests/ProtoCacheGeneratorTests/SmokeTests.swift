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

private func request(parameter: String = "") -> ProtoCacheSwiftGenerator.Request {
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

    var request = ProtoCacheSwiftGenerator.Request()
    request.fileToGenerate = [file.name]
    request.protoFile = [file]
    request.parameter = parameter
    return request
}

@Test func readonlyGenerationIsDeterministicAndProtobufFree() {
    let first = ProtoCacheSwiftGenerator.generate(request())
    let second = ProtoCacheSwiftGenerator.generate(request())
    #expect(first.error.isEmpty)
    #expect(first.file.count == 1)
    #expect(first.file[0].name == "sample.pc.swift")
    #expect(first.file[0].content == second.file[0].content)
    #expect(first.file[0].content.contains("public struct Sample_RootView"))
    #expect(first.file[0].content.contains("public struct Sample_ModeValue"))
    #expect(first.file[0].content.contains("isAlias: true"))
    #expect(first.file[0].content.contains("import ProtoCacheCore"))
    #expect(!first.file[0].content.contains("SwiftProtobuf"))
}

@Test func extraParameterAddsSeparateMutableFile() {
    let response = ProtoCacheSwiftGenerator.generate(request(parameter: "extra"))
    #expect(response.error.isEmpty)
    #expect(response.file.map(\.name) == ["sample.pc.swift", "sample.pc-ex.swift"])
    #expect(response.file[1].content.contains("public struct Sample_RootMutable"))
    #expect(response.file[1].content.contains("_ProtoCacheAccessed"))
    #expect(!response.file[1].content.contains("SwiftProtobuf"))
}

@Test func unsupportedParameterAndSchemaReturnPluginErrors() {
    let option = ProtoCacheSwiftGenerator.generate(request(parameter: "core_only"))
    #expect(option.file.isEmpty)
    #expect(option.error.contains("unsupported parameter"))

    var bad = request()
    bad.protoFile[0].syntax = "proto2"
    let proto2 = ProtoCacheSwiftGenerator.generate(bad)
    #expect(proto2.file.isEmpty)
    #expect(proto2.error.contains("only proto3"))

    bad = request()
    bad.protoFile[0].messageType[2].field[0].number = 6388
    let range = ProtoCacheSwiftGenerator.generate(bad)
    #expect(range.error.contains("outside 1...6387"))
}

@Test func extensionsAndServicesAreRejected() {
    var withExtension = request()
    withExtension.protoFile[0].`extension` = [field("legacy", 100, .int32)]
    #expect(ProtoCacheSwiftGenerator.generate(withExtension).error.contains("extensions are not supported"))

    var withService = request()
    var service = Google_Protobuf_ServiceDescriptorProto(); service.name = "API"
    withService.protoFile[0].service = [service]
    #expect(ProtoCacheSwiftGenerator.generate(withService).error.contains("services/RPC are not supported"))
}
