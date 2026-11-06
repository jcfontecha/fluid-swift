/// `JSON.stringify` / `JSON.parse` with byte-identical JavaScript behavior.
public enum JSON {
    public static func stringify(_ value: JSONValue) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        write(value, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var text = text
        return try text.withUTF8 { bytes in
            try withUnsafeTemporaryAllocation(of: JSString?.self, capacity: Parser.recentStringSlots) { recentStrings in
                recentStrings.initialize(repeating: nil)
                defer { recentStrings.deinitialize() }
                var parser = Parser(bytes: bytes, recentStrings: recentStrings)
                parser.skipWhitespace()
                let value = try parser.parseValue()
                parser.skipWhitespace()
                guard parser.position == bytes.count else { throw parser.error("unexpected trailing input") }
                return value
            }
        }
    }

    /// ECMAScript `Number::toString(x)` for radix 10.
    public static func numberToString(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number == 0 { return "0" }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        var out: [UInt8] = []
        writeNumber(number, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    private static func writeInteger(_ value: UInt64, into out: inout [UInt8]) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { buffer in
            var value = value
            var start = buffer.count
            repeat {
                start -= 1
                buffer[start] = UInt8(value % 10) + 48
                value /= 10
            } while value != 0
            out.append(contentsOf: buffer[start...])
        }
    }

    private static func writeNumber(_ number: Double, into out: inout [UInt8]) {
        guard number.isFinite else {
            out.append(contentsOf: "null".utf8)
            return
        }
        if number == 0 {
            out.append(48)
            return
        }
        let magnitude = abs(number)
        if number < 0 { out.append(45) }
        // Every integer through 2^53 has an exact decimal expansion and JS uses fixed notation.
        if magnitude <= 9_007_199_254_740_992, magnitude.rounded(.towardZero) == magnitude {
            writeInteger(UInt64(magnitude), into: &out)
            return
        }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
            // Double.description yields Swift's shortest round-trip digits; only the layout differs
            // from ECMAScript, which the code below rewrites. (Public API only: no runtime hooks.)
            var count = 0
            for byte in magnitude.description.utf8 {
                buffer[count] = byte
                count += 1
            }
            var end = count
            var exponent = 0
            if let e = (0..<count).first(where: { buffer[$0] == 101 || buffer[$0] == 69 }) {
                end = e
                var i = e + 1
                let negative = buffer[i] == 45
                if buffer[i] == 45 || buffer[i] == 43 { i += 1 }
                while i < count {
                    exponent = exponent * 10 + Int(buffer[i] - 48)
                    i += 1
                }
                if negative { exponent = -exponent }
            }
            // Compact the mantissa in place; no String, scalar array or reparsing allocation.
            var k = 0
            var point = end
            for i in 0..<end {
                if buffer[i] == 46 { point = k } else {
                    buffer[k] = buffer[i]
                    k += 1
                }
            }
            var start = 0
            while start < k && buffer[start] == 48 { start += 1 }
            point -= start
            while k > start && buffer[k - 1] == 48 { k -= 1 }
            let n = point + exponent
            let length = k - start
            if length <= n && n <= 21 {
                out.append(contentsOf: buffer[start..<k])
                out.append(contentsOf: repeatElement(48, count: n - length))
            } else if 0 < n && n <= 21 {
                out.append(contentsOf: buffer[start..<(start + n)])
                out.append(46)
                out.append(contentsOf: buffer[(start + n)..<k])
            } else if -6 < n && n <= 0 {
                out.append(contentsOf: "0.".utf8)
                out.append(contentsOf: repeatElement(48, count: -n))
                out.append(contentsOf: buffer[start..<k])
            } else {
                out.append(buffer[start])
                if length > 1 {
                    out.append(46)
                    out.append(contentsOf: buffer[(start + 1)..<k])
                }
                out.append(101)
                out.append(n - 1 < 0 ? 45 : 43)
                writeInteger(UInt64(abs(n - 1)), into: &out)
            }
        }
    }

