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

private func values<Element: ProtoCacheDecodable>(_ view: borrowing ArrayView<Element>) -> [Element] {
    var result: [Element] = []
    result.reserveCapacity(view.count)
    view.forEach { result.append($0) }
    return result
}

private func values(_ view: borrowing BoolArrayView) -> [Bool] {
    var result: [Bool] = []
    result.reserveCapacity(view.count)
    view.forEach { result.append($0) }
    return result
}

private func values(_ view: borrowing Test_Vec2D_Vec1DView) -> [Float] {
    var result: [Float] = []
    result.reserveCapacity(view.count)
    view.forEach { result.append($0) }
    return result
}

private func values(_ view: borrowing Test_ArrMap_ArrayView) -> [Float] {
    var result: [Float] = []
    result.reserveCapacity(view.count)
    view.forEach { result.append($0) }
    return result
}

private func bytes(_ view: borrowing BytesView) -> [UInt8] { view.withUnsafeBytes { Array($0) } }

private func strings(_ view: borrowing ArrayView<StringView>) -> [String] {
    var result: [String] = []
    result.reserveCapacity(view.count)
    view.forEach { result.append($0.withUnsafeUTF8 { String(decoding: $0, as: UTF8.self) }) }
    return result
}

private func byteArrays(_ view: borrowing ArrayView<BytesView>) -> [[UInt8]] {
    var result: [[UInt8]] = []
    result.reserveCapacity(view.count)
    view.forEach { result.append(bytes($0)) }
    return result
}

private func objectValues(_ view: borrowing ArrayView<Test_SmallView>) -> [Int32] {
    var result: [Int32] = []
    result.reserveCapacity(view.count)
    view.forEach { result.append($0.i32) }
    return result
}

private func modeValues(_ view: borrowing ArrayView<Test_ModeValue>) -> [Int32] {
    var result: [Int32] = []
    result.reserveCapacity(view.count)
    view.forEach { result.append($0.rawValue) }
    return result
}

private func mapValue(_ view: borrowing MapView<StringView, Int32>, _ key: String) -> Int32? {
    view.position(for: key).map { view.value(at: $0) }
}

@Test func swiftProtobufAllKindsRoundTrip() throws {
    let storage = try ProtoCache.serialize(sampleMessage(), as: Test_MainView.self)
    storage.withView(Test_MainView.self) { view in
        #expect(view.i32 == -12); #expect(view.u32 == 34)
        #expect(view.i64 == -5_000_000_000); #expect(view.u64 == 9_000_000_000)
        let flag = view.flag
        #expect(flag); #expect(view.mode == Test_ModeValue.modeB)
        let stringMatches = view.str.equalsUTF8("swift-零拷贝")
        let childMatches = view.object.str.equalsUTF8("child")
        #expect(stringMatches); #expect(bytes(view.data) == [0, 1, 2, 255])
        #expect(view.f32 == 1.5); #expect(view.f64 == -9.25)
        #expect(view.object.i32 == 7); #expect(childMatches)
        #expect(values(view.i32v) == [0, -1, 2, Int32.max])
        #expect(values(view.u64v) == [0, 1, UInt64.max])
        #expect(strings(view.strv) == ["", "alpha", "中"])
        #expect(byteArrays(view.datav) == [[], [3, 4, 5]])
        #expect(values(view.f32v).map(\.bitPattern) == [Float(0).bitPattern, Float(-0.0).bitPattern, Float.infinity.bitPattern, Float(4.25).bitPattern])
        #expect(values(view.f64v) == [0, -.infinity, 8.5])
        #expect(values(view.flags) == [false, true, false, true])
        #expect(objectValues(view.objectv) == [0, 8])
        #expect(view.tU32 == 0xfedcba98); #expect(view.tI32 == -123); #expect(view.tS32 == -456)
        #expect(view.tU64 == 0xfedcba9876543210); #expect(view.tI64 == -7_000_000_000); #expect(view.tS64 == -8_000_000_000)
        #expect(mapValue(view.index, "one") == 1); #expect(mapValue(view.index, "missing") == nil)
        let mappedMatches = view.objects.value(for: Int32(-7))?.str.equalsUTF8("mapped") ?? false
        #expect(mappedMatches)
        #expect(values(view.matrix[0]).map(\.bitPattern) == [Float(1.25).bitPattern, Float(-0.0).bitPattern, Float(3.5).bitPattern])
        let vectorValues: [Float]? = if let value = view.vector[0].value(for: "numbers") { values(value) } else { nil }
        let arrayValues: [Float]? = if let value = view.arrays.value(for: "numbers") { values(value) } else { nil }
        #expect(vectorValues == [2.5, 7.75])
        #expect(arrayValues == [2.5, 7.75])
        #expect(modeValues(view.modev) == [0, 2, 71])
    }
}

