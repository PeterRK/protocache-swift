# ProtoCache Swift Benchmarks

The benchmark is a separate SwiftPM package so benchmark-only dependencies do
not enter the main package's build, test, or dependency graph.

## FlatBuffers fixture

The FlatBuffers comparison uses the same wire layout and logical JSON fixture
as the C++ and Rust implementations. Its alias-like fields use `_x_` instead
of `_`, because FlatBuffers 25.12.19 does not emit `_` as a valid Swift 6
identifier. Field names are not encoded in the binary, so this does not alter
the wire result.

Generate the Swift bindings and ignored binary fixture directly with
FlatBuffers 25.12.19:

```bash
flatc --binary -o Benchmarks/Sources/Benchmark/Fixtures \
  Benchmarks/Sources/Benchmark/Fixtures/test.fbs \
  Benchmarks/Sources/Benchmark/Fixtures/test-fb.json
flatc --swift -o Benchmarks/Sources/Benchmark/Generated \
  Benchmarks/Sources/Benchmark/Fixtures/test.fbs
```

Use exact `flatc 25.12.19` (`flatc --version`). The generated binary must be
1296 bytes and byte-for-byte identical to the Rust benchmark fixture; it is
intentionally excluded from version control. The benchmark verifies its size
and semantic checksum at startup.

## Build and run

```bash
swift build --package-path Benchmarks -c release
swift run --package-path Benchmarks -c release Benchmark --loops 1000000
swift run --package-path Benchmarks -c release Benchmark \
  --loops 1000000 --only flatbuffers
```

The cross-format cases use public APIs only:

- `protobuf`: deserialize a message and fully traverse it.
- `protocache`: construct a borrowed View and fully traverse it.
- `flatbuffers`: construct an unchecked root table and fully traverse it.
- `protobuf-serialize`, `protocache-serialize`: serialize one decoded Protobuf
  message; the ProtoCache case reuses the public `SerializationBuffer`.
- `pb-compress`, `pc-compress`, `fb-compress`: caller-buffer compression and
  decompression.
- `protocache-fully`, `protocache-partly`: ProtoCacheEX serialization after
  full or partial materialization, reusing the public `SerializationBuffer`.

All three traversal cases cover the same logical fields and feed the same
checksum. Stock Swift FlatBuffers string accessors return `String`, whereas the
C++ and Rust generated accessors borrow UTF-8 bytes. The reported Swift result
therefore reflects the official application-facing Swift API, not a pure
wire-format-only comparison.

ProtoCache and ProtoCacheEX serialization lend output only inside the callback
and therefore match the caller-owned buffer boundary and case names used by
the C++ and Rust benchmarks.
