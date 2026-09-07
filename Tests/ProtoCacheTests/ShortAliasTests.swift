import Testing
import ProtoCache
import ProtoCacheCore
import SwiftProtobuf

@Test(arguments: 0...4)
func shortBooleanAliasesRoundTrip(size: Int) throws {
    let expected = (0..<size).map { $0 % 2 != 0 }
    var row = Test_BooleanList()
    row.___ = expected
    var mutable = Test_BooleanListMutable()
    mutable.value = expected
    let dynamic = try ProtoCache.serialize(row, as: Test_BooleanListView.self)
    let extra = try mutable.serialized()
    #expect(dynamic == extra)
    if size == 0 { #expect(dynamic.withUnsafeBytes { Array($0) } == [0, 0, 0, 0]) }
    let buffer = SerializationBuffer()
    for bytes in [dynamic, extra] {
        #expect(bytes.count == ((1 + size + 3) / 4) * 4)
        #expect(bytes.withUnsafeBytes { $0[0] } == UInt8(size << 2))
        bytes.withView(Test_BooleanListView.self) { view in
            #expect(view.count == size)
            var actual: [Bool] = []
            view.forEach { actual.append($0) }
            #expect(actual == expected)
            if view.count == size {
                for index in expected.indices { #expect(view[index] == expected[index]) }
            }
        }
        var decoded = Test_BooleanListMutable(bytes)
        #expect(decoded.value == expected)
        #expect(try decoded.serialized() == extra)
    }
    #expect(try ProtoCache.withSerializedSpan(row, using: buffer, as: Test_BooleanListView.self) {
        span in extra.withBorrowedSpan { span.elementsEqual($0) }
    })
    #expect(try mutable.withSerializedSpan(using: buffer) {
        span in extra.withBorrowedSpan { span.elementsEqual($0) }
    })

    var holder = Test_RecursiveTree()
    holder.flags = row
    var mutableHolder = Test_RecursiveTreeMutable()
    mutableHolder.flags = mutable
    for bytes in [
        try ProtoCache.serialize(holder, as: Test_RecursiveTreeView.self),
        try mutableHolder.serialized(),
    ] {
        bytes.withView(Test_RecursiveTreeView.self) { view in
            var actual: [Bool] = []
            view.flags.forEach { actual.append($0) }
            #expect(actual == expected)
        }
        var decoded = Test_RecursiveTreeMutable(bytes)
        #expect(decoded.flags.value == expected)
    }
}

