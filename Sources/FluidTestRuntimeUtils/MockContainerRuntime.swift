import FluidDatastoreDefinitions
import FluidJS
import FluidDriverDefinitions

/// Port of `MockContainerRuntime` (test-runtime-utils mocks.ts) for one channel, flush mode
/// Immediate, sequenced externally: submitted messages accumulate in `outbound` instead of going
/// to a factory queue.
public final class MockContainerRuntime<C: Channel> {
    public let clientId: JSString
    public let channel: C
    public private(set) var lastSequenceNumber: Int

    private var clientSequenceNumber = 0
    private var pendingMessages: [(clientSequenceNumber: Int, localOpMetadata: C.LocalOpMetadata)] = []
    private var outbound: [UnsequencedMessage] = []

    public init(clientId: JSString, channel: C, lastSequenceNumber: Int) {
        self.clientId = clientId
        self.channel = channel
        self.lastSequenceNumber = lastSequenceNumber
        channel.connect { [unowned self] contents, localOpMetadata in
            submit(contents, localOpMetadata)
        }
    }

    /// Messages submitted since the last call.
    public func takeOutbound() -> [UnsequencedMessage] {
        defer { outbound.removeAll() }
        return outbound
    }

    public func process(_ message: SequencedMessage) throws {
        lastSequenceNumber = message.sequenceNumber
        let local = message.clientId == clientId
        var localOpMetadata: C.LocalOpMetadata?
        if local {
            let pending = pendingMessages.removeFirst()
            precondition(pending.clientSequenceNumber == message.clientSequenceNumber, "Unexpected message")
            localOpMetadata = pending.localOpMetadata
        }
        try channel.process(message, local: local, localOpMetadata: localOpMetadata)
    }

    private func submit(_ contents: JSONValue, _ localOpMetadata: C.LocalOpMetadata) {
        clientSequenceNumber += 1
        outbound.append(UnsequencedMessage(
            clientId: clientId,
            clientSequenceNumber: clientSequenceNumber,
            referenceSequenceNumber: lastSequenceNumber,
            contents: contents
        ))
        pendingMessages.append((clientSequenceNumber, localOpMetadata))
    }
}
