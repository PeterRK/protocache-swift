import Foundation
import Testing
import ProtoCache
import ProtoCacheCore

private func sampleSmall(_ value: Int32, _ name: String) -> Test_Small {
    var message = Test_Small()
    message.i32 = value
    message.flag = true
    message.str = name
    return message
}

private func sampleMessage() -> Test_Main {
    var row = Test_Vec2D.Vec1D(); row.___ = [1.25, -0.0, 3.5]
    var matrix = Test_Vec2D(); matrix.___ = [row]
    var array = Test_ArrMap.Array(); array.___ = [2.5, 7.75]
    var arrays = Test_ArrMap(); arrays.___ = ["numbers": array]
    var message = Test_Main()
    message.i32 = -12; message.u32 = 34
    message.i64 = -5_000_000_000; message.u64 = 9_000_000_000
    message.flag = true; message.mode = .b
    message.str = "swift-零拷贝"; message.data = Data([0, 1, 2, 255])
    message.f32 = 1.5; message.f64 = -9.25
    message.object = sampleSmall(7, "child")
    message.i32V = [0, -1, 2, Int32.max]; message.u64V = [0, 1, UInt64.max]
    message.strv = ["", "alpha", "中"]; message.datav = [Data(), Data([3, 4, 5])]
    message.f32V = [0, -0.0, .infinity, 4.25]; message.f64V = [0, -.infinity, 8.5]
    message.flags = [false, true, false, true]
    message.objectv = [Test_Small(), sampleSmall(8, "array-child")]
    message.tU32 = 0xfedcba98; message.tI32 = -123; message.tS32 = -456
    message.tU64 = 0xfedcba9876543210; message.tI64 = -7_000_000_000; message.tS64 = -8_000_000_000
    message.index = ["zero": 0, "one": 1, "minus": -1]
    message.objects = [0: Test_Small(), -7: sampleSmall(9, "mapped")]
    message.matrix = matrix; message.vector = [arrays]; message.arrays = arrays
    message.modev = [.a, .c, .UNRECOGNIZED(71)]
    return message
}

@Test func swiftProtobufAllKindsRoundTrip() throws {
    let view = Test_MainView(try ProtoCache.serialize(sampleMessage(), as: Test_MainView.self))
    #expect(view.i32 == -12); #expect(view.u32 == 34)
    #expect(view.i64 == -5_000_000_000); #expect(view.u64 == 9_000_000_000)
    #expect(view.flag); #expect(view.mode == .modeB)
    #expect(view.str.equalsUTF8("swift-零拷贝")); #expect(Array(view.data) == [0, 1, 2, 255])
    #expect(view.f32 == 1.5); #expect(view.f64 == -9.25)
    #expect(view.object.i32 == 7); #expect(view.object.str.equalsUTF8("child"))
    #expect(Array(view.i32v) == [0, -1, 2, Int32.max])
    #expect(Array(view.u64v) == [0, 1, UInt64.max])
    #expect(view.strv.map { String(decoding: $0, as: UTF8.self) } == ["", "alpha", "中"])
    #expect(view.datav.map(Array.init) == [[], [3, 4, 5]])
    #expect(view.f32v.map(\.bitPattern) == [Float(0).bitPattern, Float(-0.0).bitPattern, Float.infinity.bitPattern, Float(4.25).bitPattern])
    #expect(Array(view.f64v) == [0, -.infinity, 8.5])
    #expect(Array(view.flags) == [false, true, false, true])
    #expect(view.objectv[0].i32 == 0); #expect(view.objectv[1].i32 == 8)
    #expect(view.tU32 == 0xfedcba98); #expect(view.tI32 == -123); #expect(view.tS32 == -456)
    #expect(view.tU64 == 0xfedcba9876543210); #expect(view.tI64 == -7_000_000_000); #expect(view.tS64 == -8_000_000_000)
    #expect(view.index["one"] == 1); #expect(view.index["missing"] == nil)
    #expect(view.objects[-7]?.str.equalsUTF8("mapped") == true)
    #expect(Array(view.matrix[0]).map(\.bitPattern) == [Float(1.25).bitPattern, Float(-0.0).bitPattern, Float(3.5).bitPattern])
    #expect(Array(view.vector[0][0].value) == [2.5, 7.75])
    #expect(Array(view.arrays[0].value) == [2.5, 7.75])
    #expect(view.modev.map(\.rawValue) == [0, 2, 71])
}

