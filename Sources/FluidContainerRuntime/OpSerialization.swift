import FluidJS

/// Ports opLifecycle/opSerialization.ts: wire JSON uses FluidJS, never Foundation JSON.
func serializeOp(_ runtimeOp: JSONValue) -> String {
  JSON.stringify(runtimeOp)
}
