import Testing
import FluidJS
@testable import FluidSequence

/// Ports sequence/src/test/sharedString.spec.ts:90-124,351-362.
struct SharedStringTests {
  @Test func insertion() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "hello")
    #expect(text.getText() == "hello")
    try text.insertText(5, "world")
    #expect(text.getText() == "helloworld")
    try text.insertText(5, " ")
    #expect(text.getText() == "hello world")
  }
  @Test func replacement() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "hello world")
    try text.replaceText(6, 11, "there!")
    #expect(text.getText() == "hello there!")
    try text.replaceText(0, 5, "hi")
    #expect(text.getText() == "hi there!")
  }
  @Test func removal() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "hello world")
    try text.removeText(5, 11)
    #expect(text.getText() == "hello")
    try text.removeText(0, 3)
    #expect(text.getText() == "lo")
  }
  @Test func zeroAndReverseReplacement() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "123")
    try text.replaceText(1, 1, "äÄ")
    #expect(text.getText() == "1äÄ23")
    let reverse = SharedString(id: "reverse")
    try reverse.insertText(0, "123")
    try reverse.replaceText(2, 1, "aaa")
    #expect(reverse.getText() == "12aaa3")
  }
  // sequence.ts replaceRange removes only when insertion returned an op.
  @Test func emptyReplacementDoesNotRemove() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "abc")
    try text.replaceText(0, 3, "")
    #expect(text.getText() == "abc")
  }
  @Test func surrogateHalfRemoval() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "A😀B")
    #expect(text.getLength() == 4)
    try text.removeText(1, 2)
    #expect(text.getText().utf16 == [65, 0xde00, 66])
  }
}

extension SharedStringTests {
  @Test func insertionDropsNullPropertiesBeforeSubmitting() throws {
    let text = SharedString(id: "channel")
    var props = JSObject<JSONValue>()
    props["color"] = .null
    let op = try #require(try text.insertText(0, "x", properties: props))
    #expect(try op.member("seg").member("props").asObject().isEmpty)
    #expect(text.getPropertiesAtPosition(0)?.isEmpty == true)
  }
}
