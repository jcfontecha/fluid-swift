import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase
import FluidSharedSummaryBlock
import FluidTestRuntimeUtils
import Testing

// Port of packages/dds/shared-summary-block/src/test/sharedSummaryBlock.spec.ts, plus the
// JS-semantics cases from specs/shared-summary-block.md (integer-like keys, __proto__, undefined).

private func jsonObject(_ entries: [(JSString, JSONValue)]) -> JSONValue {
  var object = JSObject<JSONValue>()
  for (key, value) in entries {
    object[key] = value
  }
  return .object(object)
}

/// The exact text of the single `header` blob (`createSingleBlobSummary`).
private func headerText(_ summary: SummaryTree) throws -> JSString {
  guard case .tree(let tree) = summary, tree.tree.keys == ["header"],
    case .blob(let blob)? = tree.tree["header"],
    case .text(let text) = blob.content
  else {
    throw JSONDecodingError("summary is not a single text header blob")
  }
  return text
}

/// The description of the error `body` throws, or nil when it does not throw.
private func thrownDescription(_ body: () throws -> Void) -> String? {
  do {
    try body()
    return nil
  } catch {
    return String(describing: error)
  }
}

private func loadedBlock(_ header: JSString) throws -> SharedSummaryBlockClass {
  try SharedSummaryBlockClass.load(
    id: "loaded", summary: .singleBlob("header", header))
}

@Test func createsEmptyBlock() {
  let block = SharedSummaryBlockClass(id: "root")
  #expect(block.get("testKey1") == nil)
}

@Test func setAndGetReturnStoredValues() {
  let block = SharedSummaryBlockClass(id: "root")

  block.set("testKey1", .string("testValue1"))
  #expect(block.get("testKey1") == .string("testValue1"))

  let value2 = jsonObject([("value", .string("testValue2"))])
  block.set("testKey2", value2)
  #expect(block.get("testKey2") == value2)

  let value3 = jsonObject([
    ("value1", .string("outer string")),
    ("value2", .number(2)),
    ("value3", .array([.bool(true), .bool(false)])),
    (
      "value4",
      jsonObject([
        ("value1", .string("inner string")),
        ("value2", .number(500)),
        ("value3", .array([.bool(false), .bool(false), .bool(true)])),
      ])
    ),
  ])
  block.set("testKey3", value3)
  #expect(block.get("testKey3") == value3)
}

@Test func emptyBlockSummarizesToEmptyObject() throws {
  let block = SharedSummaryBlockClass(id: "root")
  #expect(try headerText(block.summarize()) == "{}")
}

@Test func summaryIsSingleHeaderBlockWithJSONContent() throws {
  let block = SharedSummaryBlockClass(id: "root")
  block.set("testKey1", .string("testValue1"))
  block.set("testKey2", .string("testValue2"))
  block.set("testKey3", jsonObject([("value", .string("testValue3"))]))

  let summary = block.summarize()
  #expect(
    try headerText(summary)
      == #"{"testKey1":"testValue1","testKey2":"testValue2","testKey3":{"value":"testValue3"}}"#)
}

@Test func loadRoundTripsSummary() throws {
  let block = SharedSummaryBlockClass(id: "root")
  block.set("testKey1", .string("testValue1"))
  block.set("testKey2", .string("testValue2"))
  let value3 = jsonObject([("value", .string("testValue3"))])
  block.set("testKey3", value3)

  let loaded = try SharedSummaryBlockClass.load(id: "loaded", summary: block.summarize())
  #expect(loaded.get("testKey1") == .string("testValue1"))
  #expect(loaded.get("testKey2") == .string("testValue2"))
  #expect(loaded.get("testKey3") == value3)
}

@Test func integerLikeKeysFollowJSObjectOrder() throws {
  // Insertion order b, 10, 2, a: array-index keys sort first, numerically.
  let block = SharedSummaryBlockClass(id: "root")
  block.set("b", .number(1))
  block.set("10", .number(10))
  block.set("2", .number(2))
  block.set("a", .number(3))
  #expect(try headerText(block.summarize()) == #"{"2":2,"10":10,"b":1,"a":3}"#)
}

@Test func protoKeyStaysLiveButIsNeverSummarized() throws {
  // summarizeCore assigns with ordinary property assignment: __proto__ sets the prototype for
  // object values and is ignored for primitives, so it never becomes an own property.
  let block = SharedSummaryBlockClass(id: "root")
  let value = jsonObject([("n", .number(1))])
  block.set("__proto__", value)
  #expect(block.get("__proto__") == value)
  #expect(try headerText(block.summarize()) == "{}")

  block.set("__proto__", .number(5))
  #expect(block.get("__proto__") == .number(5))
  #expect(try headerText(block.summarize()) == "{}")
}

@Test func loadedProtoKeyIsLiveUntilNextSummary() throws {
  let block = try loadedBlock(#"{"__proto__":5,"a":1}"#)
  #expect(block.get("__proto__") == .number(5))
  #expect(block.get("a") == .number(1))
  #expect(try headerText(block.summarize()) == #"{"a":1}"#)
}

@Test func undefinedValueIsOmittedButKeepsMapPosition() throws {
  // Map.set on an existing key keeps its position, so the re-set "a" still precedes "b".
  let block = SharedSummaryBlockClass(id: "root")
  block.set("a", .number(1))
  block.set("b", .number(2))
  block.set("a", nil)
  #expect(block.get("a") == nil)
  #expect(try headerText(block.summarize()) == #"{"b":2}"#)

  block.set("a", .number(5))
  #expect(try headerText(block.summarize()) == #"{"a":5,"b":2}"#)

  block.set("b", nil)
  #expect(try headerText(block.summarize()) == #"{"a":5}"#)
}

@Test func loadedHeaderOrderFollowsObjectEntries() throws {
  let block = try loadedBlock(#"{"b":1,"10":10,"a":3,"2":2}"#)
  #expect(try headerText(block.summarize()) == #"{"2":2,"10":10,"b":1,"a":3}"#)
}

@Test func processingAnyOpThrows() {
  let block = SharedSummaryBlockClass(id: "root")
  #expect(
    thrownDescription { try block.processMessages([], local: false) }
      == "shared summary block should not generate any ops.")
}

@Test func applyStashedOpThrows() {
  let block = SharedSummaryBlockClass(id: "root")
  #expect(
    thrownDescription { try block.applyStashedOp(.null) } == "not implemented")
}

@Test func setSubmitsNothing() {
  let block = SharedSummaryBlockClass(id: "root")
  let runtime = MockContainerRuntime(
    clientId: "client", channel: block, lastSequenceNumber: 0)
  block.set("testKey1", .string("testValue1"))
  #expect(runtime.takeOutbound().isEmpty)
}
