import CLZ4

/// LZ4 frames compatible with `lz4js` 0.2.0, which the TS container runtime uses for op
/// compression (`opCompressor.ts` / `opDecompressor.ts`).
public enum FluidLZ4 {
    public enum Error: Swift.Error { case malformed, compression }

    public static func compress(_ input: [UInt8]) throws -> [UInt8] {
        let bound = LZ4F_compressFrameBound(input.count, nil)
        guard LZ4F_isError(bound) == 0 else { throw Error.compression }
        var output = [UInt8](repeating: 0, count: bound)
        let size = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                LZ4F_compressFrame(destination.baseAddress, bound, source.baseAddress, input.count, nil)
            }
        }
        guard LZ4F_isError(size) == 0 else { throw Error.compression }
        output.removeSubrange(size...)
        return output
    }

    public static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        guard !input.isEmpty else { throw Error.malformed }
        var context: OpaquePointer?
        guard LZ4F_isError(LZ4F_createDecompressionContext(&context, UInt32(LZ4F_VERSION))) == 0 else {
            throw Error.malformed
        }
        defer { LZ4F_freeDecompressionContext(context) }

        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var offset = 0
        var hint = 1
        try input.withUnsafeBytes { source in
            // `hint` is 0 once the frame's end mark has been decoded.
            while hint != 0 {
                var consumed = input.count - offset
                var produced = chunk.count
                hint = chunk.withUnsafeMutableBytes { destination in
                    LZ4F_decompress(context, destination.baseAddress, &produced,
                                    source.baseAddress! + offset, &consumed, nil)
                }
                guard LZ4F_isError(hint) == 0 else { throw Error.malformed }
                // No progress with the frame unfinished means the input is truncated.
                guard hint == 0 || consumed > 0 || produced > 0 else { throw Error.malformed }
                offset += consumed
                output.append(contentsOf: chunk[..<produced])
            }
        }
        guard offset == input.count else { throw Error.malformed }
        return output
    }
}
