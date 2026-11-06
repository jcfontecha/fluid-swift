import FluidJS

/// ECMAScript `Number.parseFloat(string)`: skips leading whitespace and parses the longest prefix
/// that is a decimal literal (or `±Infinity`); `NaN` when there is none. Used for the compact
/// snapshot's `mrv`/`cv` gates, which compare `parseFloat` results, not semver.
func jsParseFloat(_ string: JSString) -> Double {
    let units = string.utf16
    var index = 0
    while index < units.count, isJSWhitespaceOrLineTerminator(units[index]) {
        index += 1
    }
    var literal = ""
    if index < units.count, units[index] == 0x2B || units[index] == 0x2D {
        literal.append(units[index] == 0x2D ? "-" : "+")
        index += 1
    }
    if matches(units, at: index, "Infinity") {
        return literal == "-" ? -Double.infinity : Double.infinity
    }
    var integerDigits = 0
    while index < units.count, isDigit(units[index]) {
        literal.append(Character(Unicode.Scalar(UInt8(units[index]))))
        integerDigits += 1
        index += 1
    }
    var fractionDigits = 0
    if index < units.count, units[index] == 0x2E {
        var cursor = index + 1
        var fraction = "."
        while cursor < units.count, isDigit(units[cursor]) {
            fraction.append(Character(Unicode.Scalar(UInt8(units[cursor]))))
            fractionDigits += 1
            cursor += 1
        }
        if integerDigits > 0 || fractionDigits > 0 {
            // "5." is a literal (the dot is consumed, so an exponent may follow); only digits are kept.
            if fractionDigits > 0 {
                literal.append(fraction)
            }
            index = cursor
        }
    }
    if integerDigits == 0 && fractionDigits == 0 {
        return .nan
    }
    if index < units.count, units[index] == 0x45 || units[index] == 0x65 {
        var cursor = index + 1
        var exponent = "e"
        if cursor < units.count, units[cursor] == 0x2B || units[cursor] == 0x2D {
            exponent.append(units[cursor] == 0x2D ? "-" : "+")
            cursor += 1
        }
        var exponentDigits = 0
        while cursor < units.count, isDigit(units[cursor]) {
            exponent.append(Character(Unicode.Scalar(UInt8(units[cursor]))))
            exponentDigits += 1
            cursor += 1
        }
        if exponentDigits > 0 {
            literal.append(exponent)
        }
    }
    // The literal now matches the decimal grammar, which Swift's `Double(_:)` parses with
    // correct rounding; only a malformed literal returns nil, and that cannot be built above.
    return Double(literal) ?? .nan
}

private func isDigit(_ unit: UInt16) -> Bool {
    unit >= 0x30 && unit <= 0x39
}

private func matches(_ units: ContiguousArray<UInt16>, at index: Int, _ text: StaticString) -> Bool {
    let expected = text.withUTF8Buffer { Array($0) }
    guard index + expected.count <= units.count else {
        return false
    }
    for offset in 0..<expected.count where units[index + offset] != UInt16(expected[offset]) {
        return false
    }
    return true
}

/// ECMAScript WhiteSpace and LineTerminator code points (the characters `parseFloat` trims).
private func isJSWhitespaceOrLineTerminator(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
        0xFEFF, 0x2000...0x200A:
        return true
    default:
        return false
    }
}

/// `Buffer.from(string, "base64")` as Node implements it: both the standard and URL-safe alphabets
/// are accepted, characters outside them (whitespace, `\n`, `!`, non-ASCII) are skipped, and
/// decoding stops at the first `=`. Leftover bits that do not fill a byte are discarded.
func decodeNodeBase64(_ string: JSString) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(string.utf16.count * 3 / 4)
    var accumulator: UInt32 = 0
    var bits = 0
    for unit in string.utf16 {
        if unit == 0x3D {
            break
        }
        guard let sextet = base64Value(unit) else {
            continue
        }
        accumulator = (accumulator << 6) | UInt32(sextet)
        bits += 6
        if bits >= 8 {
            bits -= 8
            bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
            accumulator &= (1 << UInt32(bits)) - 1
        }
    }
    return bytes
}

private func base64Value(_ unit: UInt16) -> UInt8? {
    switch unit {
    case 0x41...0x5A:
        return UInt8(unit - 0x41)
    case 0x61...0x7A:
        return UInt8(unit - 0x61 + 26)
    case 0x30...0x39:
        return UInt8(unit - 0x30 + 52)
    case 0x2B, 0x2D:
        return 62
    case 0x2F, 0x5F:
        return 63
    default:
        return nil
    }
}