@Test func aliasSerializesAsContainerRoot() throws {
    var row = Test_Vec2D.Vec1D(); row.___ = [1, 2, 3]
    let bytes = try ProtoCache.serialize(row, as: Test_Vec2D_Vec1DView.self)
    #expect(Array(Test_Vec2D_Vec1DView(bytes)) == [1, 2, 3])
}

@Test func serializationRejectsMismatchedGeneratedLayout() {
    #expect(throws: ProtoCacheError.self) { try ProtoCache.serialize(Test_Small(), as: Test_MainView.self) }
}

@Test func extraModePartialUpdateRoundTrip() throws {
    let original = try ProtoCache.serialize(sampleMessage(), as: Test_MainView.self)
    var mutable = Test_MainMutable(original)
    mutable.i32 = 99; mutable.object.str = "changed"; mutable.i32v.append(88)
    mutable.index["new"] = 42; mutable.objects[-7]!.i32 = 1234
    mutable.modev.append(.init(rawValue: 81))
    let view = Test_MainView(try mutable.serialized())
    #expect(view.i32 == 99); #expect(view.object.str.equalsUTF8("changed"))
    #expect(view.i32v.last == 88); #expect(view.index["new"] == 42)
    #expect(view.objects[-7]?.i32 == 1234); #expect(view.modev.last?.rawValue == 81)
    #expect(view.str.equalsUTF8("swift-零拷贝")); #expect(view.u64 == 9_000_000_000)
}

@Test func extraModeUntouchedCompositeSegmentsRemainComplete() throws {
    let original = try ProtoCache.serialize(sampleMessage(), as: Test_MainView.self)
    var mutable = Test_MainMutable(original)
    mutable.i32 = mutable.i32
    let serialized = try mutable.serialized()
    let view = Test_MainView(serialized)

    #expect(serialized.count == original.count)
    #expect(view.strv.map { String(decoding: $0, as: UTF8.self) } == ["", "alpha", "中"])
    #expect(view.datav.map(Array.init) == [[], [3, 4, 5]])
    #expect(view.objectv.map(\.i32) == [0, 8])
    #expect(view.objectv[1].str.equalsUTF8("array-child"))
    #expect(Array(view.matrix[0]).map(\.bitPattern) == [
        Float(1.25).bitPattern,
        Float(-0.0).bitPattern,
        Float(3.5).bitPattern,
    ])
    #expect(Array(view.vector[0][0].value) == [2.5, 7.75])
    #expect(Array(view.arrays[0].value) == [2.5, 7.75])
    #expect(view.index["minus"] == -1)
    #expect(view.objects[-7]?.str.equalsUTF8("mapped") == true)
}

@Test func extraModeMessageBoxHasCopyOnWriteIsolation() throws {
    let original = try ProtoCache.serialize(sampleMessage(), as: Test_MainView.self)
    var left = Test_MainMutable(original); var right = left
    left.object.i32 = 111; right.object.i32 = 222
    #expect(Test_MainView(try left.serialized()).object.i32 == 111)
    #expect(Test_MainView(try right.serialized()).object.i32 == 222)
}

@Test func readonlyViewSupportsConcurrentReads() async throws {
    let view = Test_MainView(try ProtoCache.serialize(sampleMessage(), as: Test_MainView.self))
    let sum = await withTaskGroup(of: Int32.self, returning: Int32.self) { group in
        for _ in 0..<32 { group.addTask { view.i32 + (view.index["one"] ?? 0) } }
        return await group.reduce(0, +)
    }
    #expect(sum == -11 * 32)
}
