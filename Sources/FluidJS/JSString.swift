/// A JavaScript string: a sequence of UTF-16 code units, which may include lone surrogates.
///
/// Lengths and offsets are UTF-16 code-unit counts, exactly as `String.prototype.length` in JS.
public struct JSString: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var utf16: ContiguousArray<UInt16>

    public init(utf16: ContiguousArray<UInt16>) {
        self.utf16 = utf16
    }

    public init(_ string: String) {
        self.utf16 = ContiguousArray(string.utf16)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var length: Int { utf16.count }

    /// Lossy for lone surrogates (they decode as U+FFFD); use `utf16` for exact content.
    public var description: String { String(decoding: utf16, as: UTF16.self) }

    /// The array index this key denotes under ECMAScript property-key rules
    /// (canonical decimal `0`…`4294967294`), or `nil` for any other key.
    var arrayIndex: UInt32? {
        let units = utf16
        guard let first = units.first, units.count <= 10 else { return nil }
        if first == 0x30 { return units.count == 1 ? 0 : nil }
        var value: UInt64 = 0
        for unit in units {
            guard unit >= 0x30, unit <= 0x39 else { return nil }
            value = value * 10 + UInt64(unit - 0x30)
        }
        return value <= 4_294_967_294 ? UInt32(value) : nil
    }
}
