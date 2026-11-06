import FluidDriverDefinitions
import FluidJS

// The in-memory shapes the compact snapshot codec reads and writes. They mirror `ISnapshot` and
// `ISnapshotTree` from driver-definitions, but hold blob bytes as slices of the received buffer and
// do not retain a JSON backing store, so parsing a large snapshot allocates no per-blob storage.

/// `ISnapshotTree`.
public struct CompactSnapshotTree: Equatable, Sendable {
    public var id: JSString?
    public var blobs: JSObject<JSString>
    public var trees: JSObject<CompactSnapshotTree>
    /// Only ever `true` when present (the parser asserts it).
    public var unreferenced: Bool?
    public var groupId: JSString?

    public init(
        id: JSString? = nil,
        blobs: JSObject<JSString> = JSObject(),
        trees: JSObject<CompactSnapshotTree> = JSObject(),
        unreferenced: Bool? = nil,
        groupId: JSString? = nil
    ) {
        self.id = id
        self.blobs = blobs
        self.trees = trees
        self.unreferenced = unreferenced
        self.groupId = groupId
    }
}

/// An `ISnapshot.blobContents` value. The parser only produces `buffer` (an `ArrayBuffer`); the
/// writer also accepts an `IBlob` string with its encoding, as the TS writer does.
public enum CompactSnapshotBlobContent: Equatable, Sendable {
    case buffer(ArraySlice<UInt8>)
    /// `IBlob`: `encoding` defaults to UTF-8.
    case blob(contents: JSString, encoding: BlobEncoding?)
}

/// `ISnapshot` with `snapshotFormatV: 1`.
public struct CompactSnapshot {
    public var snapshotTree: CompactSnapshotTree
    /// A `Map`: insertion order is the order blobs are written.
    public var blobContents: JSMap<JSString, CompactSnapshotBlobContent>
    /// Sequenced operations as JSON, exactly as `JSON.parse` returns them (the parser does not
    /// validate their shape, only `sequenceNumber` of the first).
    public var ops: [JSONValue]
    public var sequenceNumber: Int?
    public var latestSequenceNumber: Int?
    public let snapshotFormatV = 1

    public init(
        snapshotTree: CompactSnapshotTree,
        blobContents: JSMap<JSString, CompactSnapshotBlobContent>,
        ops: [JSONValue],
        sequenceNumber: Int?,
        latestSequenceNumber: Int? = nil
    ) {
        self.snapshotTree = snapshotTree
        self.blobContents = blobContents
        self.ops = ops
        self.sequenceNumber = sequenceNumber
        self.latestSequenceNumber = latestSequenceNumber
    }
}

/// How often the parser left its fast paths, and how long each phase took (milliseconds).
/// The TS `telemetryProps` record.
public struct SnapshotTelemetryProps: Sendable {
    public let durationStructure: Double
    public let durationStrings: Double
    public let durationSnapshotTree: Double
    public let durationBlobs: Double
    public let slowTreeStructureCount: Int
    public let slowBlobStructureCount: Int
    public let treeStructureCountWithGroupId: Int
}

/// `ISnapshotContentsWithProps`: the parsed snapshot and the telemetry of the parse.
public struct ISnapshotContentsWithProps {
    public let snapshot: CompactSnapshot
    public let telemetryProps: SnapshotTelemetryProps
}
