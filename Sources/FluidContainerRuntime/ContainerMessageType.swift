/// Ports messageTypes.ts. groupedBatch is transport virtualization, not a logical runtime message.
public enum ContainerMessageType: String, CaseIterable, Sendable {
  case fluidDataStoreOp = "component"
  case attach
  case chunkedOp
  case blobAttach
  case rejoin
  case alias
  case idAllocation
  case documentSchemaChange = "schema"
  case gc = "GC"
}