@Test func aliasSerializesAsContainerRoot() throws {
    var row = Test_Vec2D.Vec1D(); row.___ = [1, 2, 3]
    let bytes = try ProtoCache.serialize(row, as: Test_Vec2D_Vec1DView.self)
    #expect(bytes.withView(Test_Vec2D_Vec1DView.self) { values($0) } == [1, 2, 3])
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
    let storage = try mutable.serialized()
    storage.withView(Test_MainView.self) { view in
        let objectMatches = view.object.str.equalsUTF8("changed")
        let rootStringMatches = view.str.equalsUTF8("swift-零拷贝")
        #expect(view.i32 == 99); #expect(objectMatches)
        #expect(view.i32v[view.i32v.count - 1] == 88); #expect(mapValue(view.index, "new") == 42)
        #expect(view.objects.value(for: Int32(-7))?.i32 == 1234)
        #expect(view.modev[view.modev.count - 1].rawValue == 81)
        #expect(rootStringMatches); #expect(view.u64 == 9_000_000_000)
    }
}

@Test func extraModeUntouchedCompositeSegmentsRemainComplete() throws {
    let original = try ProtoCache.serialize(sampleMessage(), as: Test_MainView.self)
    var mutable = Test_MainMutable(original)
    mutable.i32 = mutable.i32
    let serialized = try mutable.serialized()
    #expect(serialized.count == original.count)
    serialized.withView(Test_MainView.self) { view in
        #expect(strings(view.strv) == ["", "alpha", "中"])
        #expect(byteArrays(view.datav) == [[], [3, 4, 5]])
        #expect(objectValues(view.objectv) == [0, 8])
        let childMatches = view.objectv[1].str.equalsUTF8("array-child")
        #expect(childMatches)
        #expect(values(view.matrix[0]).map(\.bitPattern) == [
            Float(1.25).bitPattern,
            Float(-0.0).bitPattern,
            Float(3.5).bitPattern,
        ])
        let vectorValues: [Float]? = if let value = view.vector[0].value(for: "numbers") { values(value) } else { nil }
        let arrayValues: [Float]? = if let value = view.arrays.value(for: "numbers") { values(value) } else { nil }
        #expect(vectorValues == [2.5, 7.75])
        #expect(arrayValues == [2.5, 7.75])
        #expect(mapValue(view.index, "minus") == -1)
        let mappedMatches = view.objects.value(for: Int32(-7))?.str.equalsUTF8("mapped") ?? false
        #expect(mappedMatches)
    }
}

@Test func extraModeMessageBoxHasCopyOnWriteIsolation() throws {
    let original = try ProtoCache.serialize(sampleMessage(), as: Test_MainView.self)
    var left = Test_MainMutable(original); var right = left
    left.object.i32 = 111; right.object.i32 = 222
    let leftBytes = try left.serialized()
    let rightBytes = try right.serialized()
    #expect(leftBytes.withView(Test_MainView.self) { $0.object.i32 } == 111)
    #expect(rightBytes.withView(Test_MainView.self) { $0.object.i32 } == 222)
}

@Test func readonlyStorageSupportsConcurrentBorrowedReads() async throws {
    let storage = try ProtoCache.serialize(sampleMessage(), as: Test_MainView.self)
    let sum = await withTaskGroup(of: Int32.self, returning: Int32.self) { group in
        for _ in 0..<32 {
            group.addTask {
                storage.withView(Test_MainView.self) { view in
                    view.i32 + (mapValue(view.index, "one") ?? 0)
                }
            }
        }
        return await group.reduce(0, +)
    }
    #expect(sum == -11 * 32)
}
