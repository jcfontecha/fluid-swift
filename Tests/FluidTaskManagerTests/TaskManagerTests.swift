import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase
import FluidTaskManager
import FluidTestRuntimeUtils
import Testing

private let taskId: JSString = "taskId"

/// One connected TaskManager with its runtime, as taskManager.spec.ts `createConnectedTaskManager`.
private struct Client {
  let manager: TaskManagerClass
  let runtime: MockContainerRuntime<TaskManagerClass>
}

private func connected(
  _ id: JSString, _ factory: MockContainerRuntimeFactory<TaskManagerClass>,
  flushMode: FlushMode = .immediate
) -> Client {
  let manager = TaskManagerClass(id: "taskManager")
  let runtime = factory.createContainerRuntime(clientId: id, channel: manager, flushMode: flushMode)
  return Client(manager: manager, runtime: runtime)
}

private func twoClients() -> (MockContainerRuntimeFactory<TaskManagerClass>, Client, Client) {
  let factory = MockContainerRuntimeFactory<TaskManagerClass>()
  let first = connected("A", factory)
  let second = connected("B", factory)
  return (factory, first, second)
}

/// The text of the single `header` blob.
private func header(_ manager: TaskManagerClass) throws -> String {
  guard case .tree(let tree) = manager.summarize(), let blob = tree.tree["header"] else {
    throw JSONDecodingError("no header")
  }
  return try blob.json.member("content").asString().description
}

/// Counts the public events of a manager.
private final class Events {
  var assigned: [JSString] = []
  var lost: [JSString] = []
  var completed: [JSString] = []
}

private func observe(_ manager: TaskManagerClass) -> Events {
  let events = Events()
  manager.assignedEvent = { events.assigned.append($0) }
  manager.lostEvent = { events.lost.append($0) }
  manager.completedEvent = { events.completed.append($0) }
  return events
}

private let abandonedMessage: JSString = "Abandoned before acquiring task assignment"
private let disconnectedMessage: JSString = "Disconnected before acquiring task assignment"

// MARK: Connected state

/// "Volunteering for a task" › "Can volunteer for a task".
@Test func volunteerResolvesOnceSequenced() throws {
  let (factory, first, _) = twoClients()
  let promise = first.manager.volunteerForTask(taskId)
  #expect(!first.manager.queued(taskId))
  #expect(!first.manager.assigned(taskId))
  #expect(promise.state == .pending)
  try factory.processAllMessages()
  #expect(promise.state == .fulfilled(true))
  #expect(first.manager.queued(taskId))
  #expect(first.manager.assigned(taskId))
}

/// "Can wait for a task": the second volunteer waits in line until the first abandons.
@Test func volunteerWaitsForTheTask() throws {
  let (factory, first, second) = twoClients()
  let promise1 = first.manager.volunteerForTask(taskId)
  let promise2 = second.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  #expect(promise1.state == .fulfilled(true))
  #expect(promise2.state == .pending)
  #expect(second.manager.queued(taskId))
  #expect(!second.manager.assigned(taskId))

  try first.manager.abandon(taskId)
  try factory.processAllMessages()
  #expect(promise2.state == .fulfilled(true))
  #expect(!first.manager.queued(taskId))
  #expect(second.manager.assigned(taskId))
}

/// "Rejects the promise if abandon before ack": settled before any message is processed.
@Test func abandonBeforeAckRejects() throws {
  let (factory, first, _) = twoClients()
  let promise = first.manager.volunteerForTask(taskId)
  try first.manager.abandon(taskId)
  #expect(promise.state == .rejected(abandonedMessage))
  try factory.processAllMessages()
  #expect(!first.manager.queued(taskId))
  #expect(!first.manager.assigned(taskId))
}

