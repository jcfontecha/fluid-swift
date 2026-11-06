import FluidJS
import FluidMergeTree

public enum IntervalSerializationFormat { case v1, v2 }

/// Ports intervalCollectionMap.ts IntervalCollectionMap: lazy ordered collections and summary envelopes.
public final class IntervalCollectionMap {
  private let client: Client
  public var intervalStickinessEnabled = false {
    didSet { for collection in collections.values { collection.intervalStickinessEnabled = intervalStickinessEnabled } }
  }
  public var canSlideToEndpoint = false {
    didSet { for collection in collections.values { collection.canSlideToEndpoint = canSlideToEndpoint } }
  }
  private var collections: [JSString: IntervalCollection] = [:]
  public private(set) var labels: [JSString] = []
  public var created: ((IntervalCollection) -> Void)?
  public var count: Int { labels.count }

  public init(client: Client) { self.client = client }

  public func get(_ label: JSString) -> IntervalCollection {
    if let collection = collections[label] { return collection }
    let collection = IntervalCollection(client: client, label: label)
    collection.intervalStickinessEnabled = intervalStickinessEnabled
    collection.canSlideToEndpoint = canSlideToEndpoint
    collections[label] = collection
    labels.append(label)
    created?(collection)
    return collection
  }

  public func serialize(version: IntervalSerializationFormat = .v2) -> JSONValue {
    var result = JSObject<JSONValue>()
    for label in labels {
      guard let collection = collections[label] else { continue }
      result[label] = sequenceObject([
        ("type", .string("sharedStringIntervalCollection")),
        ("value", collection.serialize(version: version)),
      ])
    }
    return .object(result)
  }

  public func populate(_ serialized: JSONValue) throws {
    for (key, entry) in try serialized.asObject().entries {
      let type = try entry.member("type").asString()
      if type == "Plain" || type == "Shared" { continue }
      guard type == "sharedStringIntervalCollection" else { throw JSONDecodingError("unknown interval collection type") }
      let prefix = JSString("intervalCollections/")
      let label = key.utf16.starts(with: prefix.utf16)
        ? JSString(utf16: ContiguousArray(key.utf16.dropFirst(prefix.length))) : key
      let value = try entry.member("value")
      let intervals: [JSONValue]
      let compressed: Bool
      if case .array(let values) = value {
        intervals = values
        compressed = false
      } else {
        guard try value.member("version").asInt() == 2 else { throw JSONDecodingError("unsupported interval summary version") }
        intervals = try value.member("intervals").asArray()
        compressed = true
      }
      let collection = get(label)
      for interval in intervals {
        let start: SequencePlace
        let end: SequencePlace
        let properties: JSObject<JSONValue>
        let intervalType: IntervalType
        if compressed {
          let fields = try interval.asArray()
          guard fields.count >= 5, fields.count <= 6 else { throw JSONDecodingError("invalid compressed interval") }
          let stickiness = try fields.count == 6 ? fields[5].asInt() : 2
          guard (0...3).contains(stickiness) else { throw JSONDecodingError("invalid interval stickiness") }
          start = try decodeSequencePlace(fields[0], side: .number(stickiness & 1 == 0 ? 0 : 1))
          end = try decodeSequencePlace(fields[1], side: .number(stickiness & 2 == 0 ? 1 : 0))
          _ = try fields[2].asInt()
          guard let type = try IntervalType(rawValue: fields[3].asInt()) else { throw JSONDecodingError("unsupported interval type") }
          intervalType = type
          properties = try fields[4].asObject()
        } else {
          start = try decodeSequencePlace(interval.member("start"), side: interval.asObject()["startSide"])
          end = try decodeSequencePlace(interval.member("end"), side: interval.asObject()["endSide"])
          properties = try interval.asObject()["properties"].map { try $0.asObject() } ?? JSObject()
          guard let type = try IntervalType(rawValue: interval.member("intervalType").asInt()) else { throw JSONDecodingError("unsupported interval type") }
          intervalType = type
        }
        let serialized = sequenceObject([("start", start.position.json), ("end", end.position.json), ("properties", .object(properties))])
        let decoded = try getSerializedProperties(serialized)
        try collection.restoreInterval(id: decoded.id, start: start, end: end, properties: decoded.properties, intervalType: intervalType)
      }
    }
  }
}
