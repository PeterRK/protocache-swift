# ProtoCache Swift

An implementation of [ProtoCache](https://github.com/PeterRK/ProtoCache) for
Swift, including a Protobuf-free zero-copy runtime, eagerly materialized mutable
APIs, Protobuf serialization, compression, and a `protoc` code generator.

> [!WARNING]
>
> The `0.1.x` series is beta quality. The public API and generated-code runtime
> ABI may change before `1.0`; regenerate checked-in bindings when upgrading.
> The readonly API is a trusted-data hot path and is not a validator for hostile
> input.

## Products

| SwiftPM product | Import / executable | Purpose |
|:--|:--|:--|
| `protocache-core` | `ProtoCacheCore` | Protobuf-free bytes ownership, borrowed views, mutable runtime, encoding, hashing, and compression |
| `protocache` | `ProtoCache` | Protobuf message to ProtoCache serialization |
| `protoc-gen-pcsw` | executable | Generates typed readonly and optional mutable Swift bindings |

`ProtoCacheCore` and generated bindings do not depend on the Protobuf runtime.
FlatBuffers is used only by the separate benchmark package and never enters the
main package dependency graph.

## Requirements

- Swift 6.3 or newer with the experimental `Lifetimes` feature
- macOS 13 or newer, iOS 16 or newer, or 64-bit Linux
- `protoc` when generating bindings

Linux x86_64 is the fully exercised development platform. Manual CI also tests
macOS and builds/runs smoke tests in an iOS simulator.

## Installation

Add the package dependency in Xcode or in `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/PeterRK/protocache-swift.git",
        from: "0.1.0"
    ),
    .package(
        url: "https://github.com/apple/swift-protobuf.git",
        from: "1.38.0"
    ),
]
```

Depend on the smallest product that covers the application:

```swift
.target(
    name: "CacheReader",
    dependencies: [
        .product(name: "protocache-core", package: "protocache-swift"),
    ]
),
.target(
    name: "CacheWriter",
    dependencies: [
        .product(name: "protocache-core", package: "protocache-swift"),
        .product(name: "protocache", package: "protocache-swift"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
    ]
)
```

The writer target lists the Protobuf runtime explicitly because `ProtoCache`
does not re-export it or `ProtoCacheCore`.

For local development, use a path dependency instead:

```swift
.package(path: "../protocache-swift")
```

## Code generation

Build the generator and invoke it through `protoc`:

```bash
swift build -c release --product protoc-gen-pcsw
protoc \
  --plugin=protoc-gen-pcsw=.build/release/protoc-gen-pcsw \
  --pcsw_out=Sources/MyModel \
  --proto_path=Schemas \
  Schemas/model.proto
```

This produces `model.pc.swift`, containing typed readonly views. Pass the exact
`extra` option to additionally generate `model.pc-ex.swift` mutable types:

```bash
protoc \
  --plugin=protoc-gen-pcsw=.build/release/protoc-gen-pcsw \
  --pcsw_out=Sources/MyModel \
  --pcsw_opt=extra \
  --proto_path=Schemas \
  Schemas/model.proto
```

Generated files import only `ProtoCacheCore`. Commit them with the application
sources and regenerate them whenever the ProtoCache generated runtime ABI
changes. The current runtime ABI is `6`.

## Usage

Serialize a Protobuf message and read it without constructing a second object
graph:

```swift
import ProtoCache
import ProtoCacheCore
import SwiftProtobuf

let bytes = try ProtoCache.serialize(message, as: Example_UserView.self)

bytes.withView(Example_UserView.self) { user in
    print(user.id)
    user.name.withUnsafeUTF8 { utf8 in
        print(String(decoding: utf8, as: UTF8.self))
    }
}
```

Views borrow immutable storage. A view cannot escape the `withView` scope;
convert strings or bytes explicitly when an owned value is required.
Repeated Protobuf-to-ProtoCache serialization can reuse caller-owned storage:

```swift
let buffer = SerializationBuffer()
try ProtoCache.withSerializedSpan(
    message,
    using: buffer,
    as: Example_UserView.self
) { serialized in
    print(serialized.count)
}
```

Mutable bindings own their source and materialize a complete field the first
time its getter is accessed:

```swift
var user = Example_UserMutable(bytes)
user.name = "updated"
let updated = try user.serialized()

let buffer = SerializationBuffer()
try user.withSerializedSpan(using: buffer) { serialized in
    print(serialized.count)
}
```

Untouched fields reuse their original encoded segments. Accessed arrays, maps,
strings, bytes, and nested messages are fully owned Swift values. The runtime
does not use lazy element overlays or a general copy-on-write object graph.
`serialized()` returns owned bytes; `withSerializedSpan(using:_:)` reuses the
caller's buffer and lends its output only for the callback. A serialization
buffer is not safe for concurrent or reentrant use.

Compression has allocating and caller-buffer forms:

```swift
let compressed = Compression.compress(bytes)
let restored = try Compression.decompress(compressed)

var reusable: [UInt8] = []
Compression.compress(bytes, into: &reusable)
```

## Schema and compatibility

The generator supports proto3 scalar, enum, string, bytes, message, repeated,
map, nested/imported, recursive, and alias container schemas. A single
`repeated _ = 1` field is treated as a direct array/map alias, matching the C++
and Rust implementations.

Notable limitations include proto2 required/default semantics, groups,
extensions, MessageSet, services, and oneof active-case discrimination.
Unknown-field and presence round trips are not promised. See the upstream
[schema reference](https://github.com/PeterRK/ProtoCache/blob/main/schema.md)
and [binary format](https://github.com/PeterRK/ProtoCache/blob/main/data-format.md).

## Benchmark

Local Linux release results on the shared fixture, using public APIs and
reporting the median:

| | Protobuf | ProtoCache | FlatBuffers |
|:--|--:|--:|--:|
| Data size | **574B** | 780B | 1296B |
| Decode + traverse + dealloc | 9.496 us | **0.210 us** | 14.378 us |
| Compressed size | **566B** | 571B* | 856B |
| Compress | **0.630 us** | 0.834 us | 1.446 us |
| Decompress | **0.190 us** | 0.382 us | 0.816 us |

\* 571B follows the C++ and Rust benchmark's reference-fixture convention.
Compressed size is not a stable wire property: C++, Rust, and Swift vary the
initial 32-bit PerfectHash seed, so freshly serialized versions of the same
logical fixture can produce different valid layouts and compressed sizes. Given
identical input bytes, all three compression implementations produce
byte-for-byte identical output and can decompress each other's output.

Representative mutable and serialization paths:

| | Protobuf | ProtoCacheEX | ProtoCache |
|:--|--:|--:|--:|
| Serialize | 4.844 us | **0.475 us / 3.388 us** | 8.467 us |
| Decode + traverse + dealloc | 9.496 us | 2.538 us | **0.210 us** |

The two ProtoCacheEX serialization figures are partial-update and fully
materialized results, respectively. ProtoCache and ProtoCacheEX use the public
scoped buffer API, matching the C++/Rust benchmark. Generated FlatBuffers string
accessors return owned `String` values, whereas the C++ and Rust APIs borrow
bytes; the table therefore compares the public application APIs rather than
wire formats in isolation. See [Benchmarks/README.md](Benchmarks/README.md) for
reproduction details.

## Build and test

```bash
swift build
swift test
swift build -c release
swift build -c release --product protoc-gen-pcsw
```

The benchmark is intentionally isolated in a separate package:

```bash
swift run --package-path Benchmarks -c release Benchmark --loops 1000000
```

GitHub Actions workflows are deliberately manual-only. Run **CI** from the
Actions page before a release; it has no `push`, `pull_request`, or scheduled
trigger. The workflow verifies Linux, macOS, iOS simulator, Thread Sanitizer,
generator golden output, the Protobuf-free Core boundary, and an external
SwiftPM consumer.

## Release policy

The package is distributed as source through versioned Git tags. Before
creating a tag:

1. update `CHANGELOG.md` and the benchmark snapshot when behavior changed;
2. regenerate all checked-in `.pc.swift` and `.pc-ex.swift` bindings;
3. manually run the complete GitHub Actions **CI** workflow on the release
   commit and require every Linux/macOS/iOS job to pass;
4. verify wire/compression compatibility with a C++ or Rust fixture;
5. create an annotated Semantic Versioning tag such as `v0.1.0`.

## Security

Readonly typed views optimize trusted cached data and perform only structural
checks needed by their accessors. Validate untrusted data before exposing it to
the readonly runtime. Compression and serialization entry points return typed
errors for malformed input, overflow, output limits, schema mismatch, and
recursion limits.

Report suspected security issues privately to the maintainer rather than in a
public issue.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
