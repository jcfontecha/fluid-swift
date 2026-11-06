import Fluid
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
/// inside the SharedString's `onChange` handler, while the selection stays on the same
/// characters.
@MainActor
final class NoteText: NSObject, UITextViewDelegate {
    private let sharedString: SharedString
    private var subscription: Subscription?
    /// The SharedString's text as of the last applied edit, which local diffs are taken against.
    /// It differs from the text view only while marked (IME) text is being composed.
    private var text: NSString
    private weak var view: UITextView?
    /// Set while the text view holds marked text the SharedString has not seen.
    private var composing = false
    /// Set while this object changes the text view itself, so the delegate callbacks UIKit makes
    /// for that change are not taken as user edits.
    private var updatingView = false

    init(text sharedString: SharedString) {
        self.sharedString = sharedString
        text = sharedString.string as NSString
        super.init()
        subscription = sharedString.onChange { [weak self] change in
            guard let self, !change.isLocal else { return }
            receive(change.edits.map(TextEdit.init))
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

    /// Applies the user's change to the SharedString. A replacement is a remove and an insert.
    private func submit(_ view: UITextView) {
        let current = view.textStorage.mutableString.copy() as! NSString
        let edits = TextEdit.changes(from: text, to: current, caret: NSMaxRange(view.selectedRange))
        for edit in edits {
            switch edit {
            case let .insert(location, units):
                sharedString.insert(String(decoding: units, as: UTF16.self), at: location)
            case let .remove(location, length):
                sharedString.remove(location..<(location + length))
            }
        }
        text = current
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

    private static func apply(_ edit: TextEdit, to string: NSMutableString) {
        switch edit {
        case let .insert(location, units):
            string.insert(String(decoding: units, as: UTF16.self), at: location)
        case let .remove(location, length):
            string.deleteCharacters(in: NSRange(location: location, length: length))
        }
    }
}

private extension TextEdit {
    /// One edit of a remote change. Each position is in the post-op text, so applying the edits
    /// in order reproduces the op.
    init(_ edit: TextChange.Edit) {
        switch edit {
        case let .insert(text, location):
            self = .insert(location: location, text: Array(text.utf16))
        case let .remove(range):
            self = .remove(location: range.lowerBound, length: range.count)
        }
    }
}
