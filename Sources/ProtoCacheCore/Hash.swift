public enum ProtoCacheHash {
    @inline(__always) static func rotate(_ value: UInt64, _ amount: UInt64) -> UInt64 {
        (value << amount) | (value >> (64 - amount))
    }

    @inline(__always) static func mix(_ a0: UInt64, _ b0: UInt64, _ c0: UInt64, _ d0: UInt64) -> (UInt64, UInt64, UInt64, UInt64) {
        var a = a0, b = b0, c = c0, d = d0
        c = rotate(c, 50); c &+= d; a ^= c
        d = rotate(d, 52); d &+= a; b ^= d
        a = rotate(a, 30); a &+= b; c ^= a
        b = rotate(b, 41); b &+= c; d ^= b
        c = rotate(c, 54); c &+= d; a ^= c
        d = rotate(d, 48); d &+= a; b ^= d
        a = rotate(a, 38); a &+= b; c ^= a
        b = rotate(b, 37); b &+= c; d ^= b
        c = rotate(c, 62); c &+= d; a ^= c
        d = rotate(d, 34); d &+= a; b ^= d
        a = rotate(a, 5); a &+= b; c ^= a
        b = rotate(b, 36); b &+= c; d ^= b
        return (a, b, c, d)
    }

    @inline(__always) static func end(_ a0: UInt64, _ b0: UInt64, _ c0: UInt64, _ d0: UInt64) -> (UInt64, UInt64, UInt64, UInt64) {
        var a = a0, b = b0, c = c0, d = d0
        d ^= c; c = rotate(c, 15); d &+= c
        a ^= d; d = rotate(d, 52); a &+= d
        b ^= a; a = rotate(a, 26); b &+= a
        c ^= b; b = rotate(b, 51); c &+= b
        d ^= c; c = rotate(c, 28); d &+= c
        a ^= d; d = rotate(d, 9); a &+= d
        b ^= a; a = rotate(a, 47); b &+= a
        c ^= b; b = rotate(b, 54); c &+= b
        d ^= c; c = rotate(c, 32); d &+= c
        a ^= d; d = rotate(d, 25); a &+= d
        b ^= a; a = rotate(a, 63); b &+= a
        return (a, b, c, d)
    }

    public static func hash128(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> (UInt32, UInt32, UInt32, UInt32) {
        let magic: UInt64 = 0xdead_beef_dead_beef
        var a = seed, b = seed, c = magic, d = magic
        var offset = 0
        let longEnd = bytes.count & ~31
        while offset < longEnd {
            c &+= load64(bytes, offset); d &+= load64(bytes, offset + 8)
            (a, b, c, d) = mix(a, b, c, d)
            a &+= load64(bytes, offset + 16); b &+= load64(bytes, offset + 24)
            offset += 32
        }
        if bytes.count & 16 != 0 {
            c &+= load64(bytes, offset); d &+= load64(bytes, offset + 8)
            (a, b, c, d) = mix(a, b, c, d)
            offset += 16
        }
        let remaining = bytes.count - offset
        d &+= UInt64(bytes.count) << 56
        if remaining == 0 {
            c &+= magic; d &+= magic
        } else {
            let firstCount = min(8, remaining)
            for index in 0..<firstCount { c &+= UInt64(bytes[offset + index]) << UInt64(index * 8) }
            if remaining > 8 {
                for index in 8..<remaining { d &+= UInt64(bytes[offset + index]) << UInt64((index - 8) * 8) }
            }
        }
        (a, b, c, d) = end(a, b, c, d)
        return (UInt32(truncatingIfNeeded: a), UInt32(truncatingIfNeeded: a >> 32), UInt32(truncatingIfNeeded: b), UInt32(truncatingIfNeeded: b >> 32))
    }

    public static func hash128(_ bytes: [UInt8], seed: UInt64 = 0) -> (UInt32, UInt32, UInt32, UInt32) {
        bytes.withUnsafeBytes { hash128($0, seed: seed) }
    }

    @inline(__always) private static func load64(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: bytes.baseAddress!.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}
