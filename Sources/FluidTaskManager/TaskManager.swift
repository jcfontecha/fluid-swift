import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase

/// The three operations a TaskManager submits.
/// Port of `packages/dds/task-manager/src/taskManager.ts` ITaskManagerOperation: the wire content is
/// `{type, taskId}` in that member order.
private enum TaskManagerOperationType: String {
    case volunteer
    case abandon
    case complete
}

/// A local operation that has been submitted but not yet acknowledged.
/// Port of `packages/dds/task-manager/src/taskManager.ts` IPendingOp.
private struct IPendingOp {
    var type: TaskManagerOperationType
    var messageId: Int
}

/// Placeholder clientId for detached scenarios.
private let placeholderClientId: JSString = "placeholder"

/// A synchronous stand-in for Node's `EventEmitter` for one event name: listeners run in
/// registration order, over the listeners registered when the emit started.
private final class EventWatcher<Payload> {
    private var listeners: [(token: Int, once: Bool, callback: (Payload) -> Void)] = []
    private var nextToken = 0

    @discardableResult
    func on(_ callback: @escaping (Payload) -> Void) -> Int {
        nextToken += 1
        listeners.append((nextToken, false, callback))
        return nextToken
    }

    func once(_ callback: @escaping (Payload) -> Void) {
        nextToken += 1
        listeners.append((nextToken, true, callback))
    }

    func off(_ token: Int) {
        listeners.removeAll { $0.token == token }
    }

    func emit(_ payload: Payload) {
        let snapshot = listeners
        listeners.removeAll { $0.once }
        for listener in snapshot {
            listener.callback(payload)
        }
    }
}

/// `queueChange`: the head of a task's queue changed. Both heads are `nil` for a scrub of clients
/// that are not in the quorum, which does not derive them.
private struct QueueChange {
    var taskId: JSString
    var oldLockHolder: JSString?
    var newLockHolder: JSString?
}

/// The outcome of `volunteerForTask`: a JS `Promise<boolean>`. Continuations are not scheduled in
/// this synchronous port; read `state` instead. A promise settles once; later settles are ignored.
public final class VolunteerPromise {
    public enum State: Equatable {
        case pending
        case fulfilled(Bool)

        /// The `Error.message` the promise rejected with.
        case rejected(JSString)
    }

    public private(set) var state: State = .pending

    fileprivate func resolve(_ value: Bool) {
        if state == .pending {
            state = .fulfilled(value)
        }
    }

    fileprivate func reject(_ message: JSString) {
        if state == .pending {
            state = .rejected(message)
        }
    }
}

/// Sequenced per-task FIFO lock queues. Quorum membership removes stale volunteers; optional
/// subscriptions re-volunteer across disconnect.
/// Port of `packages/dds/task-manager/src/taskManager.ts` TaskManagerClass.
public final class TaskManagerClass: SharedObject<Int> {
    public override class var type: JSString { "https://graph.microsoft.com/types/task-manager" }

    private static let snapshotFileName: JSString = "header"

    /// Mapping of taskId to a queue of clientIds that are waiting on the task. Maintains the
    /// consensus state of the queue, even if we know we've submitted an op that should eventually
    /// modify the queue.
    private var taskQueues = JSMap<JSString, [JSString]>()

    // queueWatcher emits an event whenever the consensus state of the task queues changes.
    private let queueWatcher = EventWatcher<QueueChange>()
    // abandonWatcher emits an event whenever the local client calls abandon() on a task, and again
    // when the abandon op is acknowledged (taskId, messageId).
    private let abandonWatcher = EventWatcher<(JSString, Int?)>()
    // connectionWatcher's "disconnect" event. Its "connect" event has no listeners.
    private let disconnectWatcher = EventWatcher<Void>()
    // completedWatcher emits an event whenever the local client receives a completed op.
    private let completedWatcher = EventWatcher<(JSString, Int?)>()
    // rollbackWatcher emits an event whenever a pending op is rolled back.
    private let rollbackWatcher = EventWatcher<JSString>()
    // attachedWatcher emits an event whenever the client becomes attached.
    private let attachedWatcher = EventWatcher<Void>()

    private var nextPendingMessageId = 0

    /// Tracks the most recent pending ops for a given task.
    private var latestPendingOps = JSMap<JSString, [IPendingOp]>()