/// "Rejects the promise if abandon after ack but before acquire".
@Test func abandonAfterAckBeforeAcquireRejects() throws {
  let (factory, first, second) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  let promise2 = second.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  #expect(second.manager.queued(taskId))

  try second.manager.abandon(taskId)
  #expect(promise2.state == .rejected(abandonedMessage))
  try factory.processAllMessages()
  #expect(!second.manager.queued(taskId))
}

/// "Can abandon and immediately attempt to reacquire a task".
@Test func abandonThenReacquire() throws {
  let (factory, first, _) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  try factory.processAllMessages()

  try first.manager.abandon(taskId)
  #expect(first.manager.queued(taskId))  // pending abandon
  #expect(first.manager.assigned(taskId))
  let again = first.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  #expect(again.state == .fulfilled(true))
  #expect(first.manager.assigned(taskId))
}

/// "Can attempt to volunteer for task twice and abandon twice (after ack)".
@Test func volunteerTwiceAbandonTwiceAfterAck() throws {
  let (factory, first, _) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  let second = first.manager.volunteerForTask(taskId)
  #expect(second.state == .fulfilled(true))
  #expect(factory.outstandingMessageCount == 0)

  try first.manager.abandon(taskId)
  #expect(first.manager.assigned(taskId))
  try factory.processAllMessages()
  #expect(!first.manager.queued(taskId))
  try first.manager.abandon(taskId)
  #expect(factory.outstandingMessageCount == 0)
}

/// "Can attempt to lock task twice and abandon twice (before ack)": a second volunteer sends no
/// second op, and both promises resolve.
@Test func volunteerTwiceBeforeAck() throws {
  let (factory, first, _) = twoClients()
  let promise1 = first.manager.volunteerForTask(taskId)
  let promise2 = first.manager.volunteerForTask(taskId)
  #expect(factory.outstandingMessageCount == 1)
  try factory.processAllMessages()
  #expect(promise1.state == .fulfilled(true))
  #expect(promise2.state == .fulfilled(true))

  try first.manager.abandon(taskId)
  try first.manager.abandon(taskId)
  #expect(factory.outstandingMessageCount == 1)
  try factory.processAllMessages()
  #expect(!first.manager.queued(taskId))
}

/// "Can volunteer for a task immediately after it was completed".
@Test func volunteerImmediatelyAfterComplete() throws {
  let (factory, first, second) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  try second.manager.subscribeToTask(taskId)
  try first.manager.complete(taskId)
  let again = first.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  #expect(again.state == .fulfilled(true))
  #expect(first.manager.assigned(taskId))
  #expect(!second.manager.queued(taskId))
}

/// "Subscribing to a task" › "Can subscribe to a task", "Can abandon a subscribed task" and
/// "Can subscribe and wait for a task".
@Test func subscribeAndAbandon() throws {
  let (factory, first, second) = twoClients()
  try first.manager.subscribeToTask(taskId)
  #expect(first.manager.subscribed(taskId))
  #expect(!first.manager.queued(taskId))
  try second.manager.subscribeToTask(taskId)
  try factory.processAllMessages()
  #expect(first.manager.assigned(taskId))
  #expect(second.manager.queued(taskId) && !second.manager.assigned(taskId))

  try first.manager.abandon(taskId)
  #expect(!first.manager.subscribed(taskId))
  try factory.processAllMessages()
  #expect(second.manager.assigned(taskId))
  #expect(second.manager.subscribed(taskId))
}

/// "Completing tasks" › "Can complete a task" and "Rejects ... without being assigned".
@Test func completeRequiresAssignment() throws {
  let (factory, first, second) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  _ = second.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  #expect(throws: SharedObjectError.self) { try second.manager.complete(taskId) }
  try first.manager.complete(taskId)
  try factory.processAllMessages()
  #expect(!first.manager.assigned(taskId))
}

