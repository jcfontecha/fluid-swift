import FluidDriverDefinitions
import FluidJS
import FluidTaskManager
import FluidTestRuntimeUtils

// TaskManager adapter, as `harness/src/dds.ts` createAdapter defines it for `task-manager`.

/// The tasks `queries` reports, in the TS adapter's order.
private let taskIdPool: [JSString] = ["a", "b", "c"]

/// The only rejections of `volunteerForTask` the TS adapter tolerates.
private let toleratedVolunteerRejections: [JSString] = [
  "Disconnected before acquiring task assignment",
  "Abandoned before acquiring task assignment",
]

func taskManagerAdapter(
  _ runtime: MockContainerRuntime<TaskManagerClass>
) -> RuntimeClient<TaskManagerClass> {
  let client = RuntimeClient(
    runtime,
    edit: { c, e in
      let key = try e.member("key").asString()
      switch try e.member("kind").asString() {
      case "volunteer":
        let promise = c.volunteerForTask(key)
        if case .rejected(let message) = promise.state,
          !toleratedVolunteerRejections.contains(message)
        {
          throw PeerError(description: message.description)
        }
      case "subscribe":
        try c.subscribeToTask(key)
      case "abandon":
        try c.abandon(key)
      case "complete":
        // The upstream reducer tolerates only this completion failure.
        do {
          try c.complete(key)
        } catch {
          guard "\(error)" == "Attempted to complete task in disconnected state" else {
            throw error
          }
        }
      default:
        throw PeerError(description: "invalid edit")
      }
    },
    state: { c in
      try taskManagerQueues(c)
    },
    queries: { c in
      var queries = JSObject<JSONValue>()
      queries["canVolunteer"] = .bool(c.canVolunteer())
      queries["tasks"] = .array(
        taskIdPool.map { key in
          var task = JSObject<JSONValue>()
          task["key"] = .string(key)
          task["assigned"] = .bool(c.assigned(key))
          task["queued"] = .bool(c.queued(key))
          task["subscribed"] = .bool(c.subscribed(key))
          return .object(task)
        })
      return .object(queries)
    })
  runtime.channel.assignedEvent = { [weak client] key in
    client?.events.append(.array([.string("assigned"), .string(key)]))
  }
  runtime.channel.lostEvent = { [weak client] key in
    client?.events.append(.array([.string("lost"), .string(key)]))
  }
  runtime.channel.completedEvent = { [weak client] key in
    client?.events.append(.array([.string("completed"), .string(key)]))
  }
  return client
}

/// The non-empty queues of the `header` summary blob, sorted by task ID. The TS adapter sorts with
/// `localeCompare`; task IDs here are the ASCII letters `a`, `b` and `c`, where it agrees with
/// UTF-16 order.
private func taskManagerQueues(_ c: TaskManagerClass) throws -> JSONValue {
  guard case .tree(let tree) = c.summarize(), let blob = tree.tree["header"] else {
    throw PeerError(description: "Missing task header")
  }
  let queues = try JSON.parse(blob.json.member("content").asString().description).asArray()
  let sorted = try queues.sorted {
    try $0.asArray()[0].asString().utf16.lexicographicallyPrecedes(
      $1.asArray()[0].asString().utf16)
  }
  return .array(sorted)
}
