import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase

/// The accepted value reported by `getWithDetails`.
/// Port of `packages/dds/pact-map/src/interfaces.ts` IAcceptedPact.
public struct IAcceptedPact: Equatable {
    /// The accepted value, or `nil` (JS `undefined`) after an accepted delete.
    public let value: JSONValue?

    /// The sequence number at which the value was accepted.
    public let acceptedSequenceNumber: Int
}

/// The accepted pact information, if any.
/// Port of `packages/dds/pact-map/src/pactMap.ts` IAcceptedPactInternal.
private struct IAcceptedPactInternal {
    /// The accepted value or `nil` (typically in case of delete).
    var value: JSONValue?

    /// The sequence number when the value was accepted, which normally coincides with either the
    /// sequence number of the "accept" op from the final client we expected signoff from or the
    /// sequence number of the ClientLeave of that client. For values set in detached state, it is 0.
    var sequenceNumber: Int
}

/// The pending pact information, if any.
/// Port of `packages/dds/pact-map/src/pactMap.ts` IPendingPact.
private struct IPendingPact {
    /// The pending value or `nil` (typically in case of delete).
    var value: JSONValue?

    /// The clientIds that we expect "accept" ops from. Clients are also removed from this list if
    /// they leave the quorum without accepting. When it empties, the pending value is accepted.
    var expectedSignoffs: [JSString]
}

/// Internal format of the values stored in the PactMap (`Pact<T>`): at least one of the two is set.
private struct Pact {
    var accepted: IAcceptedPactInternal?
    var pending: IPendingPact?
}

/// Per-key proposal/acceptance consensus across the quorum present at proposal sequencing.
/// Port of `packages/dds/pact-map/src/pactMap.ts` PactMapClass. Values are plain JSON; `nil` is JS
/// `undefined`.
public final class PactMapClass: SharedObject<Void> {
    public override class var type: JSString { "https://graph.microsoft.com/types/pact-map" }

    private static let snapshotFileName: JSString = "header"

    private var values = JSMap<JSString, Pact>()

    /// `queueMicrotask` callbacks from a detached `set`, oldest first.
    private var microtasks: [() throws -> Void] = []

    /// Token of the `removeMember` listener on the runtime's quorum, once subscribed.
    private var quorumSubscription: Int?

    /// "pending" (key). Emitted when a proposal for the key is sequenced.
    public var pending: ((JSString) -> Void)?

    /// "accepted" (key). Emitted when the pending value for the key is accepted.
    public var accepted: ((JSString) -> Void)?

    public func get(_ key: JSString) -> JSONValue? {
        values.get(key)?.accepted?.value
    }

    public func getWithDetails(_ key: JSString) -> IAcceptedPact? {
        guard let acceptedPact = values.get(key)?.accepted else {
            return nil
        }
        return IAcceptedPact(
            value: acceptedPact.value, acceptedSequenceNumber: acceptedPact.sequenceNumber)
    }

    public func isPending(_ key: JSString) -> Bool {
        values.get(key)?.pending != nil
    }

    public func getPending(_ key: JSString) -> JSONValue? {
        values.get(key)?.pending?.value
    }

    public func set(_ key: JSString, _ value: JSONValue?) throws {
        // Early-exit if we can't submit a valid proposal (there's already a pending proposal).
        if values.get(key)?.pending != nil {
            return
        }

        // If not attached, we basically pretend we got an ack immediately. The TS code queues a
        // microtask so callers complete their call stacks before the result takes effect.
        guard isAttached else {
            microtasks.append { [unowned self] in
                try handleIncomingSet(key, value, 0, 0)
            }
            return
        }

        let refSeq = try attachedRuntime().deltaManager.lastSequenceNumber
        try submitLocalMessage(Self.setOperation(key, value, refSeq), ())
    }

    public func delete(_ key: JSString) throws {
        // Early-exit if there is nothing to delete, a proposal is pending (ours would be invalid),
        // or the accepted value is undefined, which is equivalent to already being deleted.
        guard let currentValue = values.get(key),
            currentValue.pending == nil,
            currentValue.accepted?.value != nil
        else {
            return
        }
        try set(key, nil)
    }

    /// Runs the callbacks a detached `set` queued with `queueMicrotask`, including any they queue.
    /// The host calls this where a JS engine would reach a microtask checkpoint.
    public func runMicrotasks() throws {
        while !microtasks.isEmpty {
            let microtask = microtasks.removeFirst()
            try microtask()
        }
    }

