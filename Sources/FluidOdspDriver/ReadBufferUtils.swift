/// Buffer class, used to sequentially read data. Used by tree code to reconstruct a tree from
/// binary representation.
///
/// Ports `ReadBuffer` from `odsp-driver/src/ReadBufferUtils.ts`. It wraps an `ArraySlice` so a
/// parsed blob can reference the caller's storage without a copy; every position it reports is
/// relative to the slice's first element, like a JS `Uint8Array` view with a non-zero `byteOffset`.
public final class ReadBuffer {
    private let data: ArraySlice<UInt8>
    private var index = 0

    public init(_ data: ArraySlice<UInt8>) {
        self.data = data
    }

    public convenience init(_ data: [UInt8]) {
        self.init(data[...])
    }

    public var buffer: ArraySlice<UInt8> { data }

    public var eof: Bool { index == data.count }

    public var pos: Int { index }

    public var length: Int { data.count }

    public func slice(_ start: Int, _ end: Int) -> [UInt8] {
        Array(data[(data.startIndex + start)..<(data.startIndex + end)])
    }

    public func reset() {
        index = 0
    }

    /// Reads a `lengthArg`-byte unsigned little-endian magnitude into a `Double`, accumulating in the
    /// same order as TS, so 8-byte values above 2^53 round exactly as they do in JS.
    public func read(_ lengthArg: Int = 1) throws -> Double {
        var res = 0.0
        var multiplier = 1.0
        var length = lengthArg
        while length > 0 {
            try fluidAssert(!eof, 0x223)  // "unexpected end of buffer"
            res += Double(data[data.startIndex + index]) * multiplier
            index += 1
            multiplier *= 256
            length -= 1
        }
        return res
    }

    /// `read()` for a marker code or single byte, without the `Double` accumulator.
    @inline(__always)
    func readByte() throws -> UInt8 {
        try fluidAssert(!eof, 0x223)  // "unexpected end of buffer"
        let byte = data[data.startIndex + index]
        index += 1
        return byte
    }

    public func skip(_ length: Double) throws {
        try fluidAssert(length >= 0, 0x224)  // "Skip length should be positive"
        try fluidAssert(length <= Double(data.count - index), 0x3dc)  // "skipping past size of buffer"
        index += Int(length)
    }
}
