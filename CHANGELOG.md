# Changelog

## Unreleased

### Generated bindings

- Generated runtime ABI is now 7. Regenerate readonly and mutable bindings when
  upgrading. Bindings explicitly record their ABI; mutable encoding and empty
  checks propagate a recursion depth budget.

### Internal cleanup

- Removed the unused schema-driven `copy(_:kind:in:)` support API and its
  recursive extent walker. Current ABI 7 bindings use generated detectors.
- Shared root materialization, byte-sequence encoding, compression traversal,
  and decompression validation while retaining owned and caller-buffer APIs.
- Centralized generator scalar classification and empty-array widths; removed
  redundant internal parameters and PerfectHash branches. `MutableMap` and
  generated runtime ABI 7 remain unchanged.

### Fixes

- Generator rejects colliding Swift symbols and references to filtered or
  unresolved message/enum types, including nested and map value references.
  Numeric type names receive a valid Swift prefix without changing their
  Protobuf full names. Mutable backing storage handles keyword fields and
  avoids reserved runtime names.
- Caller-buffer decompression now rejects trailing bytes after a zero-length
  payload, matching the owned-output API.
- Recursive mutable fields start without an allocated box, preventing infinite
  recursion during default and source-backed initialization. First access still
  materializes the field, and copies retain independent values.
- Extracted absent message values can be serialized as canonical empty values.
- Mutable serialization rejects excessive recursion, including recursive arrays,
  maps, empty checks, and untouched nested segments.
- PerfectHash construction uses a uniform limit of 40 seed attempts for all
  graph sizes, reducing the large-graph limit from 128. Wire layout and
  successful attempts within the limit are unchanged.

### Performance

- Generator precomputes direct message edges and visits each reachable node
  once per recursion query, avoiding exponential searches in converging schemas.
- Large payload copying and overlapping reverse-buffer compaction use the Swift
  standard library's bulk memory move for ranges of at least 64 bytes. Small
  ranges keep the existing word loop; wire layout and ownership are unchanged.

### Validation

- Added compression golden runs, mixed-payload round trips, zero-length error
  checks, and byte-sequence varint boundaries across owned and reusable output.

- Added executable recursive construction, copy isolation, concurrency, and
  recursion boundary tests.
- Missing local golden fixtures are reported as skipped tests. Release checks
  require them with `PROTOCACHE_REQUIRE_GOLDEN=1`.
