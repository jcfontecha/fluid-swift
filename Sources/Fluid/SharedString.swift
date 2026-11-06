internal import FluidDatastoreDefinitions
internal import FluidJS
internal import FluidSequence
import Observation

/// Collaborative plain text. Positions and lengths are UTF-16 offsets, the unit of `NSString`,
/// `NSRange` and `UITextView`. A lone surrogate written by a TS client reads as U+FFFD, which is
/// also one UTF-16 unit, so offsets computed on `string` still line up.
///
/// Edits do not throw. An out-of-range position traps, like `String` and `Array`. An edit made
/// from inside a change handler traps too. After the container closes, edits are dropped.
public final class SharedString: Observable, SharedObject {
    public static var kind: SharedObjectKind<SharedString> {
        SharedObjectKind(
            channelType: FluidSequence.SharedString.self,
            make: { id in SharedString(port: FluidSequence.SharedString(id: id)) },
            adopt: { channel in (channel as? FluidSequence.SharedString).map(SharedString.init(port:)) })
    }

    private let port: FluidSequence.SharedString
    private let registrar = ObservationRegistrar()
    private var listener = 0

    private init(port: FluidSequence.SharedString) {
        self.port = port
        listener = port.sequenceDelta.on { [weak self] event in
            self?.receive(event)
        }
    }

    deinit {
        port.sequenceDelta.off(listener)
    }

    /// The whole text. Reading it builds a `String` in O(n). Setting it applies one replace that
    /// spans the changed middle: the common prefix and suffix stay, so a repeated character
    /// ("aa" to "aaa") is attributed to the end of the run. Editors use `onChange` and the edit
    /// methods instead.
    public var string: String {
        get {
            registrar.access(self, keyPath: \.string)
            return port.getText().description
        }
        set {
            let old = Array(port.getText().description.utf16)
            let new = Array(newValue.utf16)
            let shared = min(old.count, new.count)
            var prefix = 0
            while prefix < shared, old[prefix] == new[prefix] {
                prefix += 1
            }
            var suffix = 0
            while suffix < shared - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
                suffix += 1
            }
            // Never split a surrogate pair: both strings hold the same units in the shared prefix
            // and suffix, so moving a bound inward keeps the edit exact.
            if prefix > 0, UTF16.isLeadSurrogate(new[prefix - 1]) {
                prefix -= 1
            }
            if suffix > 0, UTF16.isTrailSurrogate(new[new.count - suffix]) {
                suffix -= 1
            }
            let inserted = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
            let removed = prefix..<(old.count - suffix)
            if removed.isEmpty && inserted.isEmpty {
                return
            }
            replace(removed, with: inserted)
        }
    }

    /// The text's length in UTF-16 units.
    public var utf16Count: Int {
        registrar.access(self, keyPath: \.utf16Count)
        return port.getLength()
    }

    public func insert(_ text: String, at utf16Offset: Int) {
        precondition(utf16Offset >= 0 && utf16Offset <= port.getLength(), "Insert position \(utf16Offset) is out of range.")
        do {
            try port.insertText(utf16Offset, JSString(text))
        } catch {
            dropIfClosed(error)
        }
    }

    public func remove(_ range: Range<Int>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= port.getLength(), "Range \(range) is out of range.")
        guard !range.isEmpty else {
            return
        }
        do {
            try port.removeText(range.lowerBound, range.upperBound)
        } catch {
            dropIfClosed(error)
        }
    }

    /// Removes `range` and inserts `text` in its place, as one edit that cannot half apply.
    public func replace(_ range: Range<Int>, with text: String) {
        precondition(range.lowerBound >= 0 && range.upperBound <= port.getLength(), "Range \(range) is out of range.")
        // sequence.ts `replaceText` with empty text inserts nothing and so removes nothing.
        guard !text.isEmpty else {
            remove(range)
            return
        }
        do {
            try port.replaceText(range.lowerBound, range.upperBound, JSString(text))
        } catch {
            dropIfClosed(error)
        }
    }

    /// Calls `body` synchronously for every text change, local or remote, while the returned
    /// subscription is alive. Positions resolve against the live text, so the handler applies
    /// them right away and must not edit this string.
    public func onChange(_ body: @escaping (TextChange) -> Void) -> Subscription {
        let token = port.sequenceDelta.on { event in
            if let change = TextChange(event) {
                body(change)
            }
        }
        return Subscription { [port] in
            port.sequenceDelta.off(token)
        }
    }

    /// Text changed: insert (0) and remove (1) change it, annotate (2) does not.
    private func receive(_ event: SequenceDeltaEvent) {
        guard event.deltaOperation == 0 || event.deltaOperation == 1 else {
            return
        }
        registrar.willSet(self, keyPath: \.string)
        registrar.willSet(self, keyPath: \.utf16Count)
        registrar.didSet(self, keyPath: \.utf16Count)
        registrar.didSet(self, keyPath: \.string)
    }

    /// Edits throw only when the DDS is closed, when they are reentrant, or when an internal
    /// invariant breaks. Positions were checked already, so only a closed DDS is expected.
    private func dropIfClosed(_ error: any Error) {
        guard port.closed != nil else {
            preconditionFailure("SharedString edit failed: \(error)")
        }
    }
}

/// One op's effect on a `SharedString`'s text.
public struct TextChange {
    public enum Edit: Equatable {
        case insert(String, at: Int)
        case remove(Range<Int>)
    }

    /// In ascending position. Each position is in the text after the op, so applying the edits in
    /// order reproduces it.
    public let edits: [Edit]
    public let isLocal: Bool

    /// merge-tree `MergeTreeDeltaType`: 0 insert, 1 remove. Annotations change no text.
    init?(_ event: SequenceDeltaEvent) {
        switch event.deltaOperation {
        case 0:
            edits = event.ranges.compactMap { range in
                range.segment.text.map { .insert($0.description, at: range.position) }
            }
        case 1:
            edits = event.ranges.map { range in
                .remove(range.position..<(range.position + range.segment.length))
            }
        default:
            return nil
        }
        isLocal = event.isLocal
    }
}

/// Keeps a change handler registered. Releasing it removes the handler.
public final class Subscription {
    private let cancel: () -> Void

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    deinit {
        cancel()
    }
}