    /// Tracks tasks that this client is currently subscribed to.
    private var subscribedTasks = Set<JSString>()

    /// Token of the `removeMember` listener on the runtime's quorum, once subscribed.
    private var quorumSubscription: Int?

    /// Set by `loadCore`: the quorum is only known once the runtime connects, and the TS load
    /// scrubs clients that are not in the quorum.
    private var scrubOnConnect = false

    /// An error a listener hit where it cannot propagate (the disconnect hook does not throw). The
    /// object counts as closed by it, as `SharedObject` closes on a listener exception.
    private var listenerFailure: SharedObjectError?

    /// "assigned" (taskId).
    public var assignedEvent: ((JSString) -> Void)?

    /// "lost" (taskId).
    public var lostEvent: ((JSString) -> Void)?

    /// "completed" (taskId).
    public var completedEvent: ((JSString) -> Void)?

    public required init(id: JSString) {
        super.init(id: id)

        queueWatcher.on { [unowned self] change in
            // If oldLockHolder is placeholderClientId we need to emit the task was lost during the
            // attach process.
            if change.oldLockHolder == placeholderClientId {
                lostEvent?(change.taskId)
                return
            }

            if change.oldLockHolder != clientId && change.newLockHolder == clientId {
                assignedEvent?(change.taskId)
            } else if change.oldLockHolder == clientId && change.newLockHolder != clientId {
                lostEvent?(change.taskId)
            }
        }

        disconnectWatcher.on { [unowned self] in
            // Emit "lost" for any tasks we were assigned to.
            for entry in taskQueues.entries {
                if isAttached && entry.value.first == clientId {
                    lostEvent?(entry.key)
                }
            }

            // Remove this client from all queues to reflect the new state, since being
            // disconnected automatically removes this client from all queues.
            removeClientFromAllQueues(clientId)
        }
    }

    /// Returns the clientId. Will return a placeholder if the runtime is detached and not yet
    /// assigned a clientId.
    private var clientId: JSString {
        runtime?.clientId ?? placeholderClientId
    }

    /// Returns the current read/write permissions. A channel with no runtime yet has no delta
    /// manager and is writable.
    private var readOnlyInfo: ReadOnlyInfo {
        runtime?.deltaManager.readOnlyInfo ?? ReadOnlyInfo(readonly: false)
    }

    /// Throws what an earlier listener could not.
    private func verifyListenersSucceeded() throws {
        if let listenerFailure {
            throw listenerFailure
        }
    }

    // MARK: Submitting operations

    private static func operation(_ type: TaskManagerOperationType, _ taskId: JSString)
        -> JSONValue
    {
        var op = JSObject<JSONValue>()
        op["type"] = .string(JSString(type.rawValue))
        op["taskId"] = .string(taskId)
        return .object(op)
    }

    /// `submitVolunteerOp`, `submitAbandonOp` and `submitCompleteOp`: the message ID is allocated
    /// before the submit, and the pending record is appended after it.
    private func submitOp(_ type: TaskManagerOperationType, _ taskId: JSString) throws {
        let pendingOp = IPendingOp(type: type, messageId: nextPendingMessageId)
        nextPendingMessageId += 1
        try submitLocalMessage(Self.operation(type, taskId), pendingOp.messageId)
        var latestPendingOps = self.latestPendingOps.get(taskId) ?? []
        latestPendingOps.append(pendingOp)
        self.latestPendingOps.set(taskId, latestPendingOps)
    }

    // MARK: Public API

    /// `volunteerForTask`. Every failure is a rejection of the returned promise, as for an async
    /// function.
    public func volunteerForTask(_ taskId: JSString) -> VolunteerPromise {
        let promise = VolunteerPromise()
        do {
            try volunteerForTaskCore(taskId, promise)
        } catch {
            promise.reject(JSString("\(error)"))
        }
        return promise
    }

