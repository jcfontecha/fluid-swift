import FluidJS

/// Ports opLifecycle/definitions.ts: logical messages before transport virtualization.
public struct LocalBatchMessage {
  public var runtimeOp: JSONValue
  public var metadata: JSONValue?
  public var localOpMetadata: JSONValue?
  public var referenceSequenceNumber: Int
  public var staged: Bool
  public init(
    runtimeOp: JSONValue, referenceSequenceNumber: Int, metadata: JSONValue? = nil,
    localOpMetadata: JSONValue? = nil, staged: Bool = false
  ) {
    self.runtimeOp = runtimeOp
    self.referenceSequenceNumber = referenceSequenceNumber
    self.metadata = metadata
    self.localOpMetadata = localOpMetadata
    self.staged = staged
  }
}

/// Ports opLifecycle/definitions.ts: serialized messages and their original UTF-16 size.
public struct OutboundBatch {
  public var messages: [JSONValue]
  public var contentSizeInBytes: Int
  public var referenceSequenceNumber: Int
}
