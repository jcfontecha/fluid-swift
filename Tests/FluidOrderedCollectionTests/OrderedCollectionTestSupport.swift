import FluidDriverDefinitions
import FluidJS
import FluidOrderedCollection
import FluidSharedObjectBase
import FluidTestRuntimeUtils

/// The modes TS `consensusOrderedCollection.spec.ts` runs its `generate` suite under.
enum Connection: CaseIterable, Sendable {
  case detached
  case attached
}

/// The collection under test, and how its outstanding messages are delivered (TS `processMessages`).
struct CollectionUnderTest {
  let collection: ConsensusQueue
  let factory: MockContainerRuntimeFactory<ConsensusQueue>?

  func processMessages() throws {
    try factory?.processAllMessages()
  }
}

func makeCollection(_ connection: Connection) -> CollectionUnderTest {
  switch connection {
  case .detached:
    return CollectionUnderTest(collection: ConsensusQueue(id: "consensus-ordered-collection"), factory: nil)
  case .attached:
    let factory = MockContainerRuntimeFactory<ConsensusQueue>()
    let queue = ConsensusQueue(id: "consensus-ordered-collection")
    _ = factory.createContainerRuntime(clientId: "A", channel: queue)
    return CollectionUnderTest(collection: queue, factory: factory)
  }
}

func str(_ value: String) -> FluidValue {
  .json(.string(JSString(value)))
}

func num(_ value: Double) -> FluidValue {
  .json(.number(value))
}

func addItem(_ under: CollectionUnderTest, _ value: FluidValue) throws {
  try under.collection.add(value)
  try under.processMessages()
}

/// TS `acquireAndComplete` followed by `processMessages`: returns the item, or nil when the queue is empty.
func removeItem(_ under: CollectionUnderTest) throws -> FluidValue? {
  var acquired: FluidValue?
  try under.collection.acquire({ value in
    acquired = value
    return .complete
  })
  try under.processMessages()
  return acquired
}

/// The text of a top-level summary blob, byte for byte (`tree.<name>.content`).
func blobContent(_ summary: SummaryTree, _ name: JSString) throws -> String {
  try summary.json.member("tree").member(name).member("content").asString().description
}