    private func volunteerForTaskCore(_ taskId: JSString, _ promise: VolunteerPromise) throws {
        try verifyListenersSucceeded()

        // If we are both queued and assigned, then we have the lock and do not have any pending
        // abandon/complete ops. In this case we can resolve true immediately.
        if queuedOptimistically(taskId) && assigned(taskId) {
            promise.resolve(true)
            return
        }

        if readOnlyInfo.readonly {
            if readOnlyInfo.permissions == true {
                throw SharedObjectError("Attempted to volunteer with read-only permissions")
            }
            throw SharedObjectError("Attempted to volunteer in read-only state")
        }

        if isDetached {
            // Simulate auto-ack in detached scenario.
            addClientToQueue(taskId, clientId)
            promise.resolve(true)
            return
        }

        if !connected {
            throw SharedObjectError("Attempted to volunteer in disconnected state")
        }

        // This promise works even if we already have an outstanding volunteer op. If we don't send
        // an op (meaning the latest pending op is "volunteer"), nextPendingMessageId will be
        // greater than that prior "volunteer" op's messageId. This is OK because we only use it to
        // filter stale abandon/complete, and not when determining if we acquired the lock.
        let nextPendingMessageId = self.nextPendingMessageId
        var tokens = VolunteerListenerTokens()

        func removeListeners() {
            if let token = tokens.queue { queueWatcher.off(token) }
            if let token = tokens.abandon { abandonWatcher.off(token) }
            if let token = tokens.disconnect { disconnectWatcher.off(token) }
            if let token = tokens.completed { completedWatcher.off(token) }
            if let token = tokens.rollback { rollbackWatcher.off(token) }
        }

        tokens.queue = queueWatcher.on { [unowned self] change in
            guard change.taskId == taskId else {
                return
            }
            // Also check pending ops here because it's possible we are currently in the queue from
            // a previous lock attempt, but have an outstanding abandon AND the outstanding
            // volunteer for this lock attempt. If we reach the head of the queue based on the
            // previous lock attempt, we don't want to resolve.
            if assigned(taskId) {
                removeListeners()
                promise.resolve(true)
            }
        }

        tokens.abandon = abandonWatcher.on { eventTaskId, messageId in
            guard eventTaskId == taskId else {
                return
            }
            if let messageId, messageId <= nextPendingMessageId {
                // Ignore abandon events that were for abandon ops that were sent prior to our
                // current volunteer attempt.
                return
            }
            removeListeners()
            promise.reject("Abandoned before acquiring task assignment")
        }

        tokens.disconnect = disconnectWatcher.on { [unowned self] in
            do {
                try abandon(taskId)
            } catch {
                promise.reject(JSString("\(error)"))
                listenerFailure = listenerFailure ?? SharedObjectError("\(error)")
            }
            removeListeners()
            promise.reject("Disconnected before acquiring task assignment")
        }

        tokens.completed = completedWatcher.on { eventTaskId, messageId in
            guard eventTaskId == taskId else {
                return
            }
            if let messageId, messageId <= nextPendingMessageId {
                // Ignore completed events for ops that were sent prior to our current volunteer
                // attempt.
                return
            }
            removeListeners()
            promise.resolve(false)
        }

        tokens.rollback = rollbackWatcher.on { eventTaskId in
            guard eventTaskId == taskId else {
                return
            }
            removeListeners()
            promise.resolve(false)
        }

        if !queuedOptimistically(taskId) {
            // Only send the volunteer op if we are not already queued.
            try submitOp(.volunteer, taskId)
        }
    }

