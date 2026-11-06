import FluidJS
import FluidSequence
import Testing

@testable import Fluid

@MainActor
struct SharedStringTests {
    @Test func editsUseUTF16Offsets() throws {
        let text = Fluid.SharedString.kind.make("text")
        text.insert("héllo", at: 0)
        text.insert("👋 ", at: 0)
        #expect(text.string == "👋 héllo")
        #expect(text.utf16Count == 8)
        text.remove(0..<3)
        #expect(text.string == "héllo")
        text.replace(1..<2, with: "e")
        #expect(text.string == "hello")
        text.replace(0..<1, with: "")
        #expect(text.string == "ello")
    }

    /// A TS client can leave a lone surrogate; it reads as U+FFFD, one unit, so offsets line up.
    @Test func loneSurrogateReadsAsReplacementOfTheSameLength() throws {
        let port = FluidSequence.SharedString(id: "text")
        try port.insertText(0, JSString(utf16: [0x61, 0xD83D, 0x62]))
        let text = try #require(Fluid.SharedString.kind.adopt(port))
        #expect(text.string == "a\u{FFFD}b")
        #expect(text.string.utf16.count == text.utf16Count)
        text.insert("c", at: 3)
        #expect(port.getText() == JSString(utf16: [0x61, 0xD83D, 0x62, 0x63]))
    }

    /// The setter replaces only the changed middle, so concurrent edits elsewhere survive.
    @Test func stringSetterAppliesOneMinimalEdit() throws {
        let strings = try TwoStrings()
        strings.a.string = "Groceries"
        try strings.sync()
        strings.a.string = "Grocery list"
        strings.b.insert("My ", at: 0)
        try strings.sync()
        #expect(strings.a.string == "My Grocery list")
        #expect(strings.b.string == "My Grocery list")
    }

    /// A surrogate pair is never split: 😀 and 😁 share their lead unit.
    @Test func stringSetterKeepsSurrogatePairsWhole() throws {
        let text = Fluid.SharedString.kind.make("text")
        text.string = "a😀b"
        var changes: [TextChange] = []
        let subscription = text.onChange { changes.append($0) }
        text.string = "a😁b"
        #expect(text.string == "a😁b")
        #expect(changes.flatMap(\.edits) == [.insert("😁", at: 3), .remove(1..<3)])
        _ = subscription
    }

    @Test func onChangeReportsRemoteInsertsAndRemoves() throws {
        let strings = try TwoStrings()
        strings.a.insert("hello world", at: 0)
        try strings.sync()
        var changes: [TextChange] = []
        let subscription = strings.b.onChange { changes.append($0) }
        strings.a.remove(0..<6)
        strings.a.insert("big ", at: 5)
        try strings.sync()
        #expect(changes.map(\.isLocal) == [false, false])
        #expect(changes.map(\.edits) == [[.remove(0..<6)], [.insert("big ", at: 5)]])
        #expect(strings.b.string == "worldbig ")
        _ = subscription
    }

    @Test func onChangeReportsLocalEdits() throws {
        let text = Fluid.SharedString.kind.make("text")
        var changes: [TextChange] = []
        let subscription = text.onChange { changes.append($0) }
        text.insert("x", at: 0)
        #expect(changes.map(\.isLocal) == [true])
        #expect(changes.map(\.edits) == [[.insert("x", at: 0)]])
        _ = subscription
    }

    @Test func releasingTheSubscriptionStopsChanges() throws {
        let text = Fluid.SharedString.kind.make("text")
        var count = 0
        var subscription: Subscription? = text.onChange { _ in count += 1 }
        text.insert("a", at: 0)
        subscription = nil
        text.insert("b", at: 0)
        #expect(count == 1)
        #expect(subscription == nil)
    }

    /// Observation and an editor's handler both receive every change: neither replaces the other.
    @Test func observationAndChangeHandlersCoexist() throws {
        let strings = try TwoStrings()
        let observed = ChangeCounter { _ = strings.b.string }
        var handled = 0
        let first = strings.b.onChange { _ in handled += 1 }
        let second = strings.b.onChange { _ in handled += 10 }
        strings.a.insert("hi", at: 0)
        try strings.sync()
        #expect(observed.count == 1)
        #expect(handled == 11)
        _ = (first, second)
    }

    @Test func observationTracksStringAndCount() throws {
        let text = Fluid.SharedString.kind.make("text")
        let string = ChangeCounter { _ = text.string }
        let count = ChangeCounter { _ = text.utf16Count }
        text.insert("ab", at: 0)
        text.remove(0..<1)
        #expect(string.count == 2)
        #expect(count.count == 2)
    }

    /// An annotation changes no text, so it is neither observed nor reported.
    @Test func annotationsAreNotTextChanges() throws {
        let port = FluidSequence.SharedString(id: "text")
        let text = try #require(Fluid.SharedString.kind.adopt(port))
        text.insert("abc", at: 0)
        let observed = ChangeCounter { _ = text.string }
        var changes = 0
        let subscription = text.onChange { _ in changes += 1 }
        var properties = JSObject<JSONValue>()
        properties["bold"] = .bool(true)
        try port.annotateRange(0, 2, properties)
        #expect(observed.count == 0)
        #expect(changes == 0)
        _ = subscription
    }

    @Test func releasedStringStopsListening() throws {
        let port = FluidSequence.SharedString(id: "text")
        var text = Fluid.SharedString.kind.adopt(port)
        weak let released = text
        text = nil
        #expect(released == nil)
        try port.insertText(0, "still works")
        #expect(port.getText() == "still works")
    }
}
