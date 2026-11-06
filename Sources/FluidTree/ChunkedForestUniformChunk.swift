import FluidJS

/// Ports feature-libraries/chunked-forest/uniformChunk.ts. Shared topology, contiguous values.
public final class TreeShape {
    public let type: JSString
    public let hasValue: Bool
    public let fieldsArray: [FieldShape]
    public init(type: JSString, hasValue: Bool, fieldsArray: [FieldShape]) {
        self.type = type
        self.hasValue = hasValue
        self.fieldsArray = fieldsArray
    }
    var valueCount: Int { (hasValue ? 1 : 0) + fieldsArray.reduce(0) { $0 + $1.length * $1.shape.valueCount } }
}
public struct FieldShape {
    public let key: JSString
    public let shape: TreeShape
    public let length: Int
    public init(key: JSString, shape: TreeShape, length: Int) throws {
        try forestCheck(length >= 0, "negative field length")
        self.key = key
        self.shape = shape
        self.length = length
    }
}
public struct ChunkShape {
    public let treeShape: TreeShape
    public let topLevelLength: Int
    public init(treeShape: TreeShape, topLevelLength: Int) throws {
        try forestCheck(topLevelLength > 0, "uniform chunks must be nonempty")
        self.treeShape = treeShape
        self.topLevelLength = topLevelLength
    }
}
public final class UniformChunk: TreeChunk {
    public let shape: ChunkShape
    public let values: ContiguousArray<JSONValue>
    private var references = 1
    public var topLevelLength: Int { shape.topLevelLength }
    public init(shape: ChunkShape, values: ContiguousArray<JSONValue>) throws {
        try forestCheck(values.count == shape.treeShape.valueCount * shape.topLevelLength, "uniform value count")
        self.shape = shape
        self.values = values
    }
    public func referenceAdded() { references += 1 }
    public func referenceRemoved() { references -= 1 }
    public func isShared() -> Bool { references > 1 }
    public func materialize() throws -> BasicChunk {
        var offset = 0
        func node(_ shape: TreeShape) -> JSONValue {
            var entries: [(JSString, JSONValue)] = [("type", .string(shape.type))]
            if shape.hasValue {
                entries.append(("value", values[offset]))
                offset += 1
            }
            entries.append(("fields", .array(shape.fieldsArray.filter { $0.length > 0 }.map { field in
                .array([.string(field.key), .array((0..<field.length).map { _ in node(field.shape) })])
            })))
            return forestObject(entries)
        }
        return try BasicChunk(json: .array((0..<topLevelLength).map { _ in node(shape.treeShape) }))
    }
}
/// Ports feature-libraries/chunked-forest/sequenceChunk.ts. Aggregates chunks, never nodes.
public final class SequenceChunk: TreeChunk {
    public let subChunks: [any TreeChunk]
    private var references = 1
    public var topLevelLength: Int { subChunks.reduce(0) { $0 + $1.topLevelLength } }
    public init(subChunks: [any TreeChunk]) { self.subChunks = subChunks }
    public func referenceAdded() { references += 1 }
    public func referenceRemoved() {
        references -= 1
        if references == 0 { for chunk in subChunks { chunk.referenceRemoved() } }
    }
    public func isShared() -> Bool { references > 1 }
}
