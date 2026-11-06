import FluidRouterliciousDriver
import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation
import Synchronization

func obj(_ entries: [(JSString, JSONValue)]) -> JSONValue {
    var result = JSObject<JSONValue>()
    for (key, value) in entries { result[key] = value }
    return .object(result)
}
final class Tokens: ITokenProvider {
    let callbackEnabled: Bool
    init(callbackEnabled: Bool) { self.callbackEnabled = callbackEnabled }
    var documentPostCreateCallback: (@Sendable (String, String) async throws -> Void)? {
        guard callbackEnabled else { return nil }
        return { [self] id, token in
            log.withLock { $0.append(.array([.string("callback"), .string(JSString(id)), .string(JSString(token))])) }
        }
    }
    let log = Mutex<[JSONValue]>([])
    func fetchOrdererToken(tenantId: String, documentId: String?, refresh: Bool) async throws -> ITokenResponse {
        log.withLock { $0.append(.array([.string("orderer"), .string(JSString(tenantId)), documentId.map { .string(JSString($0)) } ?? .null, .bool(refresh)])) }
        return ITokenResponse(jwt: refresh ? "refreshed" : "token", fromCache: false)
    }
    func fetchStorageToken(tenantId: String, documentId: String, refresh: Bool) async throws -> ITokenResponse {
        log.withLock { $0.append(.array([.string("storage"), .string(JSString(tenantId)), .string(JSString(documentId)), .bool(refresh)])) }
        return ITokenResponse(jwt: refresh ? "refreshed" : "token", fromCache: false)
    }
}
while let line = readLine() {
    let input = try JSON.parse(line)
    let tokens = Tokens(callbackEnabled: try input.asObject()["callback"] == .bool(true))
    var steps: [JSONValue] = []
    var connection: (any IDocumentDeltaConnection)?
    do {
        let resolved = try IResolvedUrl(json: input.member("resolved"))
        let factory = RouterliciousDocumentServiceFactory(tokenProvider: tokens, driverPolicies: IRouterliciousDriverPolicies(enableDiscovery: true, enableWholeSummaryUpload: true))
        let service: any IDocumentService
        if try input.member("create") == .bool(true) {
            service = try await factory.createContainer(SummaryTree(json: input.member("summary")), resolvedUrl: resolved, clientIsSummarizer: false)
        } else { service = try await factory.createDocumentService(resolved, clientIsSummarizer: false) }
        steps.append(.array([.string("resolved"), service.resolvedUrl.json]))
        let storage = try await service.connectToStorage()
        let versions = try await storage.getVersions(nil, count: 1, scenarioName: nil, fetchSource: nil)
        steps.append(.array([.string("versions"), .array(versions.map(\.json))]))
        let tree = try await storage.getSnapshotTree(versions.first, scenarioName: nil)
        steps.append(.array([.string("tree"), tree!.json]))
        let blob = try await storage.readBlob("blob")
        steps.append(.array([.string("blob"), .string(JSString(Data(blob).base64EncodedString()))]))
        let deltas = try await service.connectToDeltaStorage()
        var messages: [JSONValue] = []
        for try await batch in deltas.fetchMessages(1, to: 3, cachedOnly: false, fetchReason: nil) { messages += batch.map(\.json) }
        steps.append(.array([.string("deltas"), .array(messages)]))
        let client = try IClient(json: input.member("client"))
        let connected = try await service.connectToDeltaStream(client)
        connection = connected
        steps.append(.array([.string("connected"), .string(connected.details.clientId)]))
        connected.submit([try IDocumentMessage(json: input.member("message"))])
        // Observe the echo to prove the synchronous writer actually delivered the submission.
        for try await event in connected.events {
            if case .op = event { break }
        }
        let handle = try await storage.uploadSummaryWithContext(SummaryTree(json: input.member("upload")), context: ISummaryContext(json: input.member("context")))
        steps.append(.array([.string("uploaded"), .string(handle)]))
    } catch {
        if let error = error as? DriverError {
            steps.append(.array([.string("error"), obj([("errorType", .string(JSString(error.errorType))), ("canRetry", .bool(error.canRetry)), ("statusCode", error.statusCode.map { .number(Double($0)) } ?? .null)])]))
        } else { steps.append(.array([.string("error"), .string(JSString(String(describing: error)))])) }
    }
    if let connection { await connection.dispose() }
    let output = JSON.stringify(obj([("steps", .array(steps)), ("tokens", .array(tokens.log.withLock { $0 }))]))
    FileHandle.standardOutput.write(Data((output + "\n").utf8))
}
