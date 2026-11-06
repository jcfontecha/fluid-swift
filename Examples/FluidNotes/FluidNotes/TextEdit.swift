import Foundation

/// One plain-text edit in UTF-16 code units, the unit of FluidSequence positions and of
/// `NSString`/`UITextView` ranges. Insert text stays UTF-16 because a SharedString may hold a
/// lone surrogate, which Swift `String` cannot represent.
enum TextEdit: Equatable, Sendable {
    case insert(location: Int, text: [UInt16])
    case remove(location: Int, length: Int)

    /// The single local edit that turns `old` into `new`. The edit ends at `caret` in `new`
    /// whenever that is consistent, so typing a repeated character ("aa" → "aaa" with the caret
    /// at 1) inserts where the user typed, not at the end of the run.
    static func changes(from old: NSString, to new: NSString, caret: Int) -> [TextEdit] {
        let oldLength = old.length
        let newLength = new.length
        let shared = min(oldLength, newLength)
        var suffix = 0
        let suffixLimit = min(shared, max(0, newLength - caret))
        while suffix < suffixLimit,
              old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) {
            suffix += 1
        }
        var prefix = 0
        while prefix < shared - suffix, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var edits: [TextEdit] = []
        let removed = oldLength - prefix - suffix
        if removed > 0 {
            edits.append(.remove(location: prefix, length: removed))
        }
        let inserted = newLength - prefix - suffix
        if inserted > 0 {
            var units = [UInt16](repeating: 0, count: inserted)
            new.getCharacters(&units, range: NSRange(location: prefix, length: inserted))
            edits.append(.insert(location: prefix, text: units))
        }
        return edits
    }

    /// Where `position` lands after removing `count` units at `at`.
    static func removing(_ position: Int, at: Int, _ count: Int) -> Int {
        if position <= at {
            return position
        }
        if position <= at + count {
            return at
        }
        return position - count
    }
}

extension NSRange {
    /// Moves a selection through one edit so it keeps covering the same characters.
    /// A caret sits before text inserted exactly at it, so a collaborator typing at the caret
    /// does not push it. A non-empty selection keeps exactly its characters: text inserted at its
    /// start goes before it, text inserted at its end goes after it.
    func transformed(by edit: TextEdit) -> NSRange {
        let start = location
        let end = location + length
        switch edit {
        case let .insert(at, text):
            let count = text.count
            let newStart = at < start || (at == start && length > 0) ? start + count : start
            let newEnd = at < end ? end + count : end
            return NSRange(location: newStart, length: newEnd - newStart)
        case let .remove(at, count):
            let newStart = TextEdit.removing(start, at: at, count)
            let newEnd = TextEdit.removing(end, at: at, count)
            return NSRange(location: newStart, length: newEnd - newStart)
        }
    }
}
