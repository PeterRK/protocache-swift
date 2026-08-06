public enum ProtoCacheCompression {
    public static func compress(_ source: ProtoCacheBytes) -> ProtoCacheBytes {
        var output: [UInt8] = []
        source.withUnsafeBytes { compress($0, into: &output) }
        return ProtoCacheBytes(copying: output)
    }

    public static func compress(_ source: ProtoCacheBytes, into output: inout [UInt8]) {
        source.withUnsafeBytes { raw in compress(raw, into: &output) }
    }

    public static func compress(_ source: UnsafeRawBufferPointer, into output: inout [UInt8]) {
        output.removeAll(keepingCapacity: true)
        guard !source.isEmpty else { return }
        var length = source.count
        while length & ~0x7f != 0 { output.append(0x80 | UInt8(length & 0x7f)); length >>= 7 }
        output.append(UInt8(length))
        var position = 0
        while position < source.count {
            let firstStart = position
            let first = pickRun(source, position: &position)
            if position == source.count {
                output.append(first)
                if first & 8 == 0 { appendLiteral(source, firstStart, position, into: &output) }
                break
            }
            let secondStart = position
            let second = pickRun(source, position: &position)
            output.append(first | (second << 4))
            if first & 8 == 0 { appendLiteral(source, firstStart, secondStart, into: &output) }
            if second & 8 == 0 { appendLiteral(source, secondStart, position, into: &output) }
        }
    }

    public static func decompress(_ source: ProtoCacheBytes, limits: ProtoCacheDecompressionLimits = .default) throws -> ProtoCacheBytes {
        try source.withUnsafeBytes { raw in
            if raw.isEmpty { return .empty }
            let (target, bodyOffset) = try parseVarint(raw)
            guard target <= limits.maximumOutputBytes else { throw ProtoCacheError.outputLimitExceeded }
            guard target >= 0 else { throw ProtoCacheError.integerOverflow }
            if target == 0 {
                guard bodyOffset == raw.count else { throw ProtoCacheError.outputSizeMismatch }
                return .empty
            }
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: target, alignment: 4)
            do {
                var sourcePosition = bodyOffset
                var outputPosition = 0
                while sourcePosition < raw.count {
                    let mark = raw[sourcePosition]; sourcePosition += 1
                    try unpack(mark & 0x0f, source: raw, sourcePosition: &sourcePosition, output: pointer, outputPosition: &outputPosition, target: target)
                    try unpack(mark >> 4, source: raw, sourcePosition: &sourcePosition, output: pointer, outputPosition: &outputPosition, target: target)
                }
                guard outputPosition == target else { throw ProtoCacheError.outputSizeMismatch }
                return ProtoCacheBytes(adopting: pointer, count: target)
            } catch {
                pointer.deallocate()
                throw error
            }
        }
    }

    public static func decompress(_ source: ProtoCacheBytes, into output: inout [UInt8], limits: ProtoCacheDecompressionLimits = .default) throws {
        try source.withUnsafeBytes { raw in try decompress(raw, into: &output, limits: limits) }
    }

    public static func decompress(_ source: UnsafeRawBufferPointer, into output: inout [UInt8], limits: ProtoCacheDecompressionLimits = .default) throws {
        output.removeAll(keepingCapacity: true)
        if source.isEmpty { return }
        let (target, bodyOffset) = try parseVarint(source)
        guard target <= limits.maximumOutputBytes else { throw ProtoCacheError.outputLimitExceeded }
        output.reserveCapacity(target)
        output.append(contentsOf: repeatElement(0, count: target))
        do {
            try output.withUnsafeMutableBytes { destination in
                var sourcePosition = bodyOffset
                var outputPosition = 0
                while sourcePosition < source.count {
                    let mark = source[sourcePosition]; sourcePosition += 1
                    try unpack(mark & 0x0f, source: source, sourcePosition: &sourcePosition, output: destination.baseAddress!, outputPosition: &outputPosition, target: target)
                    try unpack(mark >> 4, source: source, sourcePosition: &sourcePosition, output: destination.baseAddress!, outputPosition: &outputPosition, target: target)
                }
                guard outputPosition == target else { throw ProtoCacheError.outputSizeMismatch }
            }
        } catch {
            output.removeAll(keepingCapacity: true)
            throw error
        }
    }

    private static func pickRun(_ source: UnsafeRawBufferPointer, position: inout Int) -> UInt8 {
        let start = position, first = source[start]
        position += 1
        if first == 0 || first == 0xff {
            while position < source.count && position - start < 4 && source[position] == first { position += 1 }
            return 8 | (first & 4) | UInt8(position - start - 1)
        }
        while position < source.count && position - start < 7 && source[position] != 0 && source[position] != 0xff { position += 1 }
        return UInt8(position - start)
    }

    private static func appendLiteral(_ source: UnsafeRawBufferPointer, _ start: Int, _ end: Int, into output: inout [UInt8]) {
        for position in start..<end { output.append(source[position]) }
    }

    private static func parseVarint(_ source: UnsafeRawBufferPointer) throws -> (Int, Int) {
        var size = 0, position = 0, shift = 0
        while shift < 35 {
            guard position < source.count else { throw ProtoCacheError.truncated }
            let byte = source[position]; position += 1
            if shift >= Int.bitWidth || Int(byte & 0x7f) > (Int.max >> shift) { throw ProtoCacheError.integerOverflow }
            size |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (size, position) }
            shift += 7
        }
        throw ProtoCacheError.invalidHeader
    }

    private static func unpack(_ mark: UInt8, source: UnsafeRawBufferPointer, sourcePosition: inout Int, output: UnsafeMutableRawPointer, outputPosition: inout Int, target: Int) throws {
        if outputPosition >= target {
            guard mark == 0 else { throw ProtoCacheError.outputSizeMismatch }
            return
        }
        if mark & 8 != 0 {
            let count = Int(mark & 3) + 1
            guard count <= target - outputPosition else { throw ProtoCacheError.outputSizeMismatch }
            let value: UInt8 = mark & 4 != 0 ? 0xff : 0
            output.advanced(by: outputPosition).initializeMemory(as: UInt8.self, repeating: value, count: count)
            outputPosition += count
        } else {
            let count = Int(mark & 7)
            guard count <= source.count - sourcePosition, count <= target - outputPosition else { throw ProtoCacheError.truncated }
            if count > 0 { output.advanced(by: outputPosition).copyMemory(from: source.baseAddress!.advanced(by: sourcePosition), byteCount: count) }
            sourcePosition += count; outputPosition += count
        }
    }
}
