import FluidJS

/// Ports codec/codecs.ts: application-owned immutable chunk references.
public protocol IncrementalEncoder {
    func shouldEncodeIncrementally(_ type: JSString, _ field: JSString?) -> Bool
    func encodeIncrementalField(_ content: BasicChunk, encode: (BasicChunk) throws -> JSONValue) throws -> [Int]
}
public protocol IncrementalDecoder {
    func decodeIncrementalChunk(_ reference: Int) throws -> JSONValue
}
