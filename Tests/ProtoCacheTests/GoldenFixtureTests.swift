import Foundation
import Testing
import ProtoCacheCore

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func runGoldenFixtures(_ names: [String]) -> Bool {
    ProcessInfo.processInfo.environment["PROTOCACHE_REQUIRE_GOLDEN"] == "1"
        || names.allSatisfy { FileManager.default.fileExists(atPath: fixtureURL($0).path) }
}

private func fixtureBytes(_ name: String) throws -> Bytes {
    let source = fixtureURL(name)
    try #require(FileManager.default.fileExists(atPath: source.path), "Required golden fixture missing: \(name)")
    let data = try Data(contentsOf: source)
    guard !data.isEmpty else { return .empty }
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 4)
    data.copyBytes(to: UnsafeMutableRawBufferPointer(start: pointer, count: data.count))
    return Bytes(adopting: pointer, count: data.count)
}

@Test(.enabled(if: runGoldenFixtures(["test.pc"]), "Local cross-language fixture is absent"))
func fixedGoldenFixtureReadsAllCompositeShapes() throws {
    let bytes = try fixtureBytes("test.pc")
    #expect(bytes.count == 780)
    bytes.withView(Test_MainView.self) { view in
        #expect(view.i32 == -999)
        #expect(view.u32 == 1234)
        #expect(view.i64 == -9_876_543_210)
        #expect(view.u64 == 98_765_432_123_456_789)
        let flag = view.flag
        #expect(flag)
        #expect(view.mode == Test_ModeValue.modeC)
        let stringMatches = view.str.equalsUTF8("Hello World!")
        #expect(stringMatches)
        #expect(view.object.i32 == 88)
        #expect(view.i32v.count == 2 && view.i32v[0] == 1 && view.i32v[1] == 2)
        #expect(view.index.position(for: "abc-1").map { view.index.value(at: $0) } == 1)
        #expect(view.index.position(for: "abc-3") == nil)
        #expect(view.objects.value(for: Int32(4))?.i32 == 4)
        #expect(view.matrix.count == 3)
        #expect(view.matrix[2][2] == 9)
        #expect(view.vector.count == 2)
        #expect(view.arrays.count > 0)
    }
}

@Test(.enabled(if: runGoldenFixtures(["test.pc", "test.pc.compressed"]), "Local cross-language fixtures are absent"))
func fixedCompressedGoldenFixtureIsCompatible() throws {
    let raw = try fixtureBytes("test.pc")
    let compressed = try fixtureBytes("test.pc.compressed")
    #expect(compressed.count == 574)
    let decoded = try Compression.decompress(compressed)
    // These independent reference fixtures may use different PerfectHash seeds.
    #expect(decoded.count == raw.count)
    #expect(Compression.compress(decoded) == compressed)
    decoded.withView(Test_MainView.self) { view in
        #expect(view.i32 == -999)
        #expect(view.index.position(for: "abc-1").map { view.index.value(at: $0) } == 1)
        #expect(view.matrix[2][2] == 9)
    }
}
