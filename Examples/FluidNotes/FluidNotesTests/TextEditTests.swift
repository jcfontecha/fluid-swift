import Foundation
import Testing

private func units(_ text: String) -> [UInt16] {
    Array(text.utf16)
}

@Suite struct SelectionTransformTests {
    @Test func insertBeforeCaretShiftsIt() {
        let caret = NSRange(location: 5, length: 0)
        #expect(caret.transformed(by: .insert(location: 2, text: units("abc"))) == NSRange(location: 8, length: 0))
    }

    @Test func insertAfterCaretLeavesIt() {
        let caret = NSRange(location: 5, length: 0)
        #expect(caret.transformed(by: .insert(location: 6, text: units("abc"))) == caret)
    }

    @Test func insertAtCaretLeavesIt() {
        let caret = NSRange(location: 5, length: 0)
        #expect(caret.transformed(by: .insert(location: 5, text: units("abc"))) == caret)
    }

    @Test func insertAtSelectionStartGoesBeforeSelectedText() {
        let selection = NSRange(location: 4, length: 3)
        #expect(selection.transformed(by: .insert(location: 4, text: units("xy"))) == NSRange(location: 6, length: 3))
    }

    @Test func insertAtSelectionEndGoesAfterSelectedText() {
        let selection = NSRange(location: 4, length: 3)
        #expect(selection.transformed(by: .insert(location: 7, text: units("xy"))) == selection)
    }

    @Test func insertInsideSelectionGrowsIt() {
        let selection = NSRange(location: 4, length: 3)
        #expect(selection.transformed(by: .insert(location: 5, text: units("xy"))) == NSRange(location: 4, length: 5))
    }

    @Test func insertLengthCountsUTF16CodeUnits() {
        let caret = NSRange(location: 3, length: 0)
        // "😀" is two UTF-16 code units, as FluidSequence counts it.
        #expect(caret.transformed(by: .insert(location: 0, text: units("😀é"))) == NSRange(location: 6, length: 0))
    }

    @Test func removeBeforeCaretShiftsIt() {
        let caret = NSRange(location: 10, length: 0)
        #expect(caret.transformed(by: .remove(location: 2, length: 3)) == NSRange(location: 7, length: 0))
    }

    @Test func removeAfterCaretLeavesIt() {
        let caret = NSRange(location: 2, length: 0)
        #expect(caret.transformed(by: .remove(location: 2, length: 3)) == caret)
    }

    @Test func removeAroundCaretCollapsesItToRemovalStart() {
        let caret = NSRange(location: 4, length: 0)
        #expect(caret.transformed(by: .remove(location: 2, length: 3)) == NSRange(location: 2, length: 0))
    }

    @Test func removeEndingAtCaretMovesItToRemovalStart() {
        let caret = NSRange(location: 5, length: 0)
        #expect(caret.transformed(by: .remove(location: 2, length: 3)) == NSRange(location: 2, length: 0))
    }

    @Test func removeOverlappingSelectionStartTrimsIt() {
        let selection = NSRange(location: 4, length: 4)
        #expect(selection.transformed(by: .remove(location: 2, length: 4)) == NSRange(location: 2, length: 2))
    }

    @Test func removeOverlappingSelectionEndTrimsIt() {
        let selection = NSRange(location: 4, length: 4)
        #expect(selection.transformed(by: .remove(location: 6, length: 5)) == NSRange(location: 4, length: 2))
    }

    @Test func removeInsideSelectionShrinksIt() {
        let selection = NSRange(location: 4, length: 6)
        #expect(selection.transformed(by: .remove(location: 5, length: 2)) == NSRange(location: 4, length: 4))
    }

    @Test func removeCoveringSelectionCollapsesIt() {
        let selection = NSRange(location: 4, length: 2)
        #expect(selection.transformed(by: .remove(location: 3, length: 5)) == NSRange(location: 3, length: 0))
    }

    @Test func sequentialEditsMatchTheEditedText() {
        // Applying the edits to the text and to the selection must keep the same characters
        // selected: "hello world" with "world" selected.
        let text = NSMutableString(string: "hello world")
        var selection = NSRange(location: 6, length: 5)
        let edits: [TextEdit] = [
            .insert(location: 0, text: units(">> ")),
            .remove(location: 3, length: 6),
            .insert(location: 3, text: units("big ")),
        ]
        for edit in edits {
            switch edit {
            case let .insert(location, inserted):
                text.insert(String(utf16CodeUnits: inserted, count: inserted.count), at: location)
            case let .remove(location, length):
                text.deleteCharacters(in: NSRange(location: location, length: length))
            }
            selection = selection.transformed(by: edit)
        }
        #expect(text as String == ">> big world")
        #expect(text.substring(with: selection) == "world")
    }
}

@Suite struct LocalChangeTests {
    @Test func typingAtEnd() {
        #expect(TextEdit.changes(from: "ab", to: "abc", caret: 3) == [.insert(location: 2, text: units("c"))])
    }

    @Test func typingInsideARunInsertsAtTheCaret() {
        #expect(TextEdit.changes(from: "aa", to: "aaa", caret: 1) == [.insert(location: 0, text: units("a"))])
    }

    @Test func backspaceInsideARunRemovesAtTheCaret() {
        #expect(TextEdit.changes(from: "aaa", to: "aa", caret: 1) == [.remove(location: 1, length: 1)])
    }

    @Test func replacingASelection() {
        #expect(TextEdit.changes(from: "hello world", to: "hello there", caret: 11) == [
            .remove(location: 6, length: 5),
            .insert(location: 6, text: units("there")),
        ])
    }

    @Test func pastingInTheMiddle() {
        #expect(TextEdit.changes(from: "ad", to: "abcd", caret: 3) == [.insert(location: 1, text: units("bc"))])
    }

    @Test func emojiIsTwoCodeUnits() {
        #expect(TextEdit.changes(from: "ab", to: "a😀b", caret: 3) == [.insert(location: 1, text: units("😀"))])
    }

    /// 😀 and 😁 share their lead unit; the edit still replaces the whole pair.
    @Test func replacingAnEmojiKeepsItsSurrogatePairWhole() {
        #expect(TextEdit.changes(from: "a😀b", to: "a😁b", caret: 3) == [
            .remove(location: 1, length: 2),
            .insert(location: 1, text: units("😁")),
        ])
    }

    @Test func noChange() {
        #expect(TextEdit.changes(from: "same", to: "same", caret: 2).isEmpty)
    }

    @Test func clearingEverything() {
        #expect(TextEdit.changes(from: "gone", to: "", caret: 0) == [.remove(location: 0, length: 4)])
    }
}
