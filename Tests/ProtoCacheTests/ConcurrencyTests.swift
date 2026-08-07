import Testing
import ProtoCache

@Test func mutableCopiesCanBeModifiedInSeparateTasks() async throws {
    let bytes = try ProtoCache.serialize(Test_Main(), as: Test_MainView.self)
    let base = Test_MainMutable(bytes)
    async let left: Int32 = {
        var copy = base
        copy.object.i32 = 101
        let storage = try copy.serialized()
        return storage.withView(Test_MainView.self) { $0.object.i32 }
    }()
    async let right: Int32 = {
        var copy = base
        copy.object.i32 = 202
        let storage = try copy.serialized()
        return storage.withView(Test_MainView.self) { $0.object.i32 }
    }()
    let values = try await [left, right]
    #expect(values == [101, 202])
    #expect(base.object.i32 == 0)
}
