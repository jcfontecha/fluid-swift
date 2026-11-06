import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports routerlicious-driver/src/deltaStorageService.ts. from is inclusive, to exclusive.
public struct DeltaStorageService: Sendable {
    private let rest: RestClient
    public init(endpoint: String, document: String, tokens: any ITokenProvider) {
        rest = RestClient(endpoint: endpoint, document: document, tokens: tokens)
    }
    private var document: String { rest.document }
    public func fetchMessages(from: Int, to: Int, reason: String = "") async throws
        -> [ISequencedDocumentMessage]
    {
        try await rest.get(
            "/deltas/tinylicious/\(encodeURIComponent(document))?from=\(from - 1)&to=\(to)&fetchReason=\(encodeURIComponent(reason))",
            storage: false
        ).asArray().map { try ISequencedDocumentMessage(json: $0) }
    }
}