    /// The clients that must sign off before a value moves from "pending" to "accepted". The list is
    /// finalized for a value at the moment it goes pending: clients that join later are not added.
    /// If detached, nobody needs to sign off.
    private func getSignoffClients() throws -> [JSString] {
        guard isAttached else {
            return []
        }
        return try attachedRuntime().getQuorum().getMembers().keys
    }

    private func handleIncomingSet(
        _ key: JSString, _ value: JSONValue?, _ refSeq: Int, _ setSequenceNumber: Int
    ) throws {
        let currentValue = values.get(key)

        // We use a consensus-like approach here, so a proposal is valid if the value is unset or if
        // there is no pending change and it was made with knowledge of the most recently accepted
        // value. Invalid proposals are dropped on the ground.
        var proposalValid = currentValue == nil
        if let currentValue, currentValue.pending == nil,
            let acceptedPact = currentValue.accepted, acceptedPact.sequenceNumber <= refSeq
        {
            proposalValid = true
        }
        guard proposalValid else {
            return
        }

        // We expect signoffs from all connected clients at the time the set was sequenced
        // (including the client who sent the set).
        let expectedSignoffs = try getSignoffClients()

        values.set(
            key,
            Pact(
                accepted: currentValue?.accepted,
                pending: IPendingPact(value: value, expectedSignoffs: expectedSignoffs)))

        pending?(key)

        if expectedSignoffs.isEmpty {
            // At least the submitting client should be amongst the expectedSignoffs, but this check
            // stays as extra protection and in case the "submitting client implicitly accepts"
            // optimization comes back.
            values.set(
                key,
                Pact(
                    accepted: IAcceptedPactInternal(value: value, sequenceNumber: setSequenceNumber),
                    pending: nil))
            accepted?(key)
        } else if let clientId = runtime?.clientId, expectedSignoffs.contains(clientId) {
            // Emit an accept upon a new key entering pending state if our accept is expected.
            try submitLocalMessage(Self.acceptOperation(key), ())
        }
    }

    private func handleIncomingAccept(
        _ key: JSString, _ clientId: JSString, _ sequenceNumber: Int
    ) throws {
        guard var pendingPact = values.get(key)?.pending else {
            // If there is no pending value, we already accepted it, so we can ignore the accept op.
            return
        }
        guard pendingPact.expectedSignoffs.contains(clientId) else {
            throw SharedObjectError("0x2f9: Unexpected accept op, client not in expectedSignoffs")
        }

        // Remove the client from the expected signoffs.
        pendingPact.expectedSignoffs.removeAll { $0 == clientId }

        if pendingPact.expectedSignoffs.isEmpty {
            // The pending value has settled.
            values.set(
                key,
                Pact(
                    accepted: IAcceptedPactInternal(
                        value: pendingPact.value, sequenceNumber: sequenceNumber),
                    pending: nil))
            accepted?(key)
        } else {
            values.set(key, Pact(accepted: values.get(key)?.accepted, pending: pendingPact))
        }
    }

    private func handleQuorumRemoveMember(_ clientId: JSString) {
        for (key, pact) in values.entries {
            guard var pendingPact = pact.pending else {
                continue
            }
            pendingPact.expectedSignoffs.removeAll { $0 == clientId }

            if pendingPact.expectedSignoffs.isEmpty {
                // The pending value has settled. Its sequence number is the one of the ClientLeave
                // message, which is the last message the container processed.
                let clientLeaveSequenceNumber = runtime?.deltaManager.lastSequenceNumber ?? 0
                values.set(
                    key,
                    Pact(
                        accepted: IAcceptedPactInternal(
                            value: pendingPact.value, sequenceNumber: clientLeaveSequenceNumber),
                        pending: nil))
                accepted?(key)
            } else {
                values.set(key, Pact(accepted: pact.accepted, pending: pendingPact))
            }
        }
    }

    /// `summarizeCore`: a single `header` blob, `JSON.stringify([...values.entries()])`.
    public override func summarize() -> SummaryTree {
        let entries = values.entries.map { entry in
            JSONValue.array([.string(entry.key), Self.encode(entry.value)])
        }
        return .singleBlob(Self.snapshotFileName, JSString(JSON.stringify(.array(entries))))
    }

