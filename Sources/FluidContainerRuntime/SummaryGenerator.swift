import FluidDriverDefinitions
import FluidJS

/// Ports summary/summaryDelayLoadedModule/summaryGenerator.ts: proposal/broadcast/ack correlation.
/// Container performs asynchronous upload and submission; this state never leaves its executor.
public final class SummaryGenerator {
    public private(set) var proposalHandle: JSString?
    public private(set) var ackHandle: JSString?
    public private(set) var pendingHandle: JSString?
    public private(set) var pendingSequenceNumber: Int?
    public private(set) var lastNack: JSONValue?
    public private(set) var acknowledgedCount = 0
    public init(ackHandle: JSString?) { self.ackHandle = ackHandle }
    public func context(referenceSequenceNumber: Int) throws -> ISummaryContext {
        var fields = JSObject<JSONValue>()
        fields["proposalHandle"] = proposalHandle.map(JSONValue.string)
        fields["ackHandle"] = ackHandle.map(JSONValue.string)
        fields["referenceSequenceNumber"] = .number(Double(referenceSequenceNumber))
        return try ISummaryContext(json: .object(fields))
    }
    public func submitted(handle: JSString, referenceSequenceNumber: Int, minimumSequenceNumber: Int) throws -> JSONValue {
        guard pendingHandle == nil else { throw JSONDecodingError("summary already pending") }
        pendingHandle = handle
        lastNack = nil
        var contents = JSObject<JSONValue>()
        contents["handle"] = .string(handle)
        contents["head"] = ackHandle.map(JSONValue.string)
        contents["message"] = .string(JSString("Summary @\(referenceSequenceNumber):\(minimumSequenceNumber)"))
        contents["parents"] = .array(ackHandle.map { [.string($0)] } ?? [])
        return .object(contents)
    }
    public func failAttempt() {
        pendingHandle = nil
        pendingSequenceNumber = nil
    }
    /// Returns true only for an ack of this generation's broadcast proposal.
    public func process(_ message: ISequencedDocumentMessage) throws -> Bool {
        guard var contents = message.contents else { return false }
        if case .string(let text) = contents { contents = try JSON.parse(text.description) }
        if message.type == "summarize" {
            if try contents.member("handle").asString() == pendingHandle { pendingSequenceNumber = message.sequenceNumber }
            return false
        }
        guard message.type == "summaryAck" || message.type == "summaryNack" else { return false }
        let sequence = try contents.member("summaryProposal").member("summarySequenceNumber").asInt()
        guard sequence == pendingSequenceNumber else { return false }
        defer {
            pendingHandle = nil
            pendingSequenceNumber = nil
        }
        if message.type == "summaryNack" {
            lastNack = contents
            return false
        }
        ackHandle = try contents.member("handle").asString()
        proposalHandle = pendingHandle
        acknowledgedCount += 1
        return true
    }
}

public struct SummaryNackError: Error, Sendable, CustomStringConvertible {
    public let nack: ISummaryNack
    public init(_ value: JSONValue) throws { nack = try ISummaryNack(json: value) }
    public var description: String { "summaryNack: " + JSON.stringify(nack.json) }
}
