import FluidJS

/// `Buffer.toString("utf8")` as used by `Uint8ArrayToString` in Node: invalid sequences become
/// U+FFFD per WHATWG "maximal subpart" replacement, a BOM is kept, and the result is UTF-16 code
/// units, so no intermediate Swift `String` is built.
func decodeUTF8(_ bytes: ArraySlice<UInt8>) -> JSString {
    var units = ContiguousArray<UInt16>()
    units.reserveCapacity(bytes.count)
    var codePoint: UInt32 = 0
    var bytesNeeded = 0
    var bytesSeen = 0
    var lower: UInt8 = 0x80
    var upper: UInt8 = 0xBF
    var position = bytes.startIndex
    while position < bytes.endIndex {
        let byte = bytes[position]
        if bytesNeeded == 0 {
            switch byte {
            case 0x00...0x7F:
                units.append(UInt16(byte))
            case 0xC2...0xDF:
                bytesNeeded = 1
                codePoint = UInt32(byte & 0x1F)
            case 0xE0...0xEF:
                if byte == 0xE0 {
                    lower = 0xA0
                }
                if byte == 0xED {
                    upper = 0x9F
                }
                bytesNeeded = 2
                codePoint = UInt32(byte & 0x0F)
            case 0xF0...0xF4:
                if byte == 0xF0 {
                    lower = 0x90
                }
                if byte == 0xF4 {
                    upper = 0x8F
                }
                bytesNeeded = 3
                codePoint = UInt32(byte & 0x07)
            default:
                units.append(0xFFFD)
            }
            position += 1
            continue
        }
        if byte < lower || byte > upper {
            // The sequence ended early: emit one replacement and re-examine this byte as a lead byte.
            codePoint = 0
            bytesNeeded = 0
            bytesSeen = 0
            lower = 0x80
            upper = 0xBF
            units.append(0xFFFD)
            continue
        }
        lower = 0x80
        upper = 0xBF
        codePoint = (codePoint << 6) | UInt32(byte & 0x3F)
        bytesSeen += 1
        position += 1
        if bytesSeen == bytesNeeded {
            appendUTF16(codePoint, to: &units)
            codePoint = 0
            bytesNeeded = 0
            bytesSeen = 0
        }
    }
    if bytesNeeded != 0 {
        units.append(0xFFFD)
    }
    return JSString(utf16: units)
}

private func appendUTF16(_ codePoint: UInt32, to units: inout ContiguousArray<UInt16>) {
    if codePoint < 0x10000 {
        units.append(UInt16(codePoint))
        return
    }
    let offset = codePoint - 0x10000
    units.append(UInt16(0xD800 + (offset >> 10)))
    units.append(UInt16(0xDC00 + (offset & 0x3FF)))
}

/// `IsoBuffer.from(content, "utf8")`: lone surrogates have no UTF-8 form and encode as U+FFFD.
func encodeUTF8(_ string: JSString) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(string.utf16.count)
    var index = 0
    let units = string.utf16
    while index < units.count {
        let unit = units[index]
        index += 1
        switch unit {
        case 0x0000...0x007F:
            bytes.append(UInt8(unit))
        case 0x0080...0x07FF:
            bytes.append(UInt8(0xC0 | (unit >> 6)))
            bytes.append(UInt8(0x80 | (unit & 0x3F)))
        case 0xD800...0xDBFF:
            if index < units.count, units[index] >= 0xDC00, units[index] <= 0xDFFF {
                let codePoint = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index]) - 0xDC00)
                index += 1
                bytes.append(UInt8(0xF0 | (codePoint >> 18)))
                bytes.append(UInt8(0x80 | ((codePoint >> 12) & 0x3F)))
                bytes.append(UInt8(0x80 | ((codePoint >> 6) & 0x3F)))
                bytes.append(UInt8(0x80 | (codePoint & 0x3F)))
            } else {
                appendReplacement(to: &bytes)
            }
        case 0xDC00...0xDFFF:
            appendReplacement(to: &bytes)
        default:
            bytes.append(UInt8(0xE0 | (unit >> 12)))
            bytes.append(UInt8(0x80 | ((unit >> 6) & 0x3F)))
            bytes.append(UInt8(0x80 | (unit & 0x3F)))
        }
    }
    return bytes
}

private func appendReplacement(to bytes: inout [UInt8]) {
    bytes.append(0xEF)
    bytes.append(0xBF)
    bytes.append(0xBD)
}
