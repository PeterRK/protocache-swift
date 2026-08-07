public enum Compression {
    public static func compress(_ source: Bytes) -> Bytes {
        source.withUnsafeBytes { input in
            guard !input.isEmpty else { return .empty }
            var headerCount = 1
            var remaining = input.count >> 7
            while remaining != 0 { headerCount += 1; remaining >>= 7 }
            let markerCount = input.count / 14 + (input.count % 14 == 0 ? 0 : 1)
            let capacity = headerCount + input.count + markerCount
            let output = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
            var outputPosition = 0

            func write(_ byte: UInt8) {
                output.storeBytes(of: byte, toByteOffset: outputPosition, as: UInt8.self)
                outputPosition += 1
            }

            var length = input.count
            while length & ~0x7f != 0 {
                write(0x80 | UInt8(length & 0x7f))
                length >>= 7
            }
            write(UInt8(length))

            func copyLiteral(_ start: Int, _ end: Int) {
                let count = end - start
                output.advanced(by: outputPosition).copyMemory(
                    from: input.baseAddress!.advanced(by: start), byteCount: count
                )
                outputPosition += count
            }

            var inputPosition = 0
            while inputPosition < input.count {
                let firstStart = inputPosition
                let first = pickRun(input, position: &inputPosition)
                if inputPosition == input.count {
                    write(first)
                    if first & 8 == 0 { copyLiteral(firstStart, inputPosition) }
                    break
                }
                let secondStart = inputPosition
                let second = pickRun(input, position: &inputPosition)
                write(first | (second << 4))
                if first & 8 == 0 { copyLiteral(firstStart, secondStart) }
                if second & 8 == 0 { copyLiteral(secondStart, inputPosition) }
            }
            return Bytes(adopting: output, count: outputPosition)
        }
    }

    public static func compress(_ source: Bytes, into output: inout [UInt8]) {
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

    public static func decompress(_ source: Bytes, limits: DecompressionLimits = .default) throws -> Bytes {
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
                let sourceBase = raw.baseAddress!
                let sourceCount = raw.count
                var sourcePosition = bodyOffset
                var outputPosition = 0
                while sourcePosition < sourceCount {
                    let mark = sourceBase.load(fromByteOffset: sourcePosition, as: UInt8.self); sourcePosition += 1
                    try unpack(mark & 0x0f, source: sourceBase, sourceCount: sourceCount, sourcePosition: &sourcePosition, output: pointer, outputPosition: &outputPosition, target: target)
                    try unpack(mark >> 4, source: sourceBase, sourceCount: sourceCount, sourcePosition: &sourcePosition, output: pointer, outputPosition: &outputPosition, target: target)
                }
                guard outputPosition == target else { throw ProtoCacheError.outputSizeMismatch }
                return Bytes(adopting: pointer, count: target)
            } catch {
                pointer.deallocate()
                throw error
            }
        }
    }

    public static func decompress(_ source: Bytes, into output: inout [UInt8], limits: DecompressionLimits = .default) throws {
        try source.withUnsafeBytes { raw in try decompress(raw, into: &output, limits: limits) }
    }

    public static func decompress(_ source: UnsafeRawBufferPointer, into output: inout [UInt8], limits: DecompressionLimits = .default) throws {
        output.removeAll(keepingCapacity: true)
        if source.isEmpty { return }
        let (target, bodyOffset) = try parseVarint(source)
        guard target <= limits.maximumOutputBytes else { throw ProtoCacheError.outputLimitExceeded }
        output.reserveCapacity(target)
        output.append(contentsOf: repeatElement(0, count: target))
        do {
            try output.withUnsafeMutableBytes { destination in
                let sourceBase = source.baseAddress!
                let sourceCount = source.count
                var sourcePosition = bodyOffset
                var outputPosition = 0
                while sourcePosition < sourceCount {
                    let mark = sourceBase.load(fromByteOffset: sourcePosition, as: UInt8.self); sourcePosition += 1
                    try unpack(mark & 0x0f, source: sourceBase, sourceCount: sourceCount, sourcePosition: &sourcePosition, output: destination.baseAddress!, outputPosition: &outputPosition, target: target)
                    try unpack(mark >> 4, source: sourceBase, sourceCount: sourceCount, sourcePosition: &sourcePosition, output: destination.baseAddress!, outputPosition: &outputPosition, target: target)
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
        let signed = Int8(bitPattern: first)
        if signed == signed >> 1 {
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

    @inline(__always)
    private static func unpack(_ mark: UInt8, source: UnsafeRawPointer, sourceCount: Int, sourcePosition: inout Int, output: UnsafeMutableRawPointer, outputPosition: inout Int, target: Int) throws {
        if outputPosition >= target {
            guard mark == 0 else { throw ProtoCacheError.outputSizeMismatch }
            return
        }
        if mark & 8 != 0 {
            let count = Int(mark & 3) + 1
            guard count <= target - outputPosition else { throw ProtoCacheError.outputSizeMismatch }
            let destination = output.advanced(by: outputPosition)
            if target - outputPosition >= 4 {
                let value: UInt32 = mark & 4 != 0 ? .max : 0
                destination.storeBytes(of: value, as: UInt32.self)
            } else {
                let value: UInt8 = mark & 4 != 0 ? 0xff : 0
                destination.initializeMemory(as: UInt8.self, repeating: value, count: count)
            }
            outputPosition += count
        } else {
            let count = Int(mark & 7)
            guard count <= sourceCount - sourcePosition, count <= target - outputPosition else { throw ProtoCacheError.truncated }
            if count > 0 {
                let destination = output.advanced(by: outputPosition)
                let sourceBytes = source.advanced(by: sourcePosition)
                if sourceCount - sourcePosition >= 8 && target - outputPosition >= 8 {
                    let word = sourceBytes.loadUnaligned(as: UInt64.self)
                    destination.storeBytes(of: word, as: UInt64.self)
                } else {
                    destination.copyMemory(from: sourceBytes, byteCount: count)
                }
            }
            sourcePosition += count; outputPosition += count
        }
    }
}
