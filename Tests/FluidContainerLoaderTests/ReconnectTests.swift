import FluidContainerDefinitions
import FluidDriverDefinitions
import FluidDriverUtils
import FluidJS
import Testing
@testable import FluidContainerLoader

struct ReconnectTests {
    // connectionManager.ts getNackReconnectInfo: 400 is NOT fatal; only 403 is.
    @Test(arguments: [400, 401, 403, 404, 429, 500, 503])
    func nackClassification(code: Int) throws {
        let nack = try INackContent(json: JSON.parse("{\"code\":\(code),\"type\":\"BadRequestError\",\"message\":\"failure\",\"retryAfter\":2.5}"))
        let error = getNackReconnectInfo(nack)
        #expect(canRetryOnError(error) == (code != 403))
        #expect(getRetryDelayFromError(error) == 2500)
    }

    @Test func reconnectModes() throws {
        let manager = ConnectionManager(reconnectAllowed: false)
        #expect(manager.reconnectMode == .never)
        #expect(throws: (any Error).self) { try manager.setAutoReconnect(.enabled) }
        let enabled = ConnectionManager()
        try enabled.setAutoReconnect(.disabled)
        #expect(enabled.reconnectMode == .disabled)
        try enabled.setAutoReconnect(.enabled)
        #expect(enabled.reconnectMode == .enabled)
    }
}

private func details(_ clientId: String, mode: String = "write", checkpoint: Int = 0) throws -> IConnected {
    try IConnected(json: JSON.parse("""
    {"claims":{"documentId":"doc","scopes":["doc:read","doc:write"],"tenantId":"fake","user":{"id":"u"},"iat":0,"exp":0,"ver":"1.0"},"clientId":"\(clientId)","existing":true,"maxMessageSize":16384,"initialMessages":[],"initialSignals":[],"initialClients":[],"version":"^0.4.0","supportedVersions":[],"serviceConfiguration":{"maxMessageSize":16384,"blockSize":65436},"mode":"\(mode)","checkpointSequenceNumber":\(checkpoint)}
    """))
}

private func systemOp(_ type: String, data: String, sequence: Int) throws -> ISequencedDocumentMessage {
    var fields = try JSON.parse(#"{"clientId":null,"clientSequenceNumber":-1,"referenceSequenceNumber":-1,"contents":null,"minimumSequenceNumber":0,"timestamp":0}"#).asObject()
    fields["type"] = .string(JSString(type))
    fields["data"] = .string(JSString(data))
    fields["sequenceNumber"] = .number(Double(sequence))
    return try ISequencedDocumentMessage(json: .object(fields))
}

struct ConnectionStateHandlerTests {
    @Test func oldLeaveAndCheckpointBothGateNewJoin() throws {
        let handler = ConnectionStateHandler()
        handler.receivedConnectEvent(try details("old"), sequenceNumber: 0)
        try handler.receivedMessage(systemOp("join", data: #"{"clientId":"old","detail":{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":{"id":""}}}"#, sequence: 1), hasPendingOps: false)
        #expect(handler.connected)
        handler.receivedDisconnectEvent(hasPendingOps: true, currentClientInQuorum: true)
        handler.receivedConnectEvent(try details("new", checkpoint: 4), sequenceNumber: 1)
        try handler.receivedMessage(systemOp("join", data: #"{"clientId":"new","detail":{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":{"id":""}}}"#, sequence: 2), hasPendingOps: true)
        #expect(!handler.connected)
        #expect(handler.clientId == "old")
        try handler.receivedMessage(systemOp("leave", data: #""old""#, sequence: 3), hasPendingOps: true)
        #expect(!handler.connected)
        try handler.receivedMessage(systemOp("noop", data: "null", sequence: 4), hasPendingOps: true)
        #expect(handler.connected)
        #expect(handler.clientId == "new")
    }

    @Test func readConnectionWaitsForOwnSignal() throws {
        let handler = ConnectionStateHandler()
        handler.receivedConnectEvent(try details("reader", mode: "read"), sequenceNumber: 0)
        #expect(!handler.connected)
        handler.receivedReadJoin("other")
        #expect(!handler.connected)
        handler.receivedReadJoin("reader")
        #expect(handler.connected)
    }
}

private actor FailedConnectionService: IDocumentService {
    nonisolated let resolvedUrl: IResolvedUrl
    nonisolated let policies: IDocumentServicePolicies? = nil
    private(set) var attempts = 0

    init() throws {
        resolvedUrl = try IResolvedUrl(json: JSON.parse(#"{"type":"fluid","id":"doc","url":"https://fake/tenant/doc","tokens":{},"endpoints":{}}"#))
    }

    func connectToDeltaStream(_ client: IClient) async throws -> any IDocumentDeltaConnection {
        attempts += 1
        if attempts <= 5 { throw NetworkError("offline", canRetry: true) }
        throw NetworkError("forbidden", canRetry: false)
    }

    nonisolated func dispose(_ error: (any Error)?) {}
    func connectToStorage() async throws -> any IDocumentStorageService { throw JSONDecodingError("unused") }
    func connectToDeltaStorage() async throws -> any IDocumentDeltaStorageService { throw JSONDecodingError("unused") }
}

private actor DelayJournal {
    var delays: [Double] = []
    func sleep(_ delay: Double) { delays.append(delay) }
}

struct ConnectionAttemptTests {
    @Test func failedConnectUsesVirtualExponentialBackoff() async throws {
        let journal = DelayJournal()
        let manager = ConnectionManager(sleep: { await journal.sleep($0) })
        let service = try FailedConnectionService()
        let client = try IClient(json: JSON.parse(#"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":{"id":""}}"#))
        let attempt = try #require(manager.beginConnection())
        await #expect(throws: (any Error).self) { try await manager.connect(service, client: client, attempt: attempt) }
        #expect(await service.attempts == 6)
        #expect(await journal.delays == [1000, 2000, 4000, 8000, 8000])
    }

    @Test func disabledReconnectDoesNotRetryFailedConnect() async throws {
        let manager = ConnectionManager(sleep: { _ in Issue.record("unexpected retry") })
        try manager.setAutoReconnect(.disabled)
        let service = try FailedConnectionService()
        let client = try IClient(json: JSON.parse(#"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":{"id":""}}"#))
        let attempt = try #require(manager.beginConnection())
        let connection = try await manager.connect(service, client: client, attempt: attempt)
        #expect(connection == nil)
        #expect(await service.attempts == 1)
    }
}