/// "Can complete a task and remove other clients from queue": waiting volunteers resolve false and
/// subscribers are dropped.
@Test func completeRemovesOtherClients() throws {
  let (factory, first, second) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  let promise2 = second.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  try first.manager.complete(taskId)
  try factory.processAllMessages()
  #expect(promise2.state == .fulfilled(false))
  #expect(!second.manager.queued(taskId))

  try first.manager.subscribeToTask("other")
  try second.manager.subscribeToTask("other")
  try factory.processAllMessages()
  try first.manager.complete("other")
  try factory.processAllMessages()
  #expect(!first.manager.subscribed("other"))
  #expect(!second.manager.subscribed("other"))
  #expect(!second.manager.queued("other"))
}

/// "Can emit completed event", and "Can complete a task with a pending volunteer op".
@Test func completedEventFiresOncePerClient() throws {
  let (factory, first, second) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  try second.manager.subscribeToTask(taskId)
  try factory.processAllMessages()
  let events1 = observe(first.manager)
  let events2 = observe(second.manager)
  let pending = second.manager.volunteerForTask(taskId)  // a second volunteer op is not sent
  try first.manager.complete(taskId)
  try factory.processAllMessages()
  #expect(events1.completed == [taskId])
  #expect(events2.completed == [taskId])
  #expect(pending.state == .fulfilled(true) || pending.state == .fulfilled(false))
  #expect(events1.lost.isEmpty)  // complete does not emit lost
}

/// Assigned and lost events follow the head of the queue.
@Test func assignedAndLostEvents() throws {
  let (factory, first, second) = twoClients()
  let events1 = observe(first.manager)
  let events2 = observe(second.manager)
  _ = first.manager.volunteerForTask(taskId)
  _ = second.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  #expect(events1.assigned == [taskId])
  #expect(events2.assigned.isEmpty)
  try first.manager.abandon(taskId)
  try factory.processAllMessages()
  #expect(events1.lost == [taskId])
  #expect(events2.assigned == [taskId])
}

// MARK: Read/Write mode

/// "Read/Write Mode" › volunteer and subscribe in read mode and with read-only permissions.
@Test func readOnlyRejectsVolunteerAndSubscribe() throws {
  let (factory, first, _) = twoClients()
  first.runtime.mockDeltaManager.readOnlyInfo = ReadOnlyInfo(readonly: true, permissions: false)
  let promise = first.manager.volunteerForTask(taskId)
  #expect(promise.state == .rejected("Attempted to volunteer in read-only state"))
  try first.manager.subscribeToTask(taskId)  // transient read-only alone does not reject
  #expect(first.manager.subscribed(taskId))

  first.runtime.mockDeltaManager.readOnlyInfo = ReadOnlyInfo(readonly: true, permissions: true)
  let permissionPromise = first.manager.volunteerForTask("other")
  #expect(permissionPromise.state == .rejected("Attempted to volunteer with read-only permissions"))
  #expect(throws: SharedObjectError.self) { try first.manager.subscribeToTask("other") }
  #expect(!first.manager.subscribed("other"))
  try factory.processAllMessages()
}

// MARK: Detached and attach

private func detachedWithPlaceholder() -> TaskManagerClass {
  TaskManagerClass(id: "taskManager")
}

/// "Detached/Attach" › "Can volunteer for a task before attach", "Can volunteer and abandon a task
/// before attach", "Can complete a task before attach" and "Can emit completed event before attach".
@Test func detachedOperationsAutoAck() throws {
  let manager = detachedWithPlaceholder()
  let events = observe(manager)
  let promise = manager.volunteerForTask(taskId)
  #expect(promise.state == .fulfilled(true))
  #expect(manager.queued(taskId) && manager.assigned(taskId))
  try manager.abandon(taskId)
  #expect(!manager.queued(taskId))
  #expect(events.lost == [taskId])  // the old head was the placeholder

  _ = manager.volunteerForTask(taskId)
  try manager.complete(taskId)
  #expect(!manager.assigned(taskId))
  #expect(events.completed == [taskId])
}

