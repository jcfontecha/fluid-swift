import FluidCounter
import FluidJS
import FluidTestRuntimeUtils
import Testing

@Test func reconnectResubmitsWithoutReapplying() throws {
  let c = SharedCounter(id: "c")
  let runtime = MockContainerRuntime(clientId: "old", channel: c, lastSequenceNumber: 0)
  runtime.disconnect()
  try c.increment(9)
  #expect(runtime.takeOutbound().isEmpty)
  try runtime.reconnect(clientId: "new")
  let ops = runtime.takeOutbound()
  #expect(c.value == 9)
  #expect(ops.count == 1)
  #expect(ops[0].clientId == "new")
  #expect(ops[0].clientSequenceNumber == 1)
}
@Test func turnBasedRollbackDoesNotSend() throws {
  let c = SharedCounter(id: "c")
  let runtime = MockContainerRuntime(
    clientId: "old", channel: c, lastSequenceNumber: 0, flushMode: .turnBased)
  try c.increment(7)
  #expect(runtime.takeOutbound().isEmpty)
  try runtime.rollback()
  #expect(c.value == 0)
  try c.increment(3)
  runtime.flush()
  #expect(runtime.takeOutbound().count == 1)
}
