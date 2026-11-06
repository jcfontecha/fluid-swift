import FluidDatastoreDefinitions
import FluidJS
import FluidDriverDefinitions

/// Port of `@fluidframework/counter` `SharedCounter` (counter.ts).
public final class SharedCounter: Channel {
    public static let type: JSString = "https://graph.microsoft.com/types/counter"

    private static let snapshotFileName: JSString = "header"

    public struct IncrementError: Error, CustomStringConvertible {
        public let description = "Must increment by a whole number"
    }

    public let id: JSString
    public private(set) var value: Double = 0

    private var pendingOps: [(incrementAmount: Double, messageId: Int)] = []
    private var nextPendingMessageId = 0
    private var submit: ((JSONValue, Int) -> Void)?

    public init(id: JSString) {
        self.id = id
    }

    public static func load(id: JSString, summary: SummaryTree) throws -> SharedCounter {
        let counter = SharedCounter(id: id)
        counter.value = try summary.readAndParse(snapshotFileName).member("value").asNumber()
        return counter
    }

    public func connect(_ submit: @escaping (JSONValue, Int) -> Void) {
        self.submit = submit
    }

    public func increment(_ incrementAmount: Double) throws {
        // Incrementing by non-integers would be eventually inconsistent, since the order in which
        // increments apply would affect the result.
        guard incrementAmount.truncatingRemainder(dividingBy: 1) == 0 else { throw IncrementError() }

        let messageId = nextPendingMessageId
        nextPendingMessageId += 1
        value += incrementAmount
        // Ops are only sent once attached.
        if let submit {
            pendingOps.append((incrementAmount, messageId))
            submit(Self.incrementOp(incrementAmount), messageId)
        }
    }

    public func process(_ message: SequencedMessage, local: Bool, localOpMetadata: Int?) throws {
        guard message.type == MessageType.operation else { return }
        let contents = message.contents
        guard try contents.member("type").asString() == "increment" else {
            throw JSONDecodingError("Unknown operation")
        }
        let incrementAmount = try contents.member("incrementAmount").asNumber()
        if local {
            // Already applied optimistically; retire the matching pending op.
            let pendingOp = pendingOps.removeFirst()
            precondition(
                pendingOp.messageId == localOpMetadata && pendingOp.incrementAmount == incrementAmount,
                "0xc8f: local op mismatch"
            )
        } else {
            value += incrementAmount
        }
    }

    public func summarize() -> SummaryTree {
        var content = JSObject<JSONValue>()
        content["value"] = .number(value)
        return .singleBlob(Self.snapshotFileName, JSString(JSON.stringify(.object(content))))
    }

    private static func incrementOp(_ incrementAmount: Double) -> JSONValue {
        var op = JSObject<JSONValue>()
        op["type"] = .string("increment")
        op["incrementAmount"] = .number(incrementAmount)
        return .object(op)
    }
}
