import FluidDriverDefinitions
import FluidJS
import FluidOrderedCollection
import FluidSharedObjectBase
import FluidTestRuntimeUtils
import Testing

/// Port of `packages/dds/ordered-collection/src/test/consensusOrderedCollection.spec.ts`, the `generate` suite
/// run for a detached and an attached collection (`describe("Detached")`, `describe("Attached, connected")`).
@Suite("ConsensusQueue")
struct ConsensusQueueTests {
  @Test("Can create a collection", arguments: Connection.allCases)
  func canCreateACollection(_ connection: Connection) throws {
    let under = makeCollection(connection)
    #expect(under.collection.isAttached == (connection == .attached))
  }

  @Test("Can add and remove data", arguments: Connection.allCases)
  func canAddAndRemoveData(_ connection: Connection) throws {
    let under = makeCollection(connection)
    #expect(try removeItem(under) == nil)
    try addItem(under, str("testValue"))
    #expect(try removeItem(under) == str("testValue"))
    #expect(try removeItem(under) == nil)
  }

  @Test("Can add and remove a handle", arguments: Connection.allCases)
  func canAddAndRemoveAHandle(_ connection: Connection) throws {
    let under = makeCollection(connection)
    #expect(try removeItem(under) == nil)
    let handle = FluidValue.handle(FluidHandle(absolutePath: "/handles/a"))
    try addItem(under, handle)
    #expect(try removeItem(under) == handle)
    #expect(try removeItem(under) == nil)
  }

  @Test("Can add and release data", arguments: Connection.allCases)
  func canAddAndReleaseData(_ connection: Connection) throws {
    let under = makeCollection(connection)
    var released: [(FluidValue, Bool)] = []
    under.collection.localReleaseEvent = { value, intentional in released.append((value, intentional)) }
    try addItem(under, str("testValue"))
    var seen: FluidValue?
    try under.collection.acquire({ value in
      seen = value
      return .release
    })
    try under.processMessages()
    #expect(seen == str("testValue"))
    #expect(released.count == 1)
    #expect(released.first?.0 == str("testValue"))
    #expect(released.first?.1 == true)
    #expect(try removeItem(under) == str("testValue"))
    #expect(try removeItem(under) == nil)
  }

  @Test("Can wait for data", arguments: Connection.allCases)
  func canWaitForData(_ connection: Connection) throws {
    let under = makeCollection(connection)
    var addEventFired = false
    under.collection.addEvent = { _, _ in addEventFired = true }
    var received: FluidValue?
    var settled = false
    try under.collection.waitAndAcquire(
      { value in
        #expect(addEventFired, "Wait resolved before value is added")
        received = value
        return .complete
      },
      onSettled: { settled = true })
    try under.collection.add(str("testValue"), onSettled: {})
    try under.processMessages()
    #expect(received == str("testValue"))
    #expect(settled)
  }

  @Test("Data ordering", arguments: Connection.allCases)
  func dataOrdering(_ connection: Connection) throws {
    let under = makeCollection(connection)
    for item in [num(1), num(2)] {
      try addItem(under, item)
    }
    #expect(try removeItem(under) == num(1))
    #expect(try removeItem(under) == num(2))
    #expect(try removeItem(under) == nil)
  }

  @Test("Event", arguments: Connection.allCases)
  func events(_ connection: Connection) throws {
    let under = makeCollection(connection)
    var added: [FluidValue] = []
    var acquired: [FluidValue] = []
    under.collection.addEvent = { value, _ in added.append(value) }
    under.collection.acquireEvent = { value, _ in acquired.append(value) }
    for item in [num(1), num(2)] {
      try addItem(under, item)
    }
    try under.processMessages()
    _ = try removeItem(under)
    _ = try removeItem(under)
    #expect(try removeItem(under) == nil)
    #expect(added == [num(1), num(2)])
    #expect(acquired == [num(1), num(2)])
  }

  @Test("can clone object value", arguments: Connection.allCases)
  func canCloneObjectValue(_ connection: Connection) throws {
    let under = makeCollection(connection)
    var object = JSObject<FluidValue>()
    object["x"] = num(1)
    try addItem(under, .object(object))
    #expect(try removeItem(under) == .object(object))
  }

  @Test("acquire on an empty queue returns false without running the callback")
  func acquireOnEmptyReturnsFalse() throws {
    let under = makeCollection(.attached)
    var ran = false
    var acquired: Bool?
    try under.collection.acquire(
      { _ in
        ran = true
        return .complete
      },
      onSettled: { acquired = $0 })
    try under.processMessages()
    #expect(!ran)
    #expect(acquired == false)
  }

  @Test("waitAndAcquire on a detached collection acquires once a value is added")
  func detachedWaitAndAcquire() throws {
    let under = makeCollection(.detached)
    var received: FluidValue?
    try under.collection.waitAndAcquire({ value in
      received = value
      return .complete
    })
    #expect(received == nil)
    try under.collection.add(str("late"))
    #expect(received == str("late"))
  }
}