/// "Will lose task assignment after attaching if clientId is undefined": the summary taken while
/// attaching drops the placeholder.
@Test func attachingWithoutClientIdLosesAssignment() throws {
  let manager = detachedWithPlaceholder()
  let events = observe(manager)
  _ = manager.volunteerForTask(taskId)
  #expect(try header(manager) == "[]")
  #expect(events.lost == [taskId])
  let factory = MockContainerRuntimeFactory<TaskManagerClass>()
  _ = factory.createContainerRuntime(clientId: "A", channel: manager)
  #expect(!manager.queued(taskId))
  #expect(!manager.assigned(taskId))
}

/// "Can subscribe to a task and stay subscribed after attach if clientId was undefined": attaching
/// re-volunteers with the real clientId.
@Test func subscriptionSurvivesAttach() throws {
  let manager = detachedWithPlaceholder()
  let events = observe(manager)
  try manager.subscribeToTask(taskId)
  #expect(try header(manager) == "[]")
  let factory = MockContainerRuntimeFactory<TaskManagerClass>()
  _ = factory.createContainerRuntime(clientId: "A", channel: manager)
  try factory.processAllMessages()
  #expect(events.lost == [taskId])
  // Assigned once as the placeholder while detached, and again as the real client.
  #expect(events.assigned == [taskId, taskId])
  #expect(manager.assigned(taskId) && manager.subscribed(taskId))
  #expect(try header(manager) == #"[["taskId",["A"]]]"#)
}

/// A detached abandon of a subscription before attach stops the attach-time volunteer.
@Test func detachedAbandonStopsAttachVolunteer() throws {
  let manager = detachedWithPlaceholder()
  try manager.subscribeToTask(taskId)
  try manager.abandon(taskId)
  #expect(!manager.subscribed(taskId))
  let factory = MockContainerRuntimeFactory<TaskManagerClass>()
  _ = factory.createContainerRuntime(clientId: "A", channel: manager)
  #expect(factory.outstandingMessageCount == 0)
}

// MARK: Disconnect/Reconnect

/// "Disconnect while assigned: Raises a lost event and loses the task assignment".
@Test func disconnectWhileAssignedRaisesLost() throws {
  let (factory, first, _) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  let events = observe(first.manager)
  first.runtime.disconnect()
  try factory.processAllMessages()
  #expect(!first.manager.assigned(taskId))
  #expect(events.lost == [taskId])
}

/// "Disconnect while queued: Rejects the volunteerForTask promise and exits the queue".
@Test func disconnectWhileQueuedRejects() throws {
  let (factory, first, second) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  let promise2 = second.manager.volunteerForTask(taskId)
  try factory.processAllMessages()
  second.runtime.disconnect()
  try factory.processAllMessages()
  // Leaving the quorum already removed B from the queue, so the abandon the disconnect listener
  // calls finds nothing to do and the disconnect rejection stands.
  #expect(promise2.state == .rejected(disconnectedMessage))
  #expect(!second.manager.queued(taskId))
}

/// "Disconnect while queued: Removed from the queue for other clients".
@Test func disconnectRemovesClientFromOtherQueues() throws {
  let (factory, first, second) = twoClients()
  _ = first.manager.volunteerForTask(taskId)
  try second.manager.subscribeToTask(taskId)
  try factory.processAllMessages()
  #expect(try header(first.manager) == #"[["taskId",["A","B"]]]"#)
  second.runtime.disconnect()
  try factory.processAllMessages()
  #expect(try header(first.manager) == #"[["taskId",["A"]]]"#)
}

/// "Disconnect while pending: Rejects the volunteerForTask promise".
@Test func disconnectWhilePendingRejects() throws {
  let (factory, first, _) = twoClients()
  let promise = first.manager.volunteerForTask(taskId)
  first.runtime.disconnect()
  try factory.processAllMessages()
  // The pending volunteer makes the listener's abandon() submit an abandon, which settles first.
  #expect(promise.state == .rejected(abandonedMessage))
  #expect(!first.manager.queued(taskId))
}

