import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

enum GenError: Error, CustomStringConvertible {
    case schema(String)
    var description: String { switch self { case .schema(let message): message } }
}

package struct Generator {
    typealias Request = Google_Protobuf_Compiler_CodeGeneratorRequest
    typealias Response = Google_Protobuf_Compiler_CodeGeneratorResponse
    typealias FileProto = Google_Protobuf_FileDescriptorProto
    typealias MessageProto = Google_Protobuf_DescriptorProto
    typealias FieldProto = Google_Protobuf_FieldDescriptorProto
    typealias EnumProto = Google_Protobuf_EnumDescriptorProto

    package static func generate(serializedRequest input: Data) throws -> Data {
        let request = try Request(serializedBytes: input)
        return try generate(request).serializedBytes()
    }

    static func generate(_ request: Request) -> Response {
        var response = Response()
        response.supportedFeatures = UInt64(Response.Feature.proto3Optional.rawValue)
        do {
            guard request.parameter.isEmpty || request.parameter == "extra" else {
                throw GenError.schema("unsupported parameter '\(request.parameter)'; expected empty or 'extra'")
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
}