    private static func write(_ value: JSONValue, into out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let bool):
            out.append(contentsOf: (bool ? "true" : "false").utf8)
        case .number(let number):
            writeNumber(number, into: &out)
        case .string(let string):
            write(string, into: &out)
        case .array(let array):
            out.append(UInt8(ascii: "["))
            for (index, element) in array.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                write(element, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            out.append(UInt8(ascii: "{"))
            for (index, entry) in object.orderedEntries.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                write(entry.key, into: &out)
                out.append(UInt8(ascii: ":"))
                write(entry.value, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    /// `QuoteJSONString`: well-formed output, lone surrogates escaped as `\uXXXX` (lowercase hex).
    private static func write(_ string: JSString, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        let units = string.utf16
        var index = 0
        while index < units.count {
            let unit = units[index]
            index += 1
            switch unit {
            case 0x22: out.append(contentsOf: #"\""#.utf8)
            case 0x5C: out.append(contentsOf: #"\\"#.utf8)
            case 0x08: out.append(contentsOf: #"\b"#.utf8)
            case 0x0C: out.append(contentsOf: #"\f"#.utf8)
            case 0x0A: out.append(contentsOf: #"\n"#.utf8)
            case 0x0D: out.append(contentsOf: #"\r"#.utf8)
            case 0x09: out.append(contentsOf: #"\t"#.utf8)
            case 0x00..<0x20:
                writeUnicodeEscape(unit, into: &out)
            case 0xD800...0xDBFF where index < units.count && (0xDC00...0xDFFF).contains(units[index]):
                let scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index]) - 0xDC00)
                index += 1
                out.append(contentsOf: UTF8.encode(Unicode.Scalar(scalar)!)!)
            case 0xD800...0xDFFF:
                writeUnicodeEscape(unit, into: &out)
            case 0..<0x80:
                out.append(UInt8(unit))
            case 0x80..<0x800:
                out.append(UInt8(0xC0 | (unit >> 6)))
                out.append(UInt8(0x80 | (unit & 0x3F)))
            default:
                out.append(UInt8(0xE0 | (unit >> 12)))
                out.append(UInt8(0x80 | ((unit >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (unit & 0x3F)))
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    private static func writeUnicodeEscape(_ unit: UInt16, into out: inout [UInt8]) {
        let hex = Array("0123456789abcdef".utf8)
        out.append(contentsOf: #"\u"#.utf8)
        for shift in stride(from: 12, through: 0, by: -4) {
            out.append(hex[Int((unit >> UInt16(shift)) & 0xF)])
        }
    }
}

private struct Parser {
    /// Slots in the recent-string table; a power of two.
    static let recentStringSlots = 64
    /// Longer strings are rarely repeated and always get their own buffer.
    static let maxRecentStringLength = 32

    let bytes: UnsafeBufferPointer<UInt8>
    /// Short ASCII strings parsed so far, by hash of their bytes. Repeated keys and values ("type",
    /// "value", "Plain") share one buffer instead of each allocating, as V8 internalizes keys.
    /// A collision replaces the slot; sharing is invisible because JSString is a value type.
    let recentStrings: UnsafeMutableBufferPointer<JSString?>
    var position = 0

    init(bytes: UnsafeBufferPointer<UInt8>, recentStrings: UnsafeMutableBufferPointer<JSString?>) {
        self.bytes = bytes
        self.recentStrings = recentStrings
    }

    func error(_ message: String) -> JSONDecodingError {
        JSONDecodingError("JSON.parse: \(message) at byte \(position)")
    }

    mutating func skipWhitespace() {
        while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        guard position < bytes.count else { throw error("unexpected end of input") }
        switch bytes[position] {
        case UInt8(ascii: "{"): return .object(try parseObject())
        case UInt8(ascii: "["): return .array(try parseArray())
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    mutating func expectLiteral(_ literal: StaticString) throws {
        let count = literal.utf8CodeUnitCount
        guard position + count <= bytes.count,
              (0..<count).allSatisfy({ bytes[position + $0] == literal.utf8Start[$0] })
        else { throw error("invalid literal") }
        position += count
    }

    mutating func expect(_ byte: UInt8) throws {
        guard position < bytes.count, bytes[position] == byte else {
            throw error("expected '\(Character(Unicode.Scalar(byte)))'")
        }
        position += 1
    }

    mutating func parseObject() throws -> JSObject<JSONValue> {
        try expect(UInt8(ascii: "{"))
        var object = JSObject<JSONValue>()
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
            position += 1
            return object
        }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard position < bytes.count else { throw error("unterminated object") }
            if bytes[position] == UInt8(ascii: "}") {
                position += 1
                return object
            }
            try expect(UInt8(ascii: ","))
        }
    }

    mutating func parseArray() throws -> [JSONValue] {
        try expect(UInt8(ascii: "["))
        var array: [JSONValue] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
            position += 1
            return array
        }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            skipWhitespace()
            guard position < bytes.count else { throw error("unterminated array") }
            if bytes[position] == UInt8(ascii: "]") {
                position += 1
                return array
            }
            try expect(UInt8(ascii: ","))
        }
    }

    mutating func parseString() throws -> JSString {
        try expect(UInt8(ascii: "\""))
        let start = position
        while position < bytes.count {
            let byte = bytes[position]
            if byte == 34 {
                let string = asciiString(from: start, to: position)
                position += 1
                return string
            }
            if byte < 0x20 || byte >= 0x80 || byte == 92 { break }
            position += 1
        }
        var units = ContiguousArray<UInt16>()
        units.reserveCapacity(position - start + 8)
        for i in start..<position { units.append(UInt16(bytes[i])) }
        while true {
            guard position < bytes.count else { throw error("unterminated string") }
            let byte = bytes[position]
            switch byte {
            case UInt8(ascii: "\""):
                position += 1
                return JSString(utf16: units)
            case UInt8(ascii: "\\"):
                position += 1
                guard position < bytes.count else { throw error("unterminated escape") }
                let escape = bytes[position]
                position += 1
                switch escape {
                case UInt8(ascii: "\""): units.append(0x22)
                case UInt8(ascii: "\\"): units.append(0x5C)
                case UInt8(ascii: "/"): units.append(0x2F)
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "u"): units.append(try parseHexUnit())
                default: throw error("invalid escape")
                }
            case 0x00..<0x20:
                throw error("control character in string")
            case 0x00..<0x80:
                units.append(UInt16(byte))
                position += 1
            default:
                try appendUTF8Scalar(to: &units)
            }
        }
    }

    /// The string for `bytes[start..<end]`, all ASCII without escapes, reusing a recent equal one.
    func asciiString(from start: Int, to end: Int) -> JSString {
        let ascii = UnsafeBufferPointer(rebasing: bytes[start..<end])
        guard ascii.count <= Self.maxRecentStringLength else { return JSString(ascii: ascii) }
        // FNV-1a.
        var hash: UInt32 = 2_166_136_261
        for byte in ascii {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        let slot = Int(hash) & (Self.recentStringSlots - 1)
        if let recent = recentStrings[slot], recent.utf16.elementsEqual(ascii, by: { $0 == UInt16($1) }) {
            return recent
        }
        let string = JSString(ascii: ascii)
        recentStrings[slot] = string
        return string
    }

    mutating func parseHexUnit() throws -> UInt16 {
        guard position + 4 <= bytes.count else { throw error("short \\u escape") }
        var unit: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[position]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw error("invalid hex digit")
            }
            unit = unit << 4 | UInt16(digit)
            position += 1
        }
        return unit
    }

    /// Decodes one multi-byte UTF-8 scalar (input is valid UTF-8: it came from a Swift `String`).
    mutating func appendUTF8Scalar(to units: inout ContiguousArray<UInt16>) throws {
        let lead = bytes[position]
        let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
        guard position + length <= bytes.count else { throw error("truncated UTF-8") }
        var scalar = UInt32(lead) & (length == 4 ? 0x07 : length == 3 ? 0x0F : 0x1F)
        for offset in 1..<length {
            scalar = scalar << 6 | (UInt32(bytes[position + offset]) & 0x3F)
        }
        position += length
        units.append(contentsOf: UTF16.encode(Unicode.Scalar(scalar)!)!)
    }

    mutating func parseNumber() throws -> Double {
        let start = position
        func digits(_ parser: inout Parser) -> Int {
            let from = parser.position
            while parser.position < parser.bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(parser.bytes[parser.position]) {
                parser.position += 1
            }
            return parser.position - from
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "-") { position += 1 }
        guard position < bytes.count else { throw error("invalid number") }
        if bytes[position] == UInt8(ascii: "0") {
            position += 1
        } else if digits(&self) == 0 {
            throw error("invalid number")
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            position += 1
            guard digits(&self) > 0 else { throw error("invalid fraction") }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            guard digits(&self) > 0 else { throw error("invalid exponent") }
        }
        let negative = bytes[start] == 45
        let digitStart = start + (negative ? 1 : 0)
        // At most 15 decimal digits are exact; preserve negative zero as well.
        if position - digitStart <= 15 {
            var integer: UInt64 = 0
            var i = digitStart
            while i < position, bytes[i] >= 48, bytes[i] <= 57 {
                integer = integer * 10 + UInt64(bytes[i] - 48)
                i += 1
            }
            if i == position { return negative ? -Double(integer) : Double(integer) }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
        return Double(text)!
    }
}
