import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation
import Synchronization

/// deltaStorageService.ts MaxBatchDeltas.
private let maxBatchDeltas = 2000

func deltasFetchResult(_ messages: [ISequencedDocumentMessage], partialResult: Bool) throws -> IDeltasFetchResult {
    var object = JSObject<JSONValue>()
    object["messages"] = .array(messages.map(\.json))
    object["partialResult"] = .bool(partialResult)
    return try IDeltasFetchResult(json: .object(object))
}

/// Ports deltaStorageService.ts DeltaStorageService: one REST read of [from, to) from the
/// orderer's delta storage URL. The service's `from` is exclusive, hence `from - 1`.
final class DeltaStorageService: Sendable {
    private let url: String
    private let rest: RestClient

    init(url: String, rest: RestClient) {
        self.url = url
        self.rest = rest
    }

    /// The server is assumed to return every op it has in the range, so the result is never partial.
    func get(from: Int, to: Int, fetchReason: String?) async throws -> IDeltasFetchResult {
        let query = "?from=\(from - 1)&to=\(to)&fetchReason=\(encodeURIComponent(fetchReason ?? ""))"
        let messages = try await rest.get(url + query).asArray().map { try ISequencedDocumentMessage(json: $0) }
        return try deltasFetchResult(messages, partialResult: false)
    }
}

/// Ports deltaStorageService.ts DocumentDeltaStorageService: ops in batches of 2000. The first
/// request may be served from the snapshot's `.logTail` ops when they start at `from`.
public final class DocumentDeltaStorageService: IDocumentDeltaStorageService {
    private let deltaStorageService: DeltaStorageService
    private let documentStorageService: DocumentStorageService
    private let logtailSha: Mutex<JSString?>

    init(deltaStorageService: DeltaStorageService, documentStorageService: DocumentStorageService) {
        self.deltaStorageService = deltaStorageService
        self.documentStorageService = documentStorageService
        logtailSha = Mutex(documentStorageService.logTailSha)
    }

    public func fetchMessages(_ from: Int, to: Int?, cachedOnly: Bool, fetchReason: String?)
        -> AsyncThrowingStream<[ISequencedDocumentMessage], any Error>
    {
        if cachedOnly {
            return AsyncThrowingStream { $0.finish() }
        }
        return requestOps({ from, to in
            let result = try await self.requestCallback(from: from, to: to, fetchReason: fetchReason)
            var messages = result.messages
            validateMessages("catch all", &messages, from: from)
            return try deltasFetchResult(messages, partialResult: result.partialResult)
        }, fromTotal: from, toTotal: to, payloadSize: maxBatchDeltas)
    }

    /// TS rereads `snapshotOps` on every request, from the log tail only while its sha is unread,
    /// so only the first request can be served from it.
    private func requestCallback(from: Int, to: Int, fetchReason: String?) async throws -> IDeltasFetchResult {
        let sha = logtailSha.withLock { sha in
            let current = sha
            sha = nil
            return current
        }
        var snapshotOps: [ISequencedDocumentMessage] = []
        if let sha {
            let text = String(decoding: try await documentStorageService.readBlob(sha), as: UTF8.self)
            snapshotOps = try JSON.parse(text).asArray().map { try ISequencedDocumentMessage(json: $0) }
        }
        if !snapshotOps.isEmpty {
            var messages = snapshotOps.filter { $0.sequenceNumber >= from && $0.sequenceNumber < to }
            validateMessages("snapshotOps", &messages, from: from, strict: false)
            if let first = messages.first, first.sequenceNumber == from {
                return try deltasFetchResult(messages, partialResult: true)
            }
        }
        let ops = try await deltaStorageService.get(from: from, to: to, fetchReason: fetchReason)
        var messages = ops.messages
        validateMessages("storage", &messages, from: from, strict: false)
        return try deltasFetchResult(messages, partialResult: ops.partialResult)
    }
}