/// "Behavior while disconnected": volunteering rejects at once, completing throws, and a
/// subscription is allowed and re-volunteers on reconnect.
@Test func behaviorWhileDisconnected() throws {
  let (factory, first, _) = twoClients()
  first.runtime.disconnect()
  #expect(!first.manager.canVolunteer())
  let promise = first.manager.volunteerForTask(taskId)
  #expect(promise.state == .rejected("Attempted to volunteer in disconnected state"))
  #expect(throws: SharedObjectError.self) { try first.manager.complete(taskId) }

  try first.manager.subscribeToTask(taskId)
  #expect(first.manager.subscribed(taskId))
  #expect(!first.manager.queued(taskId))
  try factory.processAllMessages()
  try first.runtime.reconnect(clientId: "A2")
  try factory.processAllMessages()
  #expect(first.manager.assigned(taskId))
  #expect(first.manager.subscribed(taskId))
  #expect(try header(first.manager) == #"[["taskId",["A2"]]]"#)
}

/// "Does not re-attempt to enter the queue for un-ack'd ops" and "Does re-attempt to enter the queue
/// when subscribed".
@Test func reconnectResubmitsOnlySubscriptions() throws {
  let (factory, first, _) = twoClients()
  let promise = first.manager.volunteerForTask(taskId)
  first.runtime.disconnect()
  try factory.processAllMessages()
  #expect(promise.state == .rejected(abandonedMessage))
  try first.runtime.reconnect(clientId: "A2")
  try factory.processAllMessages()
  #expect(!first.manager.queued(taskId))

  try first.manager.subscribeToTask("sub")
  try factory.processAllMessages()
  first.runtime.disconnect()
  try first.runtime.reconnect(clientId: "A3")
  try factory.processAllMessages()
  #expect(first.manager.assigned("sub"))
}

// MARK: Rollback

/// taskManager.rollback.spec.ts "Rollback without remote ops": volunteer, abandon, subscribe and
/// complete are rolled back out of a turn-based outbox without touching the queues.
@Test func rollbackVolunteer() throws {
  let factory = MockContainerRuntimeFactory<TaskManagerClass>()
  let client = connected("A", factory, flushMode: .turnBased)
  let events = observe(client.manager)
  let promise = client.manager.volunteerForTask(taskId)
  try client.runtime.rollback()
  client.runtime.flush()
  try factory.processAllMessages()
  #expect(promise.state == .fulfilled(false))
  #expect(!client.manager.assigned(taskId))
  #expect(events.assigned.isEmpty)
}

@Test func rollbackAbandon() throws {
  let factory = MockContainerRuntimeFactory<TaskManagerClass>()
  let client = connected("A", factory, flushMode: .turnBased)
  let events = observe(client.manager)
  let promise = client.manager.volunteerForTask(taskId)
  client.runtime.flush()
  try factory.processAllMessages()
  #expect(promise.state == .fulfilled(true))
  try client.manager.abandon(taskId)
  #expect(client.manager.assigned(taskId))
  try client.runtime.rollback()
  try factory.processAllMessages()
  #expect(client.manager.assigned(taskId))
  #expect(events.lost.isEmpty)
}

@Test func rollbackSubscribe() throws {
  let factory = MockContainerRuntimeFactory<TaskManagerClass>()
  let client = connected("A", factory, flushMode: .turnBased)
  let events = observe(client.manager)
  try client.manager.subscribeToTask(taskId)
  try client.runtime.rollback()
  client.runtime.flush()
  try factory.processAllMessages()
  #expect(!client.manager.assigned(taskId))
  #expect(!client.manager.subscribed(taskId))
  #expect(events.assigned.isEmpty)
}

