import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports routerlicious-driver/src/documentService.ts: service connection ownership.
public struct DocumentService: Sendable {
    public let storage: DocumentStorageService
    public let deltaStorage: DeltaStorageService

    public init(endpoint: String, document: String, tokens: any ITokenProvider) {
        storage = DocumentStorageService(endpoint: endpoint, document: document, tokens: tokens)
        deltaStorage = DeltaStorageService(endpoint: endpoint, document: document, tokens: tokens)
    }

    public func connectToDeltaStream(_ connection: DocumentDeltaConnection, summarizer: Bool = false) async throws
        -> IConnected
    {
        guard let url = URL(string: storage.endpoint) else {
            throw JSONDecodingError("invalid endpoint")
        }
        let token = try await storage.tokens.fetchOrdererToken(
            tenantId: "tinylicious", documentId: storage.document, refresh: false)
        let client = try IClient(
            json: JSON.parse(summarizer ?
                #"{"mode":"write","details":{"capabilities":{"interactive":false},"type":"summarizer"},"permission":[],"scopes":[],"user":{"id":""}}"# :
                #"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":{"id":""}}"#
            ))
        let request = try R11sDocumentDeltaConnection.message(
            document: storage.document, token: token.jwt, client: client)
        return try await connection.connect(url: url, message: request)
    }
}