@Test(arguments: 0...4)
func shortScalarAliasesRoundTrip(size: Int) throws {
    let expected = (0..<size).map { Float($0 - 1) }
    var row = Test_Vec2D.Vec1D()
    row.___ = expected
    var mutable = Test_Vec2D_Vec1DMutable()
    mutable.value = expected
    let dynamic = try ProtoCache.serialize(row, as: Test_Vec2D_Vec1DView.self)
    let extra = try mutable.serialized()
    #expect(dynamic == extra)
    #expect(dynamic.count == (1 + size) * 4)
    if size == 0 { #expect(dynamic.withUnsafeBytes { Array($0) } == [1, 0, 0, 0]) }
    #expect(dynamic.withUnsafeBytes { $0[0] } == UInt8((size << 2) | 1))
    dynamic.withView(Test_Vec2D_Vec1DView.self) { view in
        var actual: [Float] = []
        view.forEach { actual.append($0) }
        #expect(actual == expected)
    }
    var matrix = Test_Vec2D()
    matrix.___ = [row]
    var holder = Test_Main()
    holder.matrix = matrix
    var mutableHolder = Test_MainMutable()
    mutableHolder.matrix.value = [mutable]
    for bytes in [
        try ProtoCache.serialize(holder, as: Test_MainView.self),
        try mutableHolder.serialized(),
    ] {
        bytes.withView(Test_MainView.self) { view in
            #expect(view.matrix.count == 1)
            var actual: [Float] = []
            view.matrix[0].forEach { actual.append($0) }
            #expect(actual == expected)
        }
    }
}

@Test(arguments: 0...1)
func shortMapAliasesRoundTrip(size: Int) throws {
    var map = Test_ArrMap()
    var mutable = Test_ArrMapMutable()
    if size == 1 {
        map.___ = ["x": Test_ArrMap.Array()]
        mutable.value["x"] = Test_ArrMap_ArrayMutable()
    }
    let dynamic = try ProtoCache.serialize(map, as: Test_ArrMapView.self)
    let extra = try mutable.serialized()
    #expect(dynamic == extra)
    #expect(dynamic.count == (size == 0 ? 4 : 12))
    if size == 0 {
        #expect(dynamic.withUnsafeBytes { Array($0) } == [0, 0, 0, 0x50])
    }
    dynamic.withView(Test_ArrMapView.self) { view in
        let count = view.count
        #expect(count == size)
        if size == 1 {
            let valueIsEmpty = view.value(for: "x")?.isEmpty
            #expect(valueIsEmpty == true)
        }
    }
    let buffer = SerializationBuffer()
    #expect(try ProtoCache.withSerializedSpan(map, using: buffer, as: Test_ArrMapView.self) {
        span in extra.withBorrowedSpan { span.elementsEqual($0) }
    })
    #expect(try mutable.withSerializedSpan(using: buffer) {
        span in extra.withBorrowedSpan { span.elementsEqual($0) }
    })
    var holder = Test_Main()
    holder.arrays = map
    var mutableHolder = Test_MainMutable()
    mutableHolder.arrays = mutable
    for bytes in [
        try ProtoCache.serialize(holder, as: Test_MainView.self),
        try mutableHolder.serialized(),
    ] {
        bytes.withView(Test_MainView.self) { view in
            let count = view.arrays.count
            #expect(count == size)
            if size == 1 {
                let valueIsEmpty = view.arrays.value(for: "x")?.isEmpty
                #expect(valueIsEmpty == true)
            }
        }
    }
}

private func checkEmptyWideAlias<Message: SwiftProtobuf.Message, View: GeneratedView, Mutable: MutableValue>(
    _ message: Message, as view: View.Type, mutable: Mutable
) throws where View: ~Escapable {
    // The low two bits retain the two-word scalar width even with zero elements.
    let expected = Bytes(copying: [2, 0, 0, 0])
    let dynamic = try ProtoCache.serialize(message, as: view)
    #expect(dynamic == expected)
    let buffer = SerializationBuffer()
    #expect(try ProtoCache.withSerializedSpan(message, using: buffer, as: view) {
        span in expected.withBorrowedSpan { span.elementsEqual($0) }
    })
    for value in [Mutable(), Mutable(expected.slice(byteOffset: 0, count: 0)), mutable, Mutable(expected)] {
        #expect(try value.serialized() == expected)
        #expect(try value.withSerializedSpan(using: buffer) {
            span in expected.withBorrowedSpan { span.elementsEqual($0) }
        })
    }
}

@Test func emptyWideAliasesRetainScalarWidth() throws {
    var signed = Test_Int64ListMutable()
    signed.value = [Int64.min]
    signed.value.removeAll()
    try checkEmptyWideAlias(Test_Int64List(), as: Test_Int64ListView.self, mutable: signed)

    var unsigned = Test_UInt64ListMutable()
    unsigned.value = [UInt64.max]
    unsigned.value.removeAll()
    try checkEmptyWideAlias(Test_UInt64List(), as: Test_UInt64ListView.self, mutable: unsigned)

    var doubles = Test_DoubleListMutable()
    doubles.value = [1.5]
    doubles.value.removeAll()
    try checkEmptyWideAlias(Test_DoubleList(), as: Test_DoubleListView.self, mutable: doubles)
}
