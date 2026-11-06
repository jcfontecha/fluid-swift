import Foundation
import FluidJS

/// Ports containerRuntime.ts creation metadata and the default 3.11 document schema.
/// Existing snapshots replace these creation values at load, including legacy missing metadata.
func initialSummaryMetadata(minVersionForCollab: String, runtimeOptions: JSONValue?) throws -> JSONValue {
    var runtime = JSObject<JSONValue>()
    runtime["explicitSchemaControl"] = .bool(true)
    runtime["compressionLz4"] = .bool(true)
    runtime["opGroupingEnabled"] = try runtimeOptions.flatMap { try field($0, "enableGroupedBatching") } ?? .bool(true)
    runtime["idCompressorMode"] = try runtimeOptions.flatMap { try field($0, "enableRuntimeIdCompressor") }
    let schema = object([("version", number(1)), ("refSeq", number(0)), ("info", object([("minVersionForCollab", string(minVersionForCollab))])), ("runtime", .object(runtime))])
    return object([
        ("createContainerRuntimeVersion", string("3.11.0")),
        ("createContainerTimestamp", .number((Date().timeIntervalSince1970 * 1000).rounded(.down))),
        ("summaryNumber", number(0)),
        ("gcFeature", number(3)),
        ("sessionExpiryTimeoutMs", number(2_592_000_000)),
        ("sweepEnabled", .bool(false)),
        ("tombstoneTimeoutMs", number(3_110_400_000)),
        ("telemetryDocumentId", string(UUID().uuidString.lowercased())),
        ("message", object([("sequenceNumber", number(-1))])),
        ("documentSchema", schema),
    ])
}