    /// `loadCore`: copies the stored pairs verbatim, with no quorum filtering, no automatic
    /// acceptance and no events.
    public override func loadCore(_ summary: SummaryTree) throws {
        for entry in try summary.readAndParse(Self.snapshotFileName).asArray() {
            let pair = try entry.asArray()
            guard pair.count == 2 else {
                throw JSONDecodingError("expected [key, pact]")
            }
            values.set(try pair[0].asString(), try Self.decodePact(pair[1]))
        }
    }

    /// Joins the runtime's quorum once connected (TS subscribes in the constructor, where the
    /// runtime is already known).
    public override func onConnect() {
        guard quorumSubscription == nil, let runtime else {
            return
        }
        quorumSubscription = runtime.getQuorum().onRemoveMember { [weak self] clientId in
            self?.handleQuorumRemoveMember(clientId)
        }
    }

    public override func reSubmitCore(_ content: JSONValue, localOpMetadata: Void) throws {
        let type = try content.member("type").asString()
        let key = try content.member("key").asString()

        // Filter out set messages that have no chance of being accepted because there's another
        // value pending or another value was accepted while we were disconnected.
        if type == "set", let currentValue = values.get(key) {
            let refSeq = try content.member("refSeq").asInt()
            if currentValue.pending != nil || refSeq < (currentValue.accepted?.sequenceNumber ?? -1)
            {
                return
            }
        }

        // Otherwise we can resubmit.
        try submitLocalMessage(content, ())
    }

    public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
        for content in contents {
            try processMessage(content.message)
        }
    }

    private func processMessage(_ message: SequencedMessage) throws {
        guard message.type == MessageType.operation else {
            return
        }
        let op = message.contents
        switch try op.member("type").asString() {
        case "set":
            try handleIncomingSet(
                op.member("key").asString(),
                op.asObject()["value"],
                op.member("refSeq").asInt(),
                message.sequenceNumber)
        case "accept":
            try handleIncomingAccept(
                op.member("key").asString(), message.clientId, message.sequenceNumber)
        default:
            throw SharedObjectError("Unknown operation")
        }
    }

    public override func applyStashedOp(_ content: JSONValue) throws {
        throw SharedObjectError("not implemented")
    }

    private func attachedRuntime() throws -> any IFluidDataStoreRuntime {
        guard let runtime else {
            throw SharedObjectError("PactMap is attached but has no runtime")
        }
        return runtime
    }

    // MARK: Wire and summary encoding

    /// `{type:"set", key, value, refSeq}`; an undefined value is omitted, as `JSON.stringify` does.
    private static func setOperation(
        _ key: JSString, _ value: JSONValue?, _ refSeq: Int
    ) -> JSONValue {
        var op = JSObject<JSONValue>()
        op["type"] = .string("set")
        op["key"] = .string(key)
        op["value"] = value
        op["refSeq"] = .number(Double(refSeq))
        return .object(op)
    }

    /// `{type:"accept", key}`.
    private static func acceptOperation(_ key: JSString) -> JSONValue {
        var op = JSObject<JSONValue>()
        op["type"] = .string("accept")
        op["key"] = .string(key)
        return .object(op)
    }

    /// `{accepted?: {value?, sequenceNumber}, pending?: {value?, expectedSignoffs}}`.
    private static func encode(_ pact: Pact) -> JSONValue {
        var object = JSObject<JSONValue>()
        if let acceptedPact = pact.accepted {
            var accepted = JSObject<JSONValue>()
            accepted["value"] = acceptedPact.value
            accepted["sequenceNumber"] = .number(Double(acceptedPact.sequenceNumber))
            object["accepted"] = .object(accepted)
        }
        if let pendingPact = pact.pending {
            var pending = JSObject<JSONValue>()
            pending["value"] = pendingPact.value
            pending["expectedSignoffs"] = .array(pendingPact.expectedSignoffs.map(JSONValue.string))
            object["pending"] = .object(pending)
        }
        return .object(object)
    }

    private static func decodePact(_ json: JSONValue) throws -> Pact {
        let object = try json.asObject()
        var pact = Pact()
        if let accepted = object["accepted"] {
            pact.accepted = IAcceptedPactInternal(
                value: try accepted.asObject()["value"],
                sequenceNumber: try accepted.member("sequenceNumber").asInt())
        }
        if let pending = object["pending"] {
            pact.pending = IPendingPact(
                value: try pending.asObject()["value"],
                expectedSignoffs: try pending.member("expectedSignoffs").asArray().map {
                    try $0.asString()
                })
        }
        return pact
    }
}
