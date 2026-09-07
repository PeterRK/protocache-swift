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

## Repeatable optimization checks

Each process runs `--warmup N` untimed iterations (default 1000), then reports
an exact nanosecond measurement as a `measurement {...}` JSON line. The existing
human-readable output remains available. Setup and semantic validation are
outside the timed loop. For traversal, the JSON `checksum` describes one
validated untimed traversal; `accumulated_checksum` records the timed result.
Long floating-point sums can differ with randomized Dictionary iteration order,
so the accumulated checksum is diagnostic rather than an exact cross-process
identity. Timed integer sums are still checked exactly.

Keep two release builds made with the same compiler and benchmark driver, then
run alternating A/B pairs on one CPU:

```bash
python3 Benchmarks/compare.py \
  --baseline /path/to/baseline/Benchmark \
  --candidate Benchmarks/.build/release/Benchmark \
  --cpu 2 --rounds 9 --loops 300000 --output /tmp/protocache-ab.json
```

The report preserves binary SHA-256 values, CPU affinity, arguments, every raw
process output, individual samples, median ns/op, median paired percentage
change, and the number of faster pairs. Prefer paired changes when the host
clock or load drifts; the ratio of two independent medians can be misleading. A failed process or inconsistent output size/checksum stops the run.
On macOS, omit `--cpu`; record the host/toolchain and avoid concurrent builds or
other heavy work during measurements. A source revision and `swift --version`
should accompany archived reports.

Scale diagnostics do not require the ignored FlatBuffers binary fixture:

```bash
swift run --package-path Benchmarks -c release Benchmark \
  --only scale-hash --count 4096 --payload 0 --loops 1000 --warmup 100
swift run --package-path Benchmarks -c release Benchmark \
  --only scale-map --count 16 --payload 65536 --loops 1000 --warmup 100
swift run --package-path Benchmarks -c release Benchmark \
  --only scale-dynamic --count 256 --payload 64 --loops 1000 --warmup 100
```

`scale-hash` builds a public PerfectHash over distinct UTF-8 keys; `--payload`
adds that many suffix bytes to each key. `scale-map` serializes fully owned
mutable Map values, and `scale-dynamic` serializes the equivalent Protobuf
message; their payload option adds string bytes to every nested value. Both
reuse a public `SerializationBuffer`. All scale cases validate the constructed
index or every logical Map value before timing. Use counts around 16/17,
255/256, and 65535/65536 to exercise implementation and wire thresholds.
The A/B driver accepts these cases through `--case`, `--count`, and `--payload`.

For the common fixture, the A/B driver first writes one valid ProtoCache input
and gives that same file to both binaries through `PROTOCACHE_BENCH_INPUT`.
The report records its SHA-256 alongside the binary hashes. This keeps reading
and compression comparisons from varying with independently randomized Map
layouts; serialization itself still uses fresh random PerfectHash seeds.
