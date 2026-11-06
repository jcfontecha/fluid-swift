import Foundation
import FluidJS
import FluidLZ4

func object(_ entries: [(JSString, JSONValue?)]) -> JSONValue {
    var value = JSObject<JSONValue>()
    for (key, entry) in entries { value[key] = entry }
    return .object(value)
}
func string(_ value: String) -> JSONValue { .string(JSString(value)) }
func number(_ value: Int) -> JSONValue { .number(Double(value)) }
func field(_ value: JSONValue, _ key: JSString) throws -> JSONValue? { try value.asObject()[key] }
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw JSONDecodingError(message) }
}

public struct LocalBatchMessage {
    public var runtimeOp: JSONValue
    public var metadata: JSONValue?
    public var localOpMetadata: JSONValue?
    public var referenceSequenceNumber: Int
    public var staged: Bool
    public init(runtimeOp: JSONValue, referenceSequenceNumber: Int, metadata: JSONValue? = nil,
                localOpMetadata: JSONValue? = nil, staged: Bool = false) {
        self.runtimeOp = runtimeOp; self.referenceSequenceNumber = referenceSequenceNumber
        self.metadata = metadata; self.localOpMetadata = localOpMetadata; self.staged = staged
    }
}

/// Owned by the container executor. Checkpoints roll back the suffix in LIFO order.
public final class BatchManager {
    public private(set) var messages: [LocalBatchMessage] = []
    public private(set) var clientSequenceNumber: Int?
    public private(set) var hasReentrantOps = false
    public init() {}
    public var referenceSequenceNumber: Int? { messages.last?.referenceSequenceNumber }
    public func push(_ message: LocalBatchMessage, reentrant: Bool = false, clientSequenceNumber: Int? = nil) {
        if messages.isEmpty { self.clientSequenceNumber = clientSequenceNumber }
        hasReentrantOps = hasReentrantOps || reentrant; messages.append(message)
    }
    public func pop() throws -> [LocalBatchMessage] {
        try require(!messages.isEmpty, "expected non-empty batch")
        let result = messages
        messages.removeAll(keepingCapacity: true); clientSequenceNumber = nil; hasReentrantOps = false
        return result
    }
    public func rollback(to count: Int, process: (LocalBatchMessage) throws -> Void) throws {
        try require(count >= 0 && count <= messages.count, "invalid checkpoint")
        let suffix = Array(messages[count...]); messages.removeSubrange(count...)
        for message in suffix.reversed() { try process(message) }
        try require(messages.count == count, "ops generated during rollback")
    }
}

public struct OpLifecycleOptions: Sendable {
    public var grouped: Bool
    public var compressionThreshold: Int
    public var chunkSize: Int
    public var maximumBatchSize: Int
    public init(grouped: Bool = true, compressionThreshold: Int = 614400,
                chunkSize: Int = 204800, maximumBatchSize: Int = 1048576) {
        self.grouped = grouped; self.compressionThreshold = compressionThreshold
        self.chunkSize = chunkSize; self.maximumBatchSize = maximumBatchSize
    }
}

/// Synchronous transport transformations. No tasks or locks on the op path.
public enum OpLifecycle {
    public static func batchId(clientId: String, startCSN: Int) -> String { "\(clientId)_[\(startCSN)]" }