    public func subscribeToTask(_ taskId: JSString) throws {
        try verifyListenersSucceeded()

        if subscribed(taskId) {
            return
        }

        if readOnlyInfo.readonly && readOnlyInfo.permissions == true {
            throw SharedObjectError("Attempted to subscribe with read-only permissions")
        }

        let subscription = Subscription()
        var tokens = SubscriptionListenerTokens()

        func submitVolunteerOp() throws {
            subscription.volunteerOpMessageId = nextPendingMessageId
            try submitOp(.volunteer, taskId)
        }

        func removeListeners() {
            if let token = tokens.abandon { abandonWatcher.off(token) }
            if let token = tokens.disconnect { disconnectWatcher.off(token) }
            if let token = tokens.completed { completedWatcher.off(token) }
            if let token = tokens.rollback { rollbackWatcher.off(token) }
        }

        func unsubscribe() {
            removeListeners()
            subscribedTasks.remove(taskId)
            subscription.abandoned = true
        }

        tokens.abandon = abandonWatcher.on { eventTaskId, messageId in
            guard eventTaskId == taskId else {
                return
            }
            // abandonWatcher emits twice for a local abandon() call. When initially called it will
            // emit with undefined messageId. It will emit a second time when the op is ack'd and
            // processed, this time with the messageId for the ack. This condition ensures we don't
            // ignore the initial abandon() emit and only ignore emits associated with ack'd
            // abandon ops that were sent prior to the current volunteer attempt.
            if let messageId, let volunteerOpMessageId = subscription.volunteerOpMessageId,
                messageId <= volunteerOpMessageId
            {
                return
            }
            unsubscribe()
        }

        tokens.disconnect = disconnectWatcher.on { [unowned self] in
            // If we are disconnected and have not already sent a volunteer op, then we should
            // submit another volunteer op while disconnected. This will allow the op to be picked
            // up by reSubmitCore() and resubmitted when we reconnect.
            if !queuedOptimistically(taskId) {
                do {
                    try submitVolunteerOp()
                } catch {
                    listenerFailure = listenerFailure ?? SharedObjectError("\(error)")
                }
            }
        }

        tokens.completed = completedWatcher.on { eventTaskId, messageId in
            guard eventTaskId == taskId else {
                return
            }
            if let messageId, let volunteerOpMessageId = subscription.volunteerOpMessageId,
                messageId <= volunteerOpMessageId
            {
                // Ignore completed events for ops that were sent prior to our current volunteer
                // attempt.
                return
            }
            unsubscribe()
        }

        tokens.rollback = rollbackWatcher.on { eventTaskId in
            guard eventTaskId == taskId else {
                return
            }
            unsubscribe()
        }

        if isDetached {
            // Simulate auto-ack in detached scenario.
            addClientToQueue(taskId, clientId)
            // Because we volunteered with placeholderClientId, we need to wait for when we attach
            // and are assigned a real clientId. At that point we should re-enter the queue with a
            // real volunteer op (assuming we are connected).
            attachedWatcher.once { [unowned self] in
                // We call scrubClientsNotInQuorum() in case our clientId changed during the attach
                // process.
                scrubClientsNotInQuorum()
                // Make sure abandon() was not called while we were detached.
                if !subscription.abandoned {
                    do {
                        try submitVolunteerOp()
                    } catch {
                        listenerFailure = listenerFailure ?? SharedObjectError("\(error)")
                    }
                }
            }
        } else if !queuedOptimistically(taskId) {
            // We don't need to send a second volunteer op if we just sent one.
            try submitVolunteerOp()
        }
        subscribedTasks.insert(taskId)
    }

    public func abandon(_ taskId: JSString) throws {
        try verifyListenersSucceeded()

        // Always allow abandon if the client is subscribed to allow clients to unsubscribe while
        // disconnected. Otherwise, we should check to make sure the client is optimistically
        // queued for the task before trying to abandon.
        if !queuedOptimistically(taskId) && !subscribed(taskId) {
            // Nothing to do.
            return
        }

        if isDetached {
            // Simulate auto-ack in detached scenario.
            removeClientFromQueue(taskId, clientId)
            abandonWatcher.emit((taskId, nil))
            return
        }

        try submitOp(.abandon, taskId)
        abandonWatcher.emit((taskId, nil))
    }

    public func assigned(_ taskId: JSString) -> Bool {
        if isAttached && !connected {
            return false
        }

        guard let currentAssignee = taskQueues.get(taskId)?.first else {
            return false
        }
        return currentAssignee == clientId
    }

    public func queued(_ taskId: JSString) -> Bool {
        if isAttached && !connected {
            return false
        }

        return taskQueues.get(taskId)?.contains(clientId) ?? false
    }

    public func subscribed(_ taskId: JSString) -> Bool {
        subscribedTasks.contains(taskId)
    }

    public func complete(_ taskId: JSString) throws {
        try verifyListenersSucceeded()

        if !assigned(taskId) {
            throw SharedObjectError("Attempted to mark task as complete while not being assigned")
        }

        // If we are detached we will simulate auto-ack for the complete op. Therefore we only need
        // to send the op if we are attached. Additionally, we don't need to check if we are
        // connected while detached.
        if isDetached {
            taskQueues.delete(taskId)
            completedWatcher.emit((taskId, nil))
            completedEvent?(taskId)
            return
        }

        if !connected {
            throw SharedObjectError("Attempted to complete task in disconnected state")
        }
        try submitOp(.complete, taskId)
    }

