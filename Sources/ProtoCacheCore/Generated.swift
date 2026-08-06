public enum _ProtoCacheScalarKind: String, Equatable, Sendable {
    case bool
    case int32
    case uint32
    case int64
    case uint64
    case float
    case double
}

public indirect enum _ProtoCacheFieldKind: @unchecked Sendable {
    case scalar(_ProtoCacheScalarKind)
    case enumeration
    case string
    case bytes
    case message(@Sendable () -> _ProtoCacheLayout)
    case array(@Sendable () -> _ProtoCacheFieldKind)
    case map(
        key: @Sendable () -> _ProtoCacheFieldKind,
        value: @Sendable () -> _ProtoCacheFieldKind
    )
}

public struct _ProtoCacheFieldLayout: Sendable {
    public let number: Int
    public let protoName: String
    public let kind: _ProtoCacheFieldKind

    public init(number: Int, protoName: String, kind: _ProtoCacheFieldKind) {
        self.number = number
        self.protoName = protoName
        self.kind = kind
    }
}

public struct _ProtoCacheLayout: Sendable {
    public let runtimeABI: UInt32
    public let fullName: String
    public let fields: [_ProtoCacheFieldLayout]
    public let isAlias: Bool

    public init(runtimeABI: UInt32 = 1, fullName: String, fields: [_ProtoCacheFieldLayout], isAlias: Bool = false) {
        self.runtimeABI = runtimeABI
        self.fullName = fullName
        self.fields = fields
        self.isAlias = isAlias
    }
}

public protocol GeneratedView: ProtoCacheDecodable {
    init(_ bytes: ProtoCacheBytes)
    var _protoCacheBytes: ProtoCacheBytes { get }
    static var _protoCacheLayout: _ProtoCacheLayout { get }
}

extension GeneratedView {
    public static func _decodeProtoCache(from field: FieldView) -> Self? {
        Self(field.objectBytes)
    }

    public static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing ProtoCacheBytes
    ) -> Self? {
        _protoCacheObjectBytes(
            fromRawWords: baseAddress,
            availableByteCount: availableByteCount,
            width: width,
            owner: owner
        ).map(Self.init)
    }
}

public struct ProtoCacheEnum<Domain>: RawRepresentable, Hashable, Sendable where Domain: Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
}

extension ProtoCacheEnum: ProtoCacheDecodable {
    public static func _decodeProtoCache(from field: FieldView) -> Self? {
        field.scalar(Int32.self).map(Self.init(rawValue:))
    }

    public static func _decodeProtoCache(
        fromRawWords baseAddress: UnsafeRawPointer,
        availableByteCount: Int,
        width: Int,
        owner: borrowing ProtoCacheBytes
    ) -> Self? {
        Int32._decodeProtoCache(
            fromRawWords: baseAddress,
            availableByteCount: availableByteCount,
            width: width,
            owner: owner
        ).map(Self.init(rawValue:))
    }
}