@Test func rollbackComplete() throws {
  let factory = MockContainerRuntimeFactory<TaskManagerClass>()
  let client = connected("A", factory, flushMode: .turnBased)
  let events = observe(client.manager)
  _ = client.manager.volunteerForTask(taskId)
  client.runtime.flush()
  try factory.processAllMessages()
  try client.manager.complete(taskId)
  try client.runtime.rollback()
  client.runtime.flush()
  try factory.processAllMessages()
  #expect(client.manager.assigned(taskId))
  #expect(events.completed.isEmpty)
}

// MARK: Summary and load

/// Summary: tasks with non-empty queues, in insertion order; loading scrubs clients that are not in
/// the quorum, and does not restore pending records or subscriptions.
@Test func summaryAndLoadScrubQuorum() throws {
  let (factory, first, second) = twoClients()
  _ = first.manager.volunteerForTask("render")
  _ = second.manager.volunteerForTask("render")
  _ = second.manager.volunteerForTask("upload")
  try factory.processAllMessages()
  let summary = first.manager.summarize()
  #expect(try header(first.manager) == #"[["render",["A","B"]],["upload",["B"]]]"#)

  let quorum = MockQuorumClients()
  quorum.addMember("A", .object(JSObject()))
  quorum.addMember("C", .object(JSObject()))
  let loaded = try TaskManagerClass.load(id: "loaded", summary: summary)
  let events = observe(loaded)
  let runtime = MockContainerRuntime(
    clientId: "C", channel: loaded, lastSequenceNumber: 0, quorum: quorum)
  #expect(try header(loaded) == #"[["render",["A"]]]"#)
  #expect(events.assigned.isEmpty)  // scrub reports no heads
  #expect(!loaded.subscribed("render"))
  #expect(runtime.channel === loaded)
}

/// The summary of an empty manager is `[]`.
@Test func emptySummary() throws {
  let (factory, first, _) = twoClients()
  #expect(try header(first.manager) == "[]")
  #expect(factory.runtimes.count == 2)
}

/// A member leaving the quorum is removed from every queue, in task order.
@Test func quorumRemovalDropsClientFromAllQueues() throws {
  let (factory, first, second) = twoClients()
  _ = first.manager.volunteerForTask("t1")
  _ = second.manager.volunteerForTask("t1")
  _ = second.manager.volunteerForTask("t2")
  try factory.processAllMessages()
  let events = observe(first.manager)
  factory.quorum.removeMember("A")
  #expect(try header(second.manager) == #"[["t1",["B"]],["t2",["B"]]]"#)
  #expect(events.lost == ["t1"])
}

// MARK: Errors and wire format

/// The op contents are `{type, taskId}` and an unknown op throws.
@Test func opsAndErrors() throws {
  let (factory, first, _) = twoClients()
  #expect(factory.runtimes.count == 2)
  _ = first.manager.volunteerForTask(taskId)
  #expect(
    JSON.stringify(first.runtime.takeOutbound()[0].contents)
      == #"{"type":"volunteer","taskId":"taskId"}"#)

  var op = JSObject<JSONValue>()
  op["type"] = .string("bogus")
  op["taskId"] = .string("t")
  var envelope = JSObject<JSONValue>()
  envelope["clientId"] = .string("B")
  envelope["clientSequenceNumber"] = .number(1)
  envelope["referenceSequenceNumber"] = .number(0)
  envelope["sequenceNumber"] = .number(1)
  envelope["minimumSequenceNumber"] = .number(0)
  envelope["type"] = .string("op")
  envelope["contents"] = .object(op)
  let unknown = try SequencedMessage(json: .object(envelope))
  #expect(throws: SharedObjectError.self) {
    try first.manager.process(unknown, local: false, localOpMetadata: nil)
  }
  #expect(throws: SharedObjectError.self) {
    try first.manager.reSubmitCore(.string("nonsense"), localOpMetadata: 0)
  }
  // Stashed ops are intentionally ignored.
  try first.manager.applyStashedOp(.object(op))
}
