import Foundation
import Testing
import ProtoCacheCore

private func fixtureBytes(_ name: String) throws -> ProtoCacheBytes? {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: source.path) else { return nil }
    let data = try Data(contentsOf: source)
    guard !data.isEmpty else { return .empty }
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 4)
    data.copyBytes(to: UnsafeMutableRawBufferPointer(start: pointer, count: data.count))
    return ProtoCacheBytes(adopting: pointer, count: data.count)
}

@Test func fixedGoldenFixtureReadsAllCompositeShapes() throws {
    guard let bytes = try fixtureBytes("test.pc") else { return }
    #expect(bytes.count == 780)
    let view = Test_MainView(bytes)
    #expect(view.i32 == -999)
    #expect(view.u32 == 1234)
    #expect(view.i64 == -9_876_543_210)
    #expect(view.u64 == 98_765_432_123_456_789)
    #expect(view.flag)
    #expect(view.mode == .modeC)
    #expect(view.str.equalsUTF8("Hello World!"))
    #expect(view.object.i32 == 88)
    #expect(Array(view.i32v) == [1, 2])
    #expect(view.index["abc-1"] == 1)
    #expect(view.index["abc-3"] == nil)
    #expect(view.objects[4]?.i32 == 4)
    #expect(view.matrix.count == 3)
    #expect(view.matrix[2][2] == 9)
    #expect(view.vector.count == 2)
    #expect(view.arrays.count > 0)
}

@Test func fixedCompressedGoldenFixtureIsCompatible() throws {
    guard let raw = try fixtureBytes("test.pc"),
          let compressed = try fixtureBytes("test.pc.compressed") else { return }
    #expect(compressed.count == 574)
    let decoded = try ProtoCacheCompression.decompress(compressed)
    #expect(decoded.count == raw.count)
    let view = Test_MainView(decoded)
    #expect(view.i32 == -999)
    #expect(view.index["abc-1"] == 1)
    #expect(view.matrix[2][2] == 9)
}
