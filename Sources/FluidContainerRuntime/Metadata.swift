import FluidJS

/// Ports metadata.ts: metadata stays open to runtime-owned fields
/// Absent is not null.
func asBatchMetadata(_ metadata: JSONValue?) throws -> JSObject<JSONValue>? {
  try metadata?.asObject()
}
