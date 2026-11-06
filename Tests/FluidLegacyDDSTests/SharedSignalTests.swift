import FluidDriverDefinitions
import FluidJS
import FluidLegacyDDS
import FluidSharedObjectBase
import FluidTestRuntimeUtils
import Testing

/// One notify event: the metadata and whether the notification was local.
private struct Notification: Equatable {
  let metadata: FluidValue
  let isLocal: Bool
}

private func recordNotifications(_ signal: SharedSignalClass) -> NotificationLog {
  let log = NotificationLog()
  signal.notifyEvent = { metadata, isLocal in
    log.events.append(Notification(metadata: metadata, isLocal: isLocal))
  }
  return log
}

private final class NotificationLog {
  var events: [Notification] = []
}

private func connectedSignal(
  _ factory: MockContainerRuntimeFactory<SharedSignalClass>, _ clientId: JSString,
  flushMode: FlushMode = .immediate
) -> (signal: SharedSignalClass, runtime: MockContainerRuntime<SharedSignalClass>) {
  let signal = SharedSignalClass(id: "signal")
  let runtime = factory.createContainerRuntime(
    clientId: clientId, channel: signal, flushMode: flushMode)
  return (signal, runtime)
}

/// signal.spec.ts "should notify both local and remote listeners with the IFluidHandle". The ack of a local op is
/// not dispatched, so the local listener hears the signal once, from `notify` itself, and the remote hears it
/// from the op.
@Test func signalNotifiesLocalAndRemoteWithHandle() throws {
  let handle = FluidValue.handle(FluidHandle(absolutePath: "/store/handle"))
  let factory = MockContainerRuntimeFactory<SharedSignalClass>()
  let local = connectedSignal(factory, "A")
  let remote = connectedSignal(factory, "B")
  let localLog = recordNotifications(local.signal)
  let remoteLog = recordNotifications(remote.signal)
  try local.signal.notify(handle)
  #expect(localLog.events == [Notification(metadata: handle, isLocal: true)])
  try factory.processAllMessages()
  #expect(localLog.events == [Notification(metadata: handle, isLocal: true)])
  #expect(remoteLog.events == [Notification(metadata: handle, isLocal: false)])
}

/// The op is `{"type":"signal","metadata":...}`, and omits `metadata` when there is none.
@Test func signalOpWireFormat() throws {
  let factory = MockContainerRuntimeFactory<SharedSignalClass>()
  let client = connectedSignal(factory, "A")
  try client.signal.notify(.json(.number(1)))
  try client.signal.notify(nil)
  #expect(
    client.runtime.takeOutbound().map { JSON.stringify($0.contents) } == [
      #"{"type":"signal","metadata":1}"#,
      #"{"type":"signal"}"#,
    ])
}

/// A remote op without metadata notifies with undefined.
@Test func signalNotifiesUndefinedMetadata() throws {
  let factory = MockContainerRuntimeFactory<SharedSignalClass>()
  let local = connectedSignal(factory, "A")
  let remote = connectedSignal(factory, "B")
  let log = recordNotifications(remote.signal)
  try local.signal.notify(nil)
  try factory.processAllMessages()
  #expect(log.events == [Notification(metadata: .undefined, isLocal: false)])
}

/// A detached signal neither notifies nor submits.
@Test func signalDetachedNotifyDoesNothing() throws {
  let signal = SharedSignalClass(id: "signal")
  let log = recordNotifications(signal)
  try signal.notify(.json(.number(1)))
  #expect(log.events.isEmpty)
}

/// The summary is one `header` blob holding the JSON empty string, and loading ignores it.
@Test func signalSummaryIsEmptyStringBlob() throws {
  let signal = SharedSignalClass(id: "signal")
  let summary = signal.summarize()
  #expect(summary == .singleBlob("header", "\"\""))
  _ = try SharedSignalClass.load(id: "loaded", summary: summary)
}

/// signal.rollback.spec.ts "rollback should not throw": the optimistic notification is not undone.
@Test func signalRollbackDoesNotThrow() throws {
  let factory = MockContainerRuntimeFactory<SharedSignalClass>()
  let client = connectedSignal(factory, "1", flushMode: .turnBased)
  let log = recordNotifications(client.signal)
  try client.signal.notify(.json(.number(0)))
  try client.runtime.rollback()
  #expect(log.events == [Notification(metadata: .json(.number(0)), isLocal: true)])
}

/// A stashed signal does nothing: no event and no submission.
@Test func signalStashedOpDoesNothing() throws {
  let factory = MockContainerRuntimeFactory<SharedSignalClass>()
  let client = connectedSignal(factory, "A")
  let log = recordNotifications(client.signal)
  try client.signal.applyStashedOp(try JSON.parse(#"{"type":"signal","metadata":1}"#))
  #expect(log.events.isEmpty)
  #expect(client.runtime.takeOutbound().isEmpty)
  #expect(throws: (any Error).self) {
    try client.signal.applyStashedOp(try JSON.parse(#"{"type":"other"}"#))
  }
}

/// An unknown remote op throws `Unknown operation`.
@Test func signalUnknownRemoteOperationThrows() throws {
  let factory = MockContainerRuntimeFactory<SharedSignalClass>()
  let client = connectedSignal(factory, "A")
  let message = try SequencedMessage(
    json: try JSON.parse(
      #"{"clientId":"B","clientSequenceNumber":1,"referenceSequenceNumber":0,"sequenceNumber":1,"minimumSequenceNumber":0,"type":"op","contents":{"type":"other"}}"#
    ))
  #expect(throws: (any Error).self) { try client.runtime.process(message) }
}
