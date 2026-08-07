import ProtoCache
import ProtoCacheCore

let empty = Bytes.empty
let compressed = Compression.compress(empty)
let restored = try Compression.decompress(compressed)
precondition(restored.count == empty.count)

print("ProtoCache products imported successfully")
