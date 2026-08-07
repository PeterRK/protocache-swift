public enum ProtoCacheError: Error, Equatable, Sendable {
    case truncated
    case invalidHeader
    case invalidUTF8
    case integerOverflow
    case outputLimitExceeded
    case outputSizeMismatch
    case duplicateMapKey
    case perfectHashBuildFailed
    case invalidSchema(String)
    case typeMismatch(String)
    case recursionLimitExceeded
}

extension ProtoCacheError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .truncated: "truncated input"
        case .invalidHeader: "invalid header"
        case .invalidUTF8: "invalid UTF-8"
        case .integerOverflow: "integer overflow"
        case .outputLimitExceeded: "decompressed output exceeds configured limit"
        case .outputSizeMismatch: "decompressed output size mismatch"
        case .duplicateMapKey: "duplicate map key"
        case .perfectHashBuildFailed: "unable to construct perfect hash"
        case .invalidSchema(let reason): "invalid schema: \(reason)"
        case .typeMismatch(let reason): "type mismatch: \(reason)"
        case .recursionLimitExceeded: "recursion limit exceeded"
        }
    }
}

public struct DecompressionLimits: Sendable, Hashable {
    public var maximumOutputBytes: Int

    public init(maximumOutputBytes: Int = 256 * 1024 * 1024) {
        precondition(maximumOutputBytes >= 0)
        self.maximumOutputBytes = maximumOutputBytes
    }

    public static let `default` = DecompressionLimits()
}
