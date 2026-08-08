import Foundation
import ProtoCacheGenerator

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    FileHandle.standardOutput.write(try Generator.generate(serializedRequest: input))
} catch {
    FileHandle.standardError.write(Data("protoc-gen-pcsw: \(error)\n".utf8))
}
