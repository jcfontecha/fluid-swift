import FluidJS
import FluidMergeTree
import FluidDriverDefinitions

public struct SequenceOperationArgs {
  public let operation: JSONValue
  public let sequencedMessage: SequencedMessage?
  public let rollback: Bool
}

public struct SequenceDeltaArgs {
  public let operation: Int
  public let deltaSegments: [MergeTreeDeltaSegment]
}

/// Ports sequenceDeltaEvent.ts SequenceEventClass; sorted ranges resolve once on first access.
open class SequenceEventClass {
  public struct Range {
    public let operation: Int
    public let position: Int
    public let segment: BaseSegment
    public let propertyDeltas: JSObject<JSONValue>
  }
  private let client: Client
  public let opArgs: SequenceOperationArgs?
  public let deltaArgs: SequenceDeltaArgs
  public let deltaOperation: Int
  public let isLocal: Bool
  public var clientId: JSString { client.id }
  public lazy var ranges: [Range] = {
    var unique: [ObjectIdentifier: MergeTreeDeltaSegment] = [:]
    for delta in deltaArgs.deltaSegments { unique[ObjectIdentifier(delta.segment)] = delta }
    return unique.values.sorted { compareSegmentPositions($0.segment, $1.segment) < 0 }.map {
      Range(operation: deltaOperation, position: client.getPosition($0.segment), segment: $0.segment, propertyDeltas: $0.propertyDeltas)
    }
  }()
  public lazy var first: Range? = ranges.first
  public lazy var last: Range? = ranges.last

  init(client: Client, operation: Int, segments: [MergeTreeDeltaSegment], local: Bool, opArgs: SequenceOperationArgs? = nil) {
    self.client = client
    self.deltaOperation = operation
    self.deltaArgs = SequenceDeltaArgs(operation: operation, deltaSegments: segments)
    self.isLocal = local
    self.opArgs = opArgs
  }
}

/// Ports sequenceDeltaEvent.ts SequenceMaintenanceEventClass.
public final class SequenceMaintenanceEvent: SequenceEventClass {}
