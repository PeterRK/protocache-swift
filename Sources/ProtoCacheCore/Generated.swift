public enum _ProtoCacheScalarKind: String, Equatable, Sendable {
    case bool
    case int32
    case uint32
    case int64
    case uint64
    case float
    case double
}

public enum _ProtoCacheFieldKind: Sendable {
    case scalar(_ProtoCacheScalarKind)
    case enumeration
    case string
    case bytes
    case message(@Sendable () -> _ProtoCacheLayout)
    indirect case array(_ProtoCacheFieldKind)
    indirect case map(
        key: _ProtoCacheFieldKind,
        value: _ProtoCacheFieldKind
    )
}

public struct _ProtoCacheFieldLayout: Sendable {
    public let number: Int
    public let kind: _ProtoCacheFieldKind

    public init(number: Int, kind: _ProtoCacheFieldKind) {
        self.number = number
        self.kind = kind
    }
}

public final class _ProtoCacheLayout: Sendable {
    public let runtimeABI: UInt32
    public let fullName: String
    public let fields: [_ProtoCacheFieldLayout]
    public let isAlias: Bool
    public let _fieldCount: Int
    public let _kindsByNumber: [_ProtoCacheFieldKind?]
    public let _hasValidFieldNumbers: Bool

    public init(runtimeABI: UInt32 = 6, fullName: String, fields: [_ProtoCacheFieldLayout], isAlias: Bool = false) {
        self.runtimeABI = runtimeABI
        self.fullName = fullName
        self.fields = fields
        self.isAlias = isAlias
        var maximum = 1
        var valid = true
        for field in fields {
            if (1...6387).contains(field.number) {
                maximum = max(maximum, field.number)
            } else {
                valid = false
            }
        }
        var kindsByNumber = [_ProtoCacheFieldKind?](repeating: nil, count: maximum + 1)
        for field in fields where (1...6387).contains(field.number) {
            if kindsByNumber[field.number] == nil {
                kindsByNumber[field.number] = field.kind
            } else {
                valid = false
            }
        }
        self._fieldCount = maximum
        self._kindsByNumber = kindsByNumber
        self._hasValidFieldNumbers = valid
    }

    @inline(__always)
    public func _kind(_ number: Int) -> _ProtoCacheFieldKind? {
        guard number >= 0, number < _kindsByNumber.count else { return nil }
        return _kindsByNumber[number]
    }
}

public protocol GeneratedView: ~Escapable, FieldDecodable {
    @_lifetime(copy bytes)
    init(_ bytes: Span)
    var _protoCacheSpan: Span {
        @_lifetime(borrow self)
        borrowing get
    }
    static var _protoCacheLayout: _ProtoCacheLayout { get }
}

extension Bytes {
    @inlinable @inline(__always)
    public borrowing func withView<View: GeneratedView, R>(
        _ type: View.Type = View.self,
        _ body: (borrowing View) throws -> R
    ) rethrows -> R where View: ~Escapable {
        try withBorrowedSpan { span in
            try body(View(span))
        }
    }
}
