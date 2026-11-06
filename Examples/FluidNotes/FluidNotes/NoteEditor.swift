import FluidJS
import FluidSequence
import SwiftUI
import UIKit

/// Plain-text editor whose text is a SharedString. `UITextView` is used because it exposes
/// selection and edits as UTF-16 `NSRange`s, the same unit as SharedString positions.
struct NoteEditor: UIViewRepresentable {
    let note: NoteText

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.keyboardDismissMode = .interactive
        note.attach(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}

/// Binds a text view to a SharedString on the main actor, which owns the container. User edits
/// go to the SharedString inside the delegate callback; remote edits patch the text storage
/// inside the SharedString's `sequenceDelta` listener, while the selection stays on the same
/// characters.
@MainActor
final class NoteText: NSObject, UITextViewDelegate {
    private let sharedString: SharedString
    private let failed: (any Error) -> Void
    /// The SharedString's text as of the last applied edit, which local diffs are taken against.
    /// It differs from the text view only while marked (IME) text is being composed.
    private var text: NSString
    private weak var view: UITextView?
    /// Set while the text view holds marked text the SharedString has not seen.
    private var composing = false
    /// Set while this object changes the text view itself, so the delegate callbacks UIKit makes
    /// for that change are not taken as user edits.
    private var updatingView = false

    init(text sharedString: SharedString, failed: @escaping (any Error) -> Void) {
        self.sharedString = sharedString
        self.failed = failed
        text = Self.string(sharedString.getText())
        super.init()
        sharedString.sequenceDelta = { [weak self] event in
            guard let self, !event.isLocal else { return }
            // Ranges resolve against live segments, so they are read inside the event.
            receive(Self.edits(of: event))
        }
    }

    func attach(_ view: UITextView) {
        replaceAll(in: view, with: text)
        view.delegate = self
        self.view = view
    }

    func textViewDidChange(_ view: UITextView) {
        guard !updatingView else { return }
        // Marked text is provisional; it reaches the SharedString once the input method
        // commits it.
        if view.markedTextRange != nil {
            composing = true
            return
        }
        composing = false
        submit(view)
    }

    /// Committing marked text without changing it ends the composition with a selection change
    /// and no text change.
    func textViewDidChangeSelection(_ view: UITextView) {
        guard !updatingView, composing, view.markedTextRange == nil else { return }
        composing = false
        submit(view)
    }

    /// Applies the user's change to the SharedString. A replacement is a remove and an insert;
    /// if either throws, the SharedString may hold only part of the change, so the text view is
    /// reset to the SharedString's text, which is what every client converges on.
    private func submit(_ view: UITextView) {
        let current = view.textStorage.mutableString.copy() as! NSString
        let edits = TextEdit.changes(from: text, to: current, caret: NSMaxRange(view.selectedRange))
        do {
            for edit in edits {
                switch edit {
                case let .insert(location, units):
                    try sharedString.insertText(location, JSString(utf16: ContiguousArray(units)))
                case let .remove(location, length):
                    try sharedString.removeText(location, location + length)
                }
            }
            text = current
        } catch {
            text = Self.string(sharedString.getText())
            updatingView = true
            let selection = view.selectedRange
            replaceAll(in: view, with: text)
            view.selectedRange = NSRange(location: min(selection.location, text.length), length: 0)
            view.undoManager?.removeAllActions()
            updatingView = false
            failed(error)
        }
    }

    /// Applies a remote op's edits to the text and the text view.
    private func receive(_ edits: [TextEdit]) {
        guard !edits.isEmpty else { return }
        let updated = text.mutableCopy() as! NSMutableString
        for edit in edits {
            Self.apply(edit, to: updated)
        }
        guard let view else {
            text = updated.copy() as! NSString
            return
        }
        updatingView = true
        defer { updatingView = false }
        if let marked = view.markedTextRange {
            // The text view holds an uncommitted composition the SharedString has not seen.
            // Positions in this op are SharedString positions, so the composition is dropped and
            // the view returns to the SharedString's text before the op applies.
            let start = view.offset(from: view.beginningOfDocument, to: marked.start)
            view.unmarkText()
            composing = false
            replaceAll(in: view, with: text)
            view.selectedRange = NSRange(location: min(start, text.length), length: 0)
        }
        var selection = view.selectedRange
        let storage = view.textStorage
        storage.beginEditing()
        for edit in edits {
            Self.apply(edit, to: storage.mutableString)
            if case let .insert(location, units) = edit {
                storage.setAttributes(view.typingAttributes, range: NSRange(location: location, length: units.count))
            }
            selection = selection.transformed(by: edit)
        }
        storage.endEditing()
        view.selectedRange = selection
        text = updated.copy() as! NSString
        // UIKit's undo actions hold ranges in the text before this op; replaying one now would
        // edit the wrong characters and send that edit to every client.
        view.undoManager?.removeAllActions()
    }

    private func replaceAll(in view: UITextView, with text: NSString) {
        let storage = view.textStorage
        storage.beginEditing()
        CFStringReplaceAll(storage.mutableString, text)
        storage.setAttributes(view.typingAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// The text edits for one remote delta, in ascending position. Each range position is in the
    /// post-op text, so applying them in order reproduces the op.
    /// `deltaOperation` is merge-tree `MergeTreeDeltaType`: 0 insert, 1 remove, 2 annotate.
    private static func edits(of event: SequenceDeltaEvent) -> [TextEdit] {
        switch event.deltaOperation {
        case 0:
            return event.ranges.compactMap { range in
                range.segment.text.map { .insert(location: range.position, text: Array($0.utf16)) }
            }
        case 1:
            return event.ranges.map { .remove(location: $0.position, length: $0.segment.length) }
        default:
            return []
        }
    }

    /// CoreFoundation keeps the UTF-16 exactly, including a lone surrogate, which a round trip
    /// through Swift `String` would replace.
    private static func string(_ text: JSString) -> NSString {
        let units = Array(text.utf16)
        return CFStringCreateWithCharacters(nil, units, units.count)! as NSString
    }

    private static func apply(_ edit: TextEdit, to string: NSMutableString) {
        switch edit {
        case let .insert(location, units):
            CFStringInsert(string, location, CFStringCreateWithCharacters(nil, units, units.count))
        case let .remove(location, length):
            string.deleteCharacters(in: NSRange(location: location, length: length))
        }
    }
}
