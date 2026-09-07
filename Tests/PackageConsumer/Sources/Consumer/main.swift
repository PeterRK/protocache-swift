import ProtoCache
import ProtoCacheCore

let empty = Bytes.empty
let compressed = Compression.compress(empty)
let restored = try Compression.decompress(compressed)
precondition(restored.count == empty.count)

print("ProtoCache products imported successfully")

var message = Test_MainMutable()
message.i32 = 42
message.object.str = "external consumer"
message.objects[7] = message.object
let buffer = SerializationBuffer()
try message.withSerializedSpan(using: buffer) { span in
    let view = Test_MainView(span)
    precondition(view.i32 == 42)
    precondition(view.object.str.equalsUTF8("external consumer"))
    precondition(view.objects.value(for: 7)?.str.equalsUTF8("external consumer") == true)
}
let output = try message.serialized()
let roundTrip = try Compression.decompress(Compression.compress(output))
precondition(roundTrip == output)
print("External generated readonly/mutable bindings passed")
