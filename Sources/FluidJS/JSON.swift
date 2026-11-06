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
            var parser = Parser(bytes: bytes)
            parser.skipWhitespace()
            let value = try parser.parseValue()
            parser.skipWhitespace()
            guard parser.position == bytes.count else { throw parser.error("unexpected trailing input") }
            return value
        }
    }

    /// ECMAScript `Number::toString(x)` for radix 10.
    public static func numberToString(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number == 0 { return "0" }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        if number < 0 { return "-" + numberToString(-number) }

        let (digits, n) = shortestDigits(number)
        let k = digits.count
        var out = ""
        if k <= n && n <= 21 {
            out.unicodeScalars.append(contentsOf: digits)
            out += String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            out.unicodeScalars.append(contentsOf: digits[..<n])
            out += "."
            out.unicodeScalars.append(contentsOf: digits[n...])
        } else if -6 < n && n <= 0 {
            out = "0." + String(repeating: "0", count: -n)
            out.unicodeScalars.append(contentsOf: digits)
        } else {
            out.unicodeScalars.append(digits[0])
            if k > 1 {
                out += "."
                out.unicodeScalars.append(contentsOf: digits[1...])
            }
            out += n - 1 < 0 ? "e-" : "e+"
            out += String(abs(n - 1))
        }
        return out
    }

    /// Shortest round-trip decimal digits of a positive finite double, and the exponent `n` such
    /// that the value is `0.d₁d₂…dₖ × 10ⁿ` (the `n` of ECMAScript `Number::toString`).
    /// Swift's `description` already produces the shortest round-trip digits; only its layout
    /// differs from ECMAScript, so the digits are lifted out of it.
    private static func shortestDigits(_ number: Double) -> (digits: [Unicode.Scalar], exponent: Int) {
        let text = number.description.unicodeScalars
        let exponentStart = text.firstIndex { $0 == "e" || $0 == "E" }
        var exponent = 0
        if let exponentStart {
            exponent = Int(String(String.UnicodeScalarView(text[text.index(after: exponentStart)...])))!
        }
        var digits: [Unicode.Scalar] = []
        var pointPosition: Int?
        for scalar in text[..<(exponentStart ?? text.endIndex)] {
            if scalar == "." { pointPosition = digits.count } else { digits.append(scalar) }
        }
        var point = pointPosition ?? digits.count
        let leadingZeros = digits.prefix { $0 == "0" }.count
        digits.removeFirst(leadingZeros)
        point -= leadingZeros
        while digits.last == "0" { digits.removeLast() }
        return (digits, point + exponent)
    }

    private static func write(_ value: JSONValue, into out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let bool):
            out.append(contentsOf: (bool ? "true" : "false").utf8)
        case .number(let number):
            out.append(contentsOf: (number.isFinite ? numberToString(number) : "null").utf8)
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
            for (index, entry) in object.entries.enumerated() {
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
            default:
                out.append(contentsOf: UTF8.encode(Unicode.Scalar(unit)!)!)
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
    let bytes: UnsafeBufferPointer<UInt8>
    var position = 0

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
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

    mutating func expect(_ byte: Character) throws {
        guard position < bytes.count, bytes[position] == byte.asciiValue! else { throw error("expected '\(byte)'") }
        position += 1
    }

    mutating func parseObject() throws -> JSObject<JSONValue> {
        try expect("{")
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
            try expect(":")
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard position < bytes.count else { throw error("unterminated object") }
            if bytes[position] == UInt8(ascii: "}") {
                position += 1
                return object
            }
            try expect(",")
        }
    }

    mutating func parseArray() throws -> [JSONValue] {
        try expect("[")
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
            try expect(",")
        }
    }

    mutating func parseString() throws -> JSString {
        try expect("\"")
        var units = ContiguousArray<UInt16>()
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
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
        return Double(text)!
    }
}
