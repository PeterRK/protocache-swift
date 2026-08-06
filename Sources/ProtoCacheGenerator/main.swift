import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let request = try Google_Protobuf_Compiler_CodeGeneratorRequest(serializedBytes: input)
    let response = ProtoCacheSwiftGenerator.generate(request)
    FileHandle.standardOutput.write(try response.serializedBytes())
} catch {
    FileHandle.standardError.write(Data("protoc-gen-pcsw: \(error)\n".utf8))
}