    public static func encode(_ input: [LocalBatchMessage], options: OpLifecycleOptions,
                              batchId: String? = nil, referenceSequenceNumber: Int = 0) throws -> [[JSONValue]] {
        try require(options.chunkSize > 0 && options.chunkSize < options.maximumBatchSize, "invalid chunk size")
        if input.isEmpty {
            guard let batchId else { return [] }
            try require(options.grouped, "empty replay requires grouping")
            return [[object([("contents", string(#"{"type":"groupedBatch","contents":[]}"#)),
                             ("metadata", object([("batchId", string(batchId)), ("groupedOpCount", number(0))])),
                             ("referenceSequenceNumber", number(referenceSequenceNumber))])]]
        }
        let messages = try stamp(input, batchId: batchId)
        let ref = messages[0].referenceSequenceNumber
        var size = 0
        var wire = messages.map { m in
            let text = JSON.stringify(m.runtimeOp); size += text.utf16.count
            return object([("contents", string(text)), ("metadata", m.metadata),
                           ("referenceSequenceNumber", number(m.referenceSequenceNumber))])
        }
        if options.grouped && messages.count > 1 {
            for message in messages {
                if let metadata = message.metadata {
                    try require(try metadata.asObject().keys.allSatisfy { $0 == "batch" || $0 == "batchId" }, "cannot group custom metadata")
                }
            }
            let contents = object([("type", string("groupedBatch")), ("contents", .array(messages.map {
                object([("contents", $0.runtimeOp), ("metadata", $0.metadata)])
            }))])
            wire = [object([("contents", string(JSON.stringify(contents))),
                            ("metadata", object([("batchId", batchId.map(string)), ("groupedOpCount", number(messages.count))])),
                            ("referenceSequenceNumber", number(ref))])]
        }
        if wire.count == 1 && size >= options.compressionThreshold {
            var message = try wire[0].asObject()
            let text = try wire[0].member("contents").asString().description
            let packed = Data(try FluidLZ4.compress(Array("[\(text)]".utf8))).base64EncodedString()
            message["contents"] = string(JSON.stringify(object([("packedContents", string(packed))])))
            message["compression"] = string("lz4")
            size = packed.count; wire = [.object(message)]
            if size > options.chunkSize {
                let chunks = try split(.object(message), chunkSize: options.chunkSize, extraOp: size + 200 >= options.maximumBatchSize)
                return chunks.map { [$0] }
            }
        }
        try require(size + 200 * wire.count < options.maximumBatchSize, "BatchTooLarge")
        return [wire]
    }

    public static func stamp(_ input: [LocalBatchMessage], batchId: String? = nil) throws -> [LocalBatchMessage] {
        guard !input.isEmpty else { return [] }
        var messages = input
        if messages.count > 1 {
            var first = try messages[0].metadata?.asObject() ?? JSObject()
            first["batch"] = .bool(true); messages[0].metadata = .object(first)
            var last = try messages[messages.count - 1].metadata?.asObject() ?? JSObject()
            last["batch"] = .bool(false); messages[messages.count - 1].metadata = .object(last)
        }
        if let batchId {
            var meta = try messages[0].metadata?.asObject() ?? JSObject()
            meta["batchId"] = string(batchId); messages[0].metadata = .object(meta)
        }
        return messages
    }

    public static func split(_ message: JSONValue, chunkSize: Int, extraOp: Bool = false) throws -> [JSONValue] {
        try require(chunkSize > 0, "invalid chunk size")
        let text = try message.member("contents").asString().utf16
        let count = (text.count + chunkSize - 1) / chunkSize + (extraOp ? 1 : 0)
        let meta = try field(message, "metadata")
        var result: [JSONValue] = []; result.reserveCapacity(count)
        for i in 0..<count {
            let start = min(i * chunkSize, text.count), end = min((i + 1) * chunkSize, text.count)
            let final = i == count - 1
            let chunk = object([("chunkId", number(i + 1)), ("contents", .string(JSString(utf16: ContiguousArray(text[start..<end])))),
                                ("totalChunks", number(count)), ("originalMetadata", final ? meta : nil),
                                ("originalCompression", final ? try field(message, "compression") : nil),
                                ("originalType", final ? string("component") : nil)])
            result.append(object([("contents", string(JSON.stringify(object([("type", string("chunkedOp")), ("contents", chunk)])))),
                                  ("metadata", final ? object([("batch", try meta.flatMap { try field($0, "batch") }),
                                                               ("groupedOpCount", try meta.flatMap { try field($0, "groupedOpCount") })]) : nil),
                                  ("referenceSequenceNumber", try message.member("referenceSequenceNumber"))]))
        }
        return result
    }
}

public final class RemoteMessageProcessor {
    private final class ChunkBuffer { var parts: [JSString] = [] }
    private var chunks = JSObject<ChunkBuffer>()
    public var partialMessages: JSObject<[JSString]> {
        var snapshot = JSObject<[JSString]>()
        for (key, buffer) in chunks.entries { snapshot[key] = buffer.parts }
        return snapshot
    }
    private var batchInProgress = false
    private var decompressed: [JSONValue] = []
    private var decompressedIndex = 0
    public init() {}
    public func clearPartialMessages(for client: JSString) { chunks[client] = nil }
    public func process(_ input: JSONValue) throws -> JSONValue? {
        var message = try input.asObject()
        let client = try input.member("clientId").asString()
        if case .string(let text) = message["contents"], !text.utf16.isEmpty { message["contents"] = try JSON.parse(text.description) }
        if let contents = message["contents"], case .object(let envelope) = contents, envelope["type"] == string("chunkedOp") {
            let chunk = try contents.member("contents")
            let id = try chunk.member("chunkId").asInt(), total = try chunk.member("totalChunks").asInt()
            let buffer = chunks[client] ?? ChunkBuffer()
            chunks[client] = buffer
            try require(id == buffer.parts.count + 1, "Chunk Id mismatch")
            buffer.parts.append(try chunk.member("contents").asString())
            if id < total { return nil }
            let joined = JSString(utf16: ContiguousArray(buffer.parts.flatMap(\.utf16)))
            chunks[client] = nil
            message["contents"] = joined.length == 0 ? nil : try JSON.parse(joined.description)
            message["type"] = try field(chunk, "originalType")
            message["metadata"] = try field(chunk, "originalMetadata")
            message["compression"] = try field(chunk, "originalCompression")
        }
        let meta = try message["metadata"]?.asObject()
        let marker = meta?["batch"]
        var packed: String?
        if let contents = message["contents"], case .object(let obj) = contents,
           case .string(let text) = obj["packedContents"] {
            let s = text.description
            if message["compression"] == string("lz4") || (obj.count == 1 && !s.isEmpty && Data(base64Encoded: s)?.base64EncodedString() == s) { packed = s }
        }
        try require(message["compression"] != string("lz4") || packed != nil, "missing packedContents")
        if let packed {
            try require(decompressed.isEmpty, "multiple compressed batches")
            try require(message["compression"] == nil || message["compression"] == string("lz4"), "unsupported compression")
            guard let bytes = Data(base64Encoded: packed) else { throw JSONDecodingError("invalid base64") }
            decompressed = try JSON.parse(String(decoding: FluidLZ4.decompress(Array(bytes)), as: UTF8.self)).asArray()
            decompressedIndex = 0
            try require(marker == nil || marker == .bool(true), "invalid compressed marker")
        }
        if !decompressed.isEmpty {
            try require(decompressedIndex < decompressed.count, "compressed array overrun")
            if packed == nil && marker == nil { try require(message["contents"] == nil, "expected empty continuation") }
            message["contents"] = decompressed[decompressedIndex]; message["compression"] = nil
            decompressedIndex += 1
            if marker == .bool(false) || (packed != nil && marker == nil) { decompressed.removeAll(keepingCapacity: true); decompressedIndex = 0 }
            if try message["contents"].map({ try field($0, "type") }) != string("groupedBatch") { try unpack(&message) }
        }
        if let contents = message["contents"], case .object(let obj) = contents, obj["type"] == string("groupedBatch") {
            try require(!batchInProgress, "group interrupts batch")
            let inner = try contents.member("contents").asArray()
            let messages = try inner.enumerated().map { index, entry -> JSONValue in
                var m = message
                m["clientSequenceNumber"] = number(index + 1)
                m["contents"] = try field(entry, "contents"); m["metadata"] = try field(entry, "metadata"); m["compression"] = try field(entry, "compression")
                try unpack(&m); return .object(m)
            }
            return object([("type", string("fullBatch")), ("messages", .array(messages)),
                           ("batchStart", batchStart(message, key: messages.first ?? .object(message))),
                           ("length", number(messages.count)), ("groupedBatch", .bool(true))])
        }
        if message["type"] == string("op") { try unpack(&message) }
        let value = JSONValue.object(message)
        if !batchInProgress {
            try require(marker != .bool(false), "unexpected batch end")
            if marker == .bool(true) {
                batchInProgress = true
                return object([("type", string("batchStartingMessage")), ("batchStart", batchStart(message, key: value)), ("nextMessage", value)])
            }
            return object([("type", string("fullBatch")), ("messages", .array([value])),
                           ("batchStart", batchStart(message, key: value)), ("length", number(1)), ("groupedBatch", .bool(false))])
        }
        try require(marker != .bool(true), "unexpected batch start")
        if marker == .bool(false) { batchInProgress = false }
        return object([("type", string("nextBatchMessage")), ("nextMessage", value), ("batchEnd", .bool(marker == .bool(false)))])
    }
    private func unpack(_ message: inout JSObject<JSONValue>) throws {
        guard let contents = message["contents"] else { throw JSONDecodingError("missing runtime envelope") }
        let envelope = try contents.asObject()
        if envelope["address"] != nil && envelope["type"] == nil { message["type"] = string("component"); return }
        message["type"] = envelope["type"]; message["contents"] = envelope["contents"]
    }
    private func batchStart(_ message: JSObject<JSONValue>, key: JSONValue) -> JSONValue {
        var id: JSONValue?
        if case .object(let metadata) = message["metadata"] { id = metadata["batchId"] }
        return object([("batchStartCsn", message["clientSequenceNumber"]), ("clientId", message["clientId"]), ("batchId", id), ("keyMessage", key)])
    }
}
