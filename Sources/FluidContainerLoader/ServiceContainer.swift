import Foundation
import FluidJS
import FluidSocketIO
import FluidDriverBase
import FluidRouterliciousDriver
import FluidTinyliciousDriver

public actor ServiceContainer {
    private let storage: DocumentStorageService
    private var state: ProtocolHandler?
    private var snapshotSequenceNumber = 0
    private var connection: DocumentDeltaConnection?
    private var clientID: JSONValue = .null
    private var log: [JSONValue] = []
    private var opSources: [JSONValue] = []
    private var signals: [JSONValue] = []
    private var failure: String?
    private var clientSequence = 0
    private var lastClientSequence = 0
    private var noopCountInFlight = 0
    private struct Pending { let message: JSONValue; let source: String }
    private var pending: [Pending] = []
    private var reader: Task<Void, Never>?
    private var noopTimer: Task<Void, Never>?
    private var debt = 0
    private var connected = false
    private var fetching = false
    private var noopCount = 50
    private var noopTime = 2000.0
    public init(endpoint: String, document: String) {
        storage = .init(endpoint: endpoint, document: document, tokens: InsecureTinyliciousTokenProvider())
    }
    public func connect() async throws {
        if state == nil {
            let loaded = try ProtocolHandler(snapshot: await storage.protocolSnapshot())
            snapshotSequenceNumber = loaded.sequenceNumber
            state = loaded
        }
        let connection = DocumentDeltaConnection(); self.connection = connection
        guard let url = URL(string: storage.endpoint) else { throw JSONDecodingError("invalid endpoint") }
        let token = try await storage.tokens.fetchOrdererToken(tenantId: "tinylicious", documentId: storage.document, refresh: false)
        let client = try JSON.parse(#"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":{"id":""}}"#)
        let details = try await connection.connect(url: url, message: R11sDocumentDeltaConnection.message(document: storage.document, token: token.jwt, client: client))
        clientID = try details.member("clientId"); clientSequence = 0; lastClientSequence = 0; noopCountInFlight = 0
        let config = try details.member("serviceConfiguration").asObject()
        noopCount = try config["noopCountFrequency"]?.asInt() ?? 50
        noopTime = try config["noopTimeFrequency"]?.asNumber() ?? 2000
        try state?.initialClients(details.member("initialClients").asArray())
        try enqueue(details.member("initialMessages").asArray())
        for signal in try details.member("initialSignals").asArray() { try processSignal(signal) }
        reader = Task {
            do {
                for try await event in connection.events { try await self.receive(event) }
            } catch {
                if !Task.isCancelled { self.failure = String(describing: error); self.connected = false }
            }
        }
        try await catchUp(fetchUnbounded: true)
    }
    private func receive(_ event: SocketEvent) async throws {
        switch event.name {
        case "op":
            guard event.arguments.count == 2 else { throw JSONDecodingError("invalid op arguments") }
            try enqueue(event.arguments[1].asArray()); try await catchUp()
        case "signal":
            guard let value = event.arguments.first else { throw JSONDecodingError("missing signal") }
            if case .array(let batch) = value { for signal in batch { try processSignal(signal) } } else { try processSignal(value) }
        case "nack": throw DriverError("nack", .array(event.arguments))
        default: break
        }
    }
    private func processSignal(_ signal: JSONValue) throws { signals.append(signal); try state?.signal(signal) }
    private func enqueue(_ messages: [JSONValue], source: String = "socket") throws {
        pending.append(contentsOf: messages.map { Pending(message: $0, source: source) })
        pending = try pending.sorted { try $0.message.member("sequenceNumber").asInt() < $1.message.member("sequenceNumber").asInt() }
    }
    private func drain() throws -> [String] {
        guard var state else { throw JSONDecodingError("no protocol state") }
        var outgoing: [String] = []
        while let entry = pending.first {
            let first = entry.message
            let sn = try first.member("sequenceNumber").asInt()
            if sn <= state.sequenceNumber {
                if let previous = log.last, sn == state.sequenceNumber {
                    for key: JSString in ["clientId", "type", "minimumSequenceNumber", "referenceSequenceNumber", "timestamp"] {
                        guard try first.member(key) == previous.member(key) else { throw DriverError("fileOverwrittenInStorage", first, canRetry: false) }
                    }
                }
                pending.removeFirst(); continue
            }
            if sn != state.sequenceNumber + 1 { break }
            pending.removeFirst()
            if try first.member("clientId") == clientID {
                let csn = try first.member("clientSequenceNumber").asInt()
                if try first.member("type") == .string("noop") { noopCountInFlight -= 1 }
                let gap = csn - lastClientSequence - 1
                noopCountInFlight -= gap
                guard noopCountInFlight >= 0 else { throw JSONDecodingError("gap in client sequence number: \(gap)") }
                lastClientSequence = csn
            }
            let accept = try state.process(first)
            log.append(first)
            opSources.append(.string(JSString(entry.source)))
            if try first.member("type") == .string("join") {
                let join = try JSON.parse(first.member("data").asString().description)
                if try join.member("clientId") == clientID { connected = true }
            }
            if connected {
                if accept { outgoing.append("accept"); debt = 0 }
                if try first.member("type") == .string("op") { debt += 1 }
            }
        }
        self.state = state
        if connected && debt >= noopCount && debt > 0 { outgoing.append("noop"); debt = 0 }
        return outgoing
    }
    private func catchUp(fetchUnbounded: Bool = false) async throws {
        for type in try drain() { try await submit(type: type) }
        if !fetching && (fetchUnbounded || !pending.isEmpty) {
            fetching = true
            defer { fetching = false }
            var unbounded = fetchUnbounded
            while let current = state, unbounded || !pending.isEmpty {
                // Refetch the prior op deliberately: DeltaManager detects a replaced file by its
                // sender/type/MSN/reference/timestamp fingerprint, not by comparing contents.
                let from = max(1, current.sequenceNumber)
                let gapEnd = try pending.first?.message.member("sequenceNumber").asInt()
                let to = min(gapEnd ?? (from + 2000), from + 2000)
                let messages = try await storage.deltas(from: from, to: to, reason: unbounded ? "DocumentOpen" : "Gap")
                try enqueue(messages, source: "storage")
                for type in try drain() { try await submit(type: type) }
                let last = try messages.last?.member("sequenceNumber").asInt() ?? 0
                unbounded = unbounded && last == to - 1
                if let next = pending.first, let updated = state,
                   try next.message.member("sequenceNumber").asInt() > updated.sequenceNumber + 1,
                   updated.sequenceNumber == current.sequenceNumber {
                    throw JSONDecodingError("delta storage did not fill the sequence gap")
                }
            }
        }
        if debt > 0 && noopTimer == nil {
            noopTimer = Task {
                do { try await Task.sleep(for: .milliseconds(noopTime)); try await self.timerFired() }
                catch is CancellationError { } catch { self.failure = String(describing: error) }
            }
        }
    }
    private func timerFired() async throws { noopTimer = nil; if connected && debt > 0 { try await submit(type: "noop") } }
    public func submit(type: String, contents: JSONValue? = nil) async throws {
        guard connected, let connection, let state else { throw JSONDecodingError("not connected to own join") }
        clientSequence += 1; debt = 0
        if type == "noop" { noopCountInFlight += 1 }
        var message = JSObject<JSONValue>()
        message["clientSequenceNumber"] = .number(Double(clientSequence)); message["referenceSequenceNumber"] = .number(Double(state.sequenceNumber))
        message["type"] = .string(JSString(type)); if let contents { message["contents"] = contents }
        try await connection.submit([.object(message)])
    }
    public func signal(_ text: String) async throws { guard let connection else { throw JSONDecodingError("disconnected") }; try await connection.submitSignal(text) }
    public func view() throws -> JSONValue {
        if let failure { throw JSONDecodingError(failure) }
        guard let state else { throw JSONDecodingError("unloaded") }
        var view = try state.view.asObject(); view["snapshotSequenceNumber"] = .number(Double(snapshotSequenceNumber)); view["ops"] = .array(log); view["opSources"] = .array(opSources); view["signals"] = .array(signals); view["clientId"] = clientID; view["connected"] = .bool(connected)
        return .object(view)
    }
    public func disconnect() async {
        connected = false; debt = 0; noopTimer?.cancel(); noopTimer = nil
        reader?.cancel(); reader = nil
        await connection?.disconnect(); connection = nil
    }
}