    public func canVolunteer() -> Bool {
        // A client can volunteer for a task if it's both connected to the delta stream and in write
        // mode. `connected` reflects that condition, but is unintuitive and may be changed in the
        // future. This API allows us to make changes to `connected` without affecting our guidance
        // on how to check if a client is eligible to volunteer for a task.
        connected
    }

    // MARK: Summary and load

    /// `summarizeCore`: a single `header` blob, `JSON.stringify([...filteredMap.entries()])`.
    public override func summarize() -> SummaryTree {
        if let runtimeClientId = runtime?.clientId {
            // The runtime has been assigned an actual clientId by now, so we can replace the
            // placeholder clientIds and maintain the task assignment.
            replacePlaceholderInAllQueues(runtimeClientId)
        } else {
            // If the runtime has still not been assigned a clientId, we should not summarize with
            // the placeholder clientIds and instead remove them from the queues and require the
            // client to re-volunteer when assigned a new clientId.
            removeClientFromAllQueues(placeholderClientId)
        }

        // Only include tasks if there are clients in the queue.
        var content: [JSONValue] = []
        for entry in taskQueues.entries where !entry.value.isEmpty {
            content.append(.array([.string(entry.key), .array(entry.value.map(JSONValue.string))]))
        }
        return .singleBlob(Self.snapshotFileName, JSString(JSON.stringify(.array(content))))
    }

    /// `loadCore`: inserts the stored pairs. TS then scrubs clients that are not in the quorum;
    /// that waits for the runtime's quorum (`onConnect`).
    public override func loadCore(_ summary: SummaryTree) throws {
        for entry in try summary.readAndParse(Self.snapshotFileName).asArray() {
            let pair = try entry.asArray()
            guard pair.count == 2 else {
                throw JSONDecodingError("expected [taskId, clientIdQueue]")
            }
            taskQueues.set(
                try pair[0].asString(), try pair[1].asArray().map { try $0.asString() })
        }
        scrubOnConnect = true
    }

    public override func didAttach() {
        attachedWatcher.emit(())
    }

    /// Joins the runtime's quorum once connected (TS subscribes in the constructor, where the
    /// runtime is already known), and finishes a load.
    public override func onConnect() {
        guard let runtime else {
            return
        }
        if scrubOnConnect {
            scrubOnConnect = false
            scrubClientsNotInQuorum()
        }
        if quorumSubscription == nil {
            quorumSubscription = runtime.getQuorum().onRemoveMember { [weak self] clientId in
                self?.removeClientFromAllQueues(clientId)
            }
        }
    }

    public override func onDisconnect() {
        disconnectWatcher.emit(())
    }

    // MARK: Op processing

    /// Override resubmit core to avoid resubmission on reconnect. On disconnect we accept our
    /// removal from the queues, and leave it up to the user to decide whether they want to attempt
    /// to re-enter a queue on reconnect. However, we do need to update latestPendingOps to account
    /// for the ops we will no longer be processing.
    public override func reSubmitCore(_ content: JSONValue, localOpMetadata: Int) throws {
        let (type, taskId) = try Self.taskManagerOperation(content)
        guard var pendingOps = latestPendingOps.get(taskId) else {
            throw SharedObjectError("0xc42: No pending ops for task on resubmit attempt")
        }
        guard
            let pendingOpIndex = pendingOps.firstIndex(where: {
                $0.messageId == localOpMetadata && $0.type == type
            })
        else {
            throw SharedObjectError("0xc43: Could not match pending op on resubmit attempt")
        }
        pendingOps.remove(at: pendingOpIndex)
        latestPendingOps.set(taskId, pendingOps)
        if type == .volunteer && pendingOps.last?.type != .abandon {
            try submitOp(.volunteer, taskId)
        }
        if latestPendingOps.get(taskId)?.isEmpty == true {
            latestPendingOps.delete(taskId)
        }
    }

