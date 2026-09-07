import Testing
import ProtoCache
import ProtoCacheCore

@Test func recursiveMutableDefaultsAreFiniteAndSerializable() throws {
    for source in [Bytes.empty, try ProtoCache.serialize(Test_CyclicA(), as: Test_CyclicAView.self)] {
        var root = Test_CyclicAMutable(source)
        #expect(try root.serialized() == Bytes.empty)
        var child = root.cyclic
        #expect(child.value == 0)
        #expect(try child.serialized() == Bytes.empty)
        var grandchild = child.cyclic
        #expect(grandchild.value == 0)
        #expect(try grandchild.serialized() == Bytes.empty)
        #expect(try root.serialized() == Bytes.empty)
    }
    var root = Test_CyclicAMutable()
    root.cyclic.cyclic.value = 37
    let bytes = try root.serialized()
    #expect(bytes.withView(Test_CyclicAView.self) { $0.cyclic.cyclic.value } == 37)
}

@Test func recursiveMutableCopiesAndExtractedChildrenAreIsolated() throws {
    var pb = Test_CyclicA()
    pb.value = 1
    pb.cyclic.value = 2
    pb.cyclic.cyclic.value = 3
    var left = Test_CyclicAMutable(try ProtoCache.serialize(pb, as: Test_CyclicAView.self))
    var extracted = left.cyclic
    var right = left
    left.cyclic.cyclic.value = 11
    right.cyclic.cyclic.value = 22
    extracted.cyclic.value = 33
    #expect(try left.serialized().withView(Test_CyclicAView.self) { $0.cyclic.cyclic.value } == 11)
    #expect(try right.serialized().withView(Test_CyclicAView.self) { $0.cyclic.cyclic.value } == 22)
    #expect(try extracted.serialized().withView(Test_CyclicBView.self) { $0.cyclic.value } == 33)
    #expect(try left.serialized().withView(Test_CyclicAView.self) { $0.cyclic.value } == 2)
}

@Test func absentMutableMessageCanBeExtractedAndSerialized() throws {
    var root = Test_MainMutable()
    let child = root.object
    #expect(try child.serialized() == Bytes.empty)
    let alias = root.matrix
    #expect(try alias.serialized() == Test_Vec2DMutable().serialized())
    let mapAlias = root.arrays
    #expect(try mapAlias.serialized() == Test_ArrMapMutable().serialized())
    var tree = Test_RecursiveTreeMutable()
    let flags = tree.flags
    #expect(try flags.serialized() == Test_BooleanListMutable().serialized())
}

private func modifyRecursiveCopy(_ base: Test_CyclicAMutable, value: Int32) throws -> Int32 {
    var copy = base
    copy.cyclic.cyclic.value = value
    return try copy.serialized().withView(Test_CyclicAView.self) { $0.cyclic.cyclic.value }
}

@Test func recursiveMutableCopiesCanBeModifiedConcurrently() async throws {
    var base = Test_CyclicAMutable()
    base.cyclic.cyclic.value = 7
    let snapshot = base
    async let left = modifyRecursiveCopy(snapshot, value: 101)
    async let right = modifyRecursiveCopy(snapshot, value: 202)
    #expect(try await [left, right] == [101, 202])
    #expect(base.cyclic.cyclic.value == 7)
}

private func recursiveChain(pairs: Int) -> Test_CyclicAMutable {
    var root = Test_CyclicAMutable()
    root.value = 7
    for _ in 0..<pairs {
        var child = Test_CyclicBMutable()
        child.cyclic = root
        root = Test_CyclicAMutable()
        root.cyclic = child
    }
    return root
}

@Test func mutableRecursionLimitCoversEncodingAndEmptyChecks() throws {
    let allowed = recursiveChain(pairs: 50)
    let bytes = try allowed.serialized()
    #expect(bytes.count > 4)
    let excessive = recursiveChain(pairs: 51)
    #expect(throws: ProtoCacheError.recursionLimitExceeded) { try excessive.serialized() }
    #expect(throws: ProtoCacheError.recursionLimitExceeded) {
        try excessive._isProtoCacheEmpty()
    }
    let buffer = SerializationBuffer()
    #expect(throws: ProtoCacheError.recursionLimitExceeded) {
        try excessive.withSerializedSpan(using: buffer) { $0.count }
    }
    #expect(try allowed.withSerializedSpan(using: buffer) { $0.count } == bytes.count)
}

@Test func selfRecursiveAndContainerCopiesKeepIndependentValues() throws {
    var original = Test_RecursiveTreeMutable()
    original.value = 1
    original.next.value = 2
    original.children = [original.next]
    original.branches["leaf"] = original.next
    var copied = original
    original.next.value = 11
    copied.next.value = 22
    original.children[0].value = 33
    copied.branches["leaf"]!.value = 44
    let left = try original.serialized()
    let right = try copied.serialized()
    left.withView(Test_RecursiveTreeView.self) { root in
        #expect(root.next.value == 11)
        #expect(root.children[0].value == 33)
        #expect(root.branches.position(for: "leaf").map { root.branches.value(at: $0).value } == 2)
    }
    right.withView(Test_RecursiveTreeView.self) { root in
        #expect(root.next.value == 22)
        #expect(root.children[0].value == 2)
        #expect(root.branches.position(for: "leaf").map { root.branches.value(at: $0).value } == 44)
    }
}

@Test(arguments: [false, true])
func recursiveContainersShareDepthBudgetWithUntouchedSegments(useMap: Bool) throws {
    var tree = Test_RecursiveTreeMutable()
    tree.value = 7
    // Force the terminal message out of its cell so extent detection visits
    // every message edge, including the one at the depth boundary.
    tree.padding = Array(0..<32)
    for _ in 0..<50 {
        var parent = Test_RecursiveTreeMutable()
        if useMap { parent.branches["child"] = tree }
        else { parent.children = [tree] }
        tree = parent
    }
    let bytes = try tree.serialized()
    var partly = Test_RecursiveTreeMutable(bytes)
    partly.value = 9
    #expect(try partly.serialized().withView(Test_RecursiveTreeView.self) { $0.value } == 9)
    var parent = Test_RecursiveTreeMutable()
    if useMap { parent.branches["child"] = tree }
    else { parent.children = [tree] }
    #expect(throws: ProtoCacheError.recursionLimitExceeded) { try parent.serialized() }
    // An untouched child must consume the enclosing encoder's depth budget too.
    if useMap { parent.branches["child"] = Test_RecursiveTreeMutable(bytes) }
    else { parent.children = [Test_RecursiveTreeMutable(bytes)] }
    #expect(throws: ProtoCacheError.recursionLimitExceeded) { try parent.serialized() }
}
