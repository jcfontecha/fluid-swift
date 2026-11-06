/// The `NodeType` union of `zipItDataRepresentationUtils.ts`: the kind of a decoded tree element,
/// reported by `throwBufferParseException` as `nodeType` / `expectedNodeType`.
public enum NodeType: String, Sendable {
    case number = "Number"
    case blobCore = "BlobCore"
    case nodeCore = "NodeCore"
    case boolean = "Boolean"
    case unknownType = "UnknownType"
    case string = "String"
}

/// Every way the compact snapshot codec fails in the TS oracle.
///
/// Fluid `assert(cond, 0xNNN)` throws `Error("0xNNN")`, `throwBufferParseException` throws a
/// non-retryable `incorrectServerResponse`, the marker switch throws `Error("Invalid code: N")`, and
/// reading a property of a missing element is a JS `TypeError`. The cases keep those apart so the
/// differential harness can compare failure kind and payload, not just "it threw".
public enum OdspSnapshotError: Error, Equatable, Sendable {
    /// `assert(condition, code)` from `@fluidframework/core-utils`. The spec lists every code.
    case assertionFailed(code: Int)
    /// `throw new Error(`Invalid code: ${code}`)` for a marker byte outside the grammar.
    case invalidCode(Int)
    /// `NonRetryableError("Buffer parsing exception: <message>", incorrectServerResponse, ...)`.
    /// `message` already carries the `Buffer parsing exception: ` prefix.
    case bufferParsing(message: String, nodeType: NodeType, expectedNodeType: NodeType)
    /// A JS `TypeError` raised because the TS code dereferenced `undefined`
    /// (missing child index, missing property, popped past the root).
    case undefinedAccess
    /// `JSON.parse` of a delta string threw a `SyntaxError`.
    case invalidJSON
    /// A parsed sequence number does not fit the protocol's exact-integer range (ARCHITECTURE §3).
    /// TS accepts any `number` here; Swift protocol counters are `Int` below 2^53.
    case sequenceNumberOutOfRange
}

/// `assert(condition, code)` from `@fluidframework/core-utils`.
@inline(__always)
func fluidAssert(_ condition: Bool, _ code: Int) throws {
    if !condition {
        throw OdspSnapshotError.assertionFailed(code: code)
    }
}
