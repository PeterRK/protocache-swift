import Testing
import ProtoCache

private func modifiedObjectValue(_ base: Test_MainMutable, _ value: Int32) throws -> Int32 {
    var copy = base
    copy.object.i32 = value
    let storage = try copy.serialized()
    return storage.withView(Test_MainView.self) { $0.object.i32 }
}

@Test func mutableCopiesCanBeModifiedInSeparateTasks() async throws {
    let bytes = try ProtoCache.serialize(Test_Main(), as: Test_MainView.self)
    let base = Test_MainMutable(bytes)
    async let left = modifiedObjectValue(base, 101)
    async let right = modifiedObjectValue(base, 202)
    let values = try await [left, right]
    #expect(values == [101, 202])
    var untouched = base
    #expect(untouched.object.i32 == 0)
}
