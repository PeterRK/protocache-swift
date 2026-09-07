# Changelog

## Unreleased

### Generated bindings

- Generated runtime ABI is now 7. Regenerate readonly and mutable bindings when
  upgrading. Bindings explicitly record their ABI; mutable encoding and empty
  checks propagate a recursion depth budget.

### Fixes

- Recursive mutable fields start without an allocated box, preventing infinite
  recursion during default and source-backed initialization. First access still
  materializes the field, and copies retain independent values.
- Extracted absent message values can be serialized as canonical empty values.
- Mutable serialization rejects excessive recursion, including recursive arrays,
  maps, empty checks, and untouched nested segments.
- Large PerfectHash graphs allow up to 128 seed attempts instead of 16,
  recovering a deterministic valid 256-key case that previously failed. The
  retry budget remains finite; wire layout and successful earlier attempts are
  unchanged.

### Performance

- Large payload copying and overlapping reverse-buffer compaction use the Swift
  standard library's bulk memory move for ranges of at least 64 bytes. Small
  ranges keep the existing word loop; wire layout and ownership are unchanged.

### Validation

- Added executable recursive construction, copy isolation, concurrency, and
  recursion boundary tests.
- Missing local golden fixtures are reported as skipped tests. Release checks
  require them with `PROTOCACHE_REQUIRE_GOLDEN=1`.
