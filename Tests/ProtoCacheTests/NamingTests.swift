import Testing
import ProtoCache
import ProtoCacheCore

@Test func qualifiedNamesSurviveSwiftPrefixesNestedTypesAndImports() throws {
    var message = Custom_Root()
    message.class = 11
    message.source = 22
    message.accessed = 33
    message.repeat.id = 44
    message.repeat.class.id = 66
    message.external.id = 55
    message.mode = .one
    message.switch = ["first", "second"]

    #expect(Custom_Root.protoMessageName == "names.deep.Root")
    #expect(Names_Deep_RootView._protoCacheLayout.fullName == "names.deep.Root")
    #expect(Names_Deep_Root_ChildView._protoCacheLayout.fullName == "names.deep.Root.Child")
    #expect(ExternalView._protoCacheLayout.fullName == "External")
    #expect(_123View._protoCacheLayout.fullName == "_123")

    let bytes = try ProtoCache.serialize(message, as: Names_Deep_RootView.self)
    bytes.withView(Names_Deep_RootView.self) { view in
        #expect(view.class == 11)
        #expect(view.source == 22)
        #expect(view.accessed == 33)
        #expect(view.repeat.id == 44)
        #expect(view.repeat.class.id == 66)
        #expect(view.external.id == 55)
        #expect(view.mode == .modeOne)
        #expect(view.switch.count == 2)
    }
    let child = try ProtoCache.serialize(message.repeat, as: Names_Deep_Root_ChildView.self)
    child.withView(Names_Deep_Root_ChildView.self) { #expect($0.id == 44) }
    let external = try ProtoCache.serialize(message.external, as: ExternalView.self)
    external.withView(ExternalView.self) { #expect($0.id == 55) }
    #expect(throws: ProtoCacheError.self) {
        try ProtoCache.serialize(message, as: Names_Deep_Root_ChildView.self)
    }
}

@Test func keywordAndReservedFieldsRoundTripThroughMutableStorage() throws {
    var message = Custom_Root()
    message.class = 1
    message.source = 2
    message.accessed = 3
    message.repeat.id = 4
    message.repeat.class.id = 6
    message.external.id = 5
    message.switch = ["original"]
    let bytes = try ProtoCache.serialize(message, as: Names_Deep_RootView.self)
    var mutable = Names_Deep_RootMutable(bytes)
    #expect(mutable.class == 1)
    #expect(mutable.source == 2)
    #expect(mutable.accessed == 3)
    #expect(mutable.repeat.id == 4)
    #expect(mutable.repeat.class.id == 6)
    #expect(mutable.external.id == 5)
    #expect(mutable.switch == ["original"])
    mutable.class += 10
    mutable.source += 10
    mutable.accessed += 10
    mutable.repeat.id += 10
    mutable.repeat.class.id += 10
    mutable.external.id += 10
    mutable.switch.append("updated")

    let buffer = SerializationBuffer()
    try mutable.withSerializedSpan(using: buffer) { span in
        let view = Names_Deep_RootView(span)
        #expect(view.class == 11)
        #expect(view.source == 12)
        #expect(view.accessed == 13)
        #expect(view.repeat.id == 14)
        #expect(view.repeat.class.id == 16)
        #expect(view.external.id == 15)
        #expect(view.switch.count == 2)
    }
    let output = try mutable.serialized()
    output.withView(Names_Deep_RootView.self) { #expect($0.class == 11) }
}

@Test func numericTypeNamesCompileAndSerialize() throws {
    var mutable = _123Mutable()
    mutable.id = 123
    let bytes = try mutable.serialized()
    bytes.withView(_123View.self) { #expect($0.id == 123) }
}