    public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
        for content in contents {
            try processMessage(content.message, content.metadata, local)
        }
    }

    private func processMessage(_ message: SequencedMessage, _ messageId: Int?, _ local: Bool) throws
    {
        guard message.type == MessageType.operation else {
            return
        }
        let op = message.contents
        switch try op.member("type").asString() {
        case "volunteer":
            let taskId = try op.member("taskId").asString()
            if local {
                try shiftPendingOp(taskId, messageId, .volunteer, ("0xc3c", "0xc3d", "0x07c"))
            }
            addClientToQueue(taskId, message.clientId)
        case "abandon":
            let taskId = try op.member("taskId").asString()
            if local {
                try shiftPendingOp(taskId, messageId, .abandon, ("0xc3e", "0xc3f", "0x07e"))
                abandonWatcher.emit((taskId, messageId))
            }
            removeClientFromQueue(taskId, message.clientId)
        case "complete":
            let taskId = try op.member("taskId").asString()
            if local {
                try shiftPendingOp(taskId, messageId, .complete, ("0xc40", "0xc41", "0x401"))
            }
            taskQueues.delete(taskId)
            completedWatcher.emit((taskId, messageId))
            completedEvent?(taskId)
        default:
            throw SharedObjectError("Unknown operation")
        }
    }

    /// The local branch of the op handlers: the acknowledged op must be the oldest pending one for
    /// its task. `codes` are the asserts for no pending ops, an unexpected op and a wrong type.
    private func shiftPendingOp(
        _ taskId: JSString, _ messageId: Int?, _ type: TaskManagerOperationType,
        _ codes: (noPending: String, unexpected: String, wrongType: String)
    ) throws {
        guard var pendingOps = latestPendingOps.get(taskId) else {
            throw SharedObjectError("\(codes.noPending): No pending ops for task")
        }
        guard !pendingOps.isEmpty, pendingOps[0].messageId == messageId else {
            throw SharedObjectError("\(codes.unexpected): Unexpected op")
        }
        let pendingOp = pendingOps.removeFirst()
        guard pendingOp.type == type else {
            throw SharedObjectError("\(codes.wrongType): Unexpected op type")
        }
        if pendingOps.isEmpty {
            latestPendingOps.delete(taskId)
        } else {
            latestPendingOps.set(taskId, pendingOps)
        }
    }

    // MARK: Queues

    private func addClientToQueue(_ taskId: JSString, _ clientId: JSString) {
        // Ensure that the clientId exists in the quorum, or it is placeholderClientId (detached
        // scenario).
        guard
            runtime?.getQuorum().getMember(clientId) != nil || self.clientId == placeholderClientId
        else {
            return
        }

        // Create the queue if it doesn't exist, and push the client on the back.
        var clientQueue = taskQueues.get(taskId) ?? []
        if clientQueue.contains(clientId) {
            // We shouldn't re-add the client if it's already in the queue. This may be possible in
            // scenarios where a client was added in while detached.
            taskQueues.set(taskId, clientQueue)
            return
        }

        let oldLockHolder = clientQueue.first
        clientQueue.append(clientId)
        taskQueues.set(taskId, clientQueue)
        let newLockHolder = clientQueue.first
        if newLockHolder != oldLockHolder {
            queueWatcher.emit(
                QueueChange(
                    taskId: taskId, oldLockHolder: oldLockHolder, newLockHolder: newLockHolder))
        }
    }

    private func removeClientFromQueue(_ taskId: JSString, _ clientId: JSString) {
        guard var clientQueue = taskQueues.get(taskId) else {
            return
        }

        let oldLockHolder = clientId == placeholderClientId ? placeholderClientId : clientQueue.first
        if let clientIdIndex = clientQueue.firstIndex(of: clientId) {
            clientQueue.remove(at: clientIdIndex)
            // Clean up the queue if there are no more clients in it.
            if clientQueue.isEmpty {
                taskQueues.delete(taskId)
            } else {
                taskQueues.set(taskId, clientQueue)
            }
        }
        let newLockHolder = clientQueue.first
        if newLockHolder != oldLockHolder {
            queueWatcher.emit(
                QueueChange(
                    taskId: taskId, oldLockHolder: oldLockHolder, newLockHolder: newLockHolder))
        }
    }

    private func removeClientFromAllQueues(_ clientId: JSString) {
        for taskId in taskQueues.keys {
            removeClientFromQueue(taskId, clientId)
        }
    }

    /// Will replace all instances of the placeholderClientId with the current clientId. This should
    /// only be called when transitioning from detached to attached and the runtime has a clientId.
    private func replacePlaceholderInAllQueues(_ runtimeClientId: JSString) {
        for entry in taskQueues.entries {
            var clientQueue = entry.value
            guard let clientIdIndex = clientQueue.firstIndex(of: placeholderClientId) else {
                continue
            }
            if clientQueue.contains(runtimeClientId) {
                // If the real clientId is already in the queue, just remove the placeholder.
                clientQueue.remove(at: clientIdIndex)
            } else {
                clientQueue[clientIdIndex] = runtimeClientId
            }
            taskQueues.set(entry.key, clientQueue)
        }
    }

    // This seems like it should be unnecessary if we can trust to receive the join/leave messages
    // and also have an accurate snapshot.
    private func scrubClientsNotInQuorum() {
        guard let quorum = runtime?.getQuorum() else {
            return
        }
        for entry in taskQueues.entries {
            let filteredClientQueue = entry.value.filter { quorum.getMember($0) != nil }
            if entry.value.count != filteredClientQueue.count {
                if filteredClientQueue.isEmpty {
                    taskQueues.delete(entry.key)
                } else {
                    taskQueues.set(entry.key, filteredClientQueue)
                }
                queueWatcher.emit(
                    QueueChange(taskId: entry.key, oldLockHolder: nil, newLockHolder: nil))
            }
        }
    }

    /// Checks whether this client is currently assigned or in queue to become assigned, while also
    /// accounting for the latest pending ops.
    private func queuedOptimistically(_ taskId: JSString) -> Bool {
        let inQueue = taskQueues.get(taskId)?.contains(clientId) ?? false
        let latestPendingOp = latestPendingOps.get(taskId)?.last
        let isPendingVolunteer = latestPendingOp?.type == .volunteer
        let isPendingAbandonOrComplete =
            latestPendingOp?.type == .abandon || latestPendingOp?.type == .complete
        // We return true if the client is either in queue already or the latest pending op for this
        // task is a volunteer op. But we should always return false if the latest pending op is an
        // abandon or complete op.
        return (inQueue && !isPendingAbandonOrComplete) || isPendingVolunteer
    }

    /// Returns true if the client is detached. This is distinct from `!isAttached` because
    /// `isAttached` also checks the channel is bound; `isDetached` decides whether to simulate
    /// auto-ack, which is concerned with whether we have been assigned a real clientId yet.
    private var isDetached: Bool {
        attachState == .detached
    }

    // MARK: Stash and rollback

    /// We don't apply any stashed ops since during the rehydration process we lose any assigned
    /// tasks, so we cannot be assigned any tasks. Additionally, without the in-memory state of the
    /// previous DDS, we also cannot re-volunteer based on a previous subscribeToTask() call.
    public override func applyStashedOp(_ content: JSONValue) throws {}

    public override func rollback(_ content: JSONValue, localOpMetadata: Int) throws {
        let (_, taskId) = try Self.taskManagerOperation(content)
        guard var latestPendingOps = self.latestPendingOps.get(taskId) else {
            throw SharedObjectError("0xc46: No pending ops when trying to rollback")
        }
        guard let pendingOpToRollback = latestPendingOps.popLast(),
            pendingOpToRollback.messageId == localOpMetadata
        else {
            throw SharedObjectError("0xc47: pending op mismatch")
        }
        if latestPendingOps.isEmpty {
            self.latestPendingOps.delete(taskId)
        } else {
            self.latestPendingOps.set(taskId, latestPendingOps)
        }
        rollbackWatcher.emit(taskId)
    }

    /// `assertIsTaskManagerOperation` (0xc3b): an object with a string `taskId` and a known `type`.
    private static func taskManagerOperation(_ op: JSONValue) throws -> (
        TaskManagerOperationType, JSString
    ) {
        guard case .object(let object) = op,
            case .string(let taskId)? = object["taskId"],
            case .string(let type)? = object["type"],
            let operationType = TaskManagerOperationType(rawValue: type.description)
        else {
            throw SharedObjectError("0xc3b: Not a TaskManager operation")
        }
        return (operationType, taskId)
    }
}

/// The listeners one `volunteerForTask` call installs, so settling can remove all of them.
private struct VolunteerListenerTokens {
    var queue: Int?
    var abandon: Int?
    var disconnect: Int?
    var completed: Int?
    var rollback: Int?
}

/// The listeners one `subscribeToTask` call installs.
private struct SubscriptionListenerTokens {
    var abandon: Int?
    var disconnect: Int?
    var completed: Int?
    var rollback: Int?
}

/// The `volunteerOpMessageId` and `abandoned` locals of `subscribeToTask`, shared by its listeners.
private final class Subscription {
    var volunteerOpMessageId: Int?
    var abandoned = false
}
