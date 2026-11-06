# Swift-native app API

2026-11-06. Proposal only. Nothing here is implemented. It covers the layer an iOS or macOS app
imports, which sits on top of the 1:1 TypeScript port. ARCHITECTURE.md §2 (one owner, synchronous
DDS access and events) and §3 (JS value semantics inside the port) are taken as settled. This
proposal does not reopen them.

Benchmarks: `.build/swift-native-api/` (`bench.swift`, `keypath.swift`; raw output in
`results.txt`, `run2.txt` and `run3.txt`).

## Problems with today's surface

Everything below comes from `Examples/FluidNotes`, the one real app, and the APIs it has to touch.

1. **Initial objects are a string-keyed bag that the app has to downcast.** The schema is
   `ContainerSchema(initialObjects: ["text": SharedString.self])`
   (`Examples/FluidNotes/FluidNotes/NotesModel.swift:15`, `Sources/FluidStatic/Types.swift:7-11`).
   The container hands back `JSObject<any Channel>` (`Sources/FluidStatic/FluidContainer.swift:61`).
   So every app writes `container.initialObjects["text"] as? SharedString`, then invents an error
   for a case the type system could rule out (`NotesModel.swift:72-75`, `NotesError` at `:114-123`).
2. **DDS events are single-slot closure properties.** Examples are
   `sequenceDelta: ((SequenceDeltaEvent) -> Void)?` (`Sources/FluidSequence/SharedSegmentSequence.swift:15`)
   and `valueChanged` / `clearEvent` (`Sources/FluidMap/SharedMap.swift:22-30`). Assigning one
   silently replaces whatever was already there (`NoteEditor.swift:46`), so an Observation adapter
   and an editor cannot both listen. TS uses an `EventEmitter` with any number of listeners. The
   port therefore has three event mechanisms: these slots, `ListenerList` with `Int` tokens
   (`Sources/FluidContainerDefinitions/Events.swift:5-25`), and a stringly typed
   `on(_ event: JSString, …)` (`Sources/FluidSharedObjectBase/SharedObject.swift:80`).
3. **Deltas expose merge-tree internals.** The app decodes `deltaOperation` as the magic numbers
   0, 1 and 2 and walks `range.segment.text` on `BaseSegment` (`NoteEditor.swift:156-170`).
4. **`JSString` leaks into UI code.** The editor drops to CoreFoundation so that it never goes
   through `String` (`NoteEditor.swift:172-186`). It builds `JSString(utf16: ContiguousArray(units))`
   by hand (`:89`), and carries `[UInt16]` in its own edit type (`TextEdit.swift:3-8`). In the
   other direction, `JSString.description` quietly loses lone surrogates
   (`Sources/FluidJS/JSString.swift:37-38`).
5. **Every edit throws, and callers cannot tell why.** `insertText`, `removeText`, `replaceText`
   (`Sources/FluidSequence/SharedString.swift:22-39`) and map `set`, `delete` and `clear`
   (`SharedMap.swift:50-61`) all throw untyped errors. Three of the causes are programmer errors:
   reentrancy (`SharedSegmentSequence.swift:113`), out-of-range positions
   (`Sources/FluidMergeTree/Client.swift:101`) and listener faults (`SharedObject.swift:86-93`). The
   fourth is runtime state: a closed DDS (`SharedObject.swift:75-77`). Because a replace is two
   ops, the editor needs 20 lines to recover from a partial failure (`NoteEditor.swift:79-105`).
6. **Map values are untyped.** Maps use `JSONValue?` with `JSString` keys (`SharedMap.swift:42-52`),
   and `nil` means both "absent" and "JS `undefined`" (`Sources/FluidMap/LocalValue.swift:3-6`).
   Reading a `String` takes `if case .string(let s) = value { s.description }`.
7. **Container state is mirrored by hand.** The model copies `connectionState` into its own
   `connection` property (`NotesModel.swift:18`, `:82`) and keeps it current with a hand-written
   event switch (`:99-111`). That gives two sources of truth. The listener token is dropped
   (`:83`), and teardown is manual (`:92-97`).
8. **Configuration and results follow TS's shape.**
   `OdspClient(properties: OdspClientProps(connection: OdspConnectionConfig(…, filePath: "")))`
   nests three structs to pass three values, one of them unused (`NotesModel.swift:63-68`).
   `getContainer` returns a `(container, services)` tuple that the app discards half of
   (`Sources/FluidOdspClient/OdspClient.swift:50-54`, `NotesModel.swift:70`).

Problem 2 is a fidelity bug in the port, not just friction: TS DDS events can have many listeners.
The native layer below does not depend on fixing it, but the port should move those slots to
`ListenerList` anyway.

## Settled, and not reopened here

- The owner is the explicit, non-optional `isolation: isolated any Actor` on every factory, with
  no default. The native layer forwards it unchanged.
- Edits and events stay synchronous on the owner. There is no `edit {}` scope, and live deltas are
  never streamed through `AsyncSequence`.
- The port's TS-shaped API, `JSString`/`JSONValue` and UTF-16 wire positions all stay exactly as
  they are. The differential harness keeps driving the port.

## Questions for Juan

### Q1. `String` or `JSString` at the boundary, and what is a position?

**A. Keep `JSString` and `JSONValue` (status quo).** Exact, but every app repeats problem 4.

```swift
try text.insertText(location, JSString(utf16: ContiguousArray(units)))
let s = text.getText().description          // lossy anyway
```

**B. `String` for text, keys and values; `Int` UTF-16 offsets for positions.** On read, a lone
surrogate becomes U+FFFD. That replacement is one UTF-16 unit, the same length as the lone
surrogate, so every offset the app computes still lines up with the DDS. A `String` cannot hold a
lone surrogate, so the app can never write one.

```swift
text.insert("hi", at: range.location)        // UTF-16 offset == NSRange.location
text.replace(range.lowerBound..<range.upperBound, with: "x")
let s: String = text.string
```

**C. `String` for text, `String.Index` for positions.** This matches SwiftUI's `TextSelection`, but
an index is only valid for one `String` value, and the DDS text changes with every op. Rebuilding
the mapping costs O(n) per edit for non-ASCII text: 19.6 µs at 10K units and 1.96 ms at 1M (see
Performance). Merge-tree, the wire format, `NSString`, `NSRange`, `UITextView` and TextKit all
count in UTF-16.

**Recommendation: B.** Positions stay `Int` UTF-16 offsets, the unit used by merge-tree and by
every Apple text view that can carry a collaborative editor. The only lossy case is a TS client
that splits a surrogate pair across two ops: Swift then shows two U+FFFD until reload. Content and
convergence are unaffected, because the app only reads the replacement and never writes it. Map
keys carry one sharp edge: a TS-written lone-surrogate key is listed as `"\u{FFFD}"`, but
`map["\u{FFFD}"]` does not find it. Document that rather than adding an escape hatch.

### Q2. SharedMap values: typed or `JSONValue`?

**A. `JSONValue` with `String` keys.** Smallest change, still untyped.

```swift
map["title"] = .string("Groceries")
if case .string(let title)? = map["title"] { … }
```

**B. A homogeneous `SharedMap<Value: Codable>` that behaves like `Dictionary<String, Value>`.**

```swift
let items: SharedMap<Item>
items[id] = Item(text: "Milk", done: false)
items[id]?.done = true                        // read, mutate, write: last writer wins per key
items[id] = nil                               // delete
```

**C. Heterogeneous typed keys, in the style of `EnvironmentKey`.**

```swift
extension SharedMap.Key { static var title: Key<String> { .init("title") } }
settings[.title] = "Groceries"
```

**Recommendation: B.** It has one generic parameter, a familiar Dictionary shape, and the schema
states the value type. When an app wants per-field last-writer-wins, it puts the fields in
separate maps or keys instead of one struct. C buys heterogeneity at the cost of a key declaration
per field, and B plus a second map covers the same need.

How it encodes: through an internal encoder and decoder that go straight between `Codable` and
`JSONValue`, with JS number semantics (`Int` becomes `Double`, and values above 2^53 are rejected).
Foundation's `JSONEncoder` is never used, per §3. A value that cannot be encoded is a programmer
error and traps.

The one sub-decision: **what a read does with a stored value that does not decode**, for example
one written by an older version or by a TS client. I recommend treating it as absent, with an
`assertionFailure` in debug builds. The app cannot act on it, and trapping on remote data would let
any peer crash every Swift client. The stricter alternative is a throwing `value(forKey:)`, which
puts `try` into every SwiftUI `body`.

### Q3. Observation or synchronous callbacks?

**A. Synchronous callbacks only, with typed, multi-listener events.** This is TS-faithful, but
every app rebuilds problem 7: a mirror model that copies DDS state into `@Observable` properties.

```swift
let token = map.onValueChanged { key, isLocal in model.refresh(key) }
```

**B. The native objects are themselves `Observable`, and every read goes straight to the DDS.**
The native object keeps no copy of any value, only an `ObservationRegistrar`. The DDS's own
synchronous listener calls `withMutation` for exactly what changed: `\.string` for a
SharedString; `\.[key]` for a map key, plus `\.keys` when the set of keys changes. Per-key
tracking works: a tracker on `map["a"]` does not fire for writes to `b` (`keypath.swift`). Editors
are the one consumer that needs deltas rather than "something changed", so they get one
synchronous callback on SharedString:

```swift
@Bindable var title = container.initialObjects.title
TextField("Title", text: $title.string)                  // SwiftUI: no adapter at all

subscription = text.onChange { [weak self] change in     // UIKit editor: deltas, synchronously
    guard let self, !change.isLocal else { return }
    for edit in change.edits { self.apply(edit) }        // .insert(String, at:) / .remove(Range<Int>)
}
```

**C. `AsyncSequence` of changes.** Rejected by §2 for live deltas. Snapshot streams come for free
from the standard library's `Observations { text.string }` on top of B, so the library adds no
`AsyncSequence` API of its own.

**Recommendation: B.** It keeps all of §2's guarantees:

- Notifications are emitted inside the DDS's synchronous event, on the owner.
- Nothing is stored, so a deferred reader such as SwiftUI's next render always sees live DDS
  state, never a stale copy.
- The editor callback runs inside the event exactly as `sequenceDelta` does today, so its
  positions resolve against live segments.

One rule carries over from TS listeners: a `withObservationTracking` `onChange` handler runs
inside `willSet`, so it must not edit. If it does, the existing reentrancy guard traps (see Q5).
`SharedMap` gets no callback API at all. SwiftUI just re-reads the keys it tracks.

### Q4. How is a schema declared?

**A. Status quo: a string bag, with the cast moved into one helper.**

```swift
static let schema = ContainerSchema(initialObjects: ["text": SharedString.self])
let text = try container.initialObject("text", as: SharedString.self)
```

**B. A typed struct with a hand-written init, using a generic subscript constrained to DDS types.**

```swift
struct Checklist: ContainerSchema {
    let title: SharedString
    let items: SharedMap<Item>
    init(_ objects: InitialObjects) {
        title = objects["title"]        // subscript<T: SharedObject>(key: String) -> T
        items = objects["items"]
    }
}
```

The library runs `init` in two modes:

- To create a container, `InitialObjects` makes fresh objects. Those become the TS
  `initialObjects`, in declaration order.
- To load one, a first pass over fresh objects records each key and kind for the channel registry.
  `createDOProviderContainerRuntimeFactory` needs those before load
  (`Sources/FluidOdspClient/OdspClient.swift:74`). A second pass then resolves the loaded
  channels, and a wrong kind throws `FluidError.schemaMismatch(key:)` from `loadContainer`.

After load, every access is typed and total. A non-DDS property fails at compile time, because
the subscript is constrained to `SharedObject`.

**C. A `@ContainerSchema` macro that generates B's init from property names.**

```swift
@ContainerSchema struct Checklist { let title: SharedString; let items: SharedMap<Item> }
```

**Recommendation: B.** It needs no swift-syntax dependency or macro target, and it is
compile-time safe. The cost is one line per object that spells the key. C can be added later as
pure sugar, because it would generate B. I considered and rejected making the schema `Decodable`
and letting the compiler synthesize the init. A property such as `let title: String` would still
compile, and the mistake would only surface at runtime.

### Q5. Error handling and closure

**A. Keep `throws` on every edit (status quo).** Problem 5 stays, and with it `try` on every
keystroke plus recovery code at each call site.

**B. Edits do not throw. Programmer errors trap, and closure is state.**

```swift
text.insert("x", at: 99_999)   // precondition: out of range, like String/Array
items[id] = item               // after the service closed the container: dropped;
                               // container.status is already .closed(error)
```

The native layer validates ranges before calling the port, so a replace can no longer half-apply.
Reentrancy traps too. Any other error from the port is an internal invariant violation and traps.
Only loading throws: `loadContainer` can fail on the network, on a token or on a schema mismatch.

**C. Typed `throws(FluidError)` on edits, where the only case is `.closed`.** The causes are
honest, but every call site still writes `try` for a state that the UI has to render anyway.

**Recommendation: B.** The container can close at any moment for reasons the app does not control,
and edits after that cannot reach the wire under any design. Throwing only moves the loss to N
call sites that would all do the same thing. Exposing closure once, as observable
`status == .closed(error)`, puts the handling in the one place the UI already looks. Lifecycle
follows the same idea. The native `FluidContainer` has no `dispose()`: the container closes when
its last reference goes away. Its listeners on the port graph are weak, and the object is
non-Sendable, so that release always happens on the owner. `container = nil` replaces
`NotesModel.close()`.

### Q6. How does the native layer relate to the 1:1 port?

**A. Extensions on the port types.** No new types, but apps see two APIs on the same object:
`insertText(_:_: JSString)` beside `insert(_:at:)`.

**B. A new `Fluid` target holding stateless views over the port objects, which it imports with
`internal import`.**

```swift
// Sources/Fluid/SharedString.swift
internal import FluidSequence
public final class SharedString: Observable {
    let port: FluidSequence.SharedString       // the only state that matters
    let registrar = ObservationRegistrar()
}
```

**C. Mark the TS-shaped methods `package` and add native methods to the port types.** That gives
one type per DDS, but it mixes native concerns into ported files and breaks §4's rule that each
ported type has the same responsibilities as its TS class.

**Recommendation: B.** Apps write `import Fluid` and see one path per use case, with no `JSString`,
`JSONValue`, `ListenerList` or `I`-prefixed protocols. The port, its tests and the harness peers
do not change. Each native object holds a reference to its port object, a registrar, and the
token of its one port listener. No DDS state is duplicated. Native names match TS names
(`SharedString`, `SharedMap`, `OdspClient`, `FluidContainer`). Inside `Fluid`, the code refers to
port types by module qualification.

Version 1 covers `OdspClient`, `FluidContainer`, plain-text `SharedString` and `SharedMap`.
Annotations, intervals, the other DDSes, audience and ODSP services follow the same pattern
later, each when a use case needs it.

## Proposed API

```swift
// import Fluid
public struct OdspClient: Sendable {
    public init(siteURL: URL, driveID: String, tokenProvider: any OdspTokenProvider)
    public func loadContainer<Schema: ContainerSchema>(
        _ itemID: String, schema: Schema.Type, isolation owner: isolated any Actor
    ) async throws -> FluidContainer<Schema>
}

public final class FluidContainer<Schema: ContainerSchema>: Observable {
    public let initialObjects: Schema
    public var status: ContainerStatus { get }          // observable
    public var isDirty: Bool { get }                    // observable
}                                                       // closes on deinit

public enum ContainerStatus { case connecting, connected, disconnected, closed((any Error)?) }

public final class SharedString: Observable {
    public var string: String { get set }               // observable; the setter applies one minimal edit
    public var utf16Count: Int { get }                  // observable
    public func insert(_ text: String, at utf16Offset: Int)
    public func remove(_ range: Range<Int>)
    public func replace(_ range: Range<Int>, with text: String)
    public func onChange(_ body: @escaping (TextChange) -> Void) -> Subscription
}

public struct TextChange {
    public enum Edit { case insert(String, at: Int), remove(Range<Int>) }
    public let edits: [Edit]        // ascending; each position in post-edit text
    public let isLocal: Bool
}

public final class SharedMap<Value: Codable>: Observable {
    public subscript(key: String) -> Value? { get set } // observable per key; nil deletes
    public var keys: [String] { get }                   // observable; insertion order
    public func removeAll()
}
```

`ContainerStatus.connecting` covers both `establishingConnection` and `catchingUp`.
`OdspTokenProvider` has the same two requirements as `IOdspTokenProvider`, minus the `I`.

The `string` setter diffs the common prefix and suffix and applies one `replace`. It exists so
SwiftUI `TextField`s get a one-line binding. It cannot know where the caret is, so a repeated
character ("aa" to "aaa") is attributed to the end of the run. That is fine for titles and short
fields. Long documents should use a UIKit editor driven by `onChange`.

A complete app, a shared checklist with a collaborative title:

```swift
import Fluid
import SwiftUI

struct Checklist: ContainerSchema {
    let title: SharedString
    let items: SharedMap<Item>

    init(_ objects: InitialObjects) {
        title = objects["title"]
        items = objects["items"]
    }
}

struct Item: Codable {
    var text: String
    var done: Bool
}

let client = OdspClient(siteURL: AppConfig.siteURL, driveID: AppConfig.driveID, tokenProvider: AppTokenProvider())

@main
struct ChecklistApp: App {
    var body: some Scene {
        WindowGroup { ContentView(itemID: AppConfig.itemID) }
    }
}

struct ContentView: View {
    let itemID: String
    @State private var container: FluidContainer<Checklist>?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            if let container {
                ChecklistView(container: container)
            } else if let failure {
                ContentUnavailableView(failure, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                container = try await client.loadContainer(itemID, schema: Checklist.self, isolation: MainActor.shared)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct ChecklistView: View {
    let container: FluidContainer<Checklist>
    @State private var draft = ""

    var body: some View {
        @Bindable var title = container.initialObjects.title
        let items = container.initialObjects.items
        List {
            TextField("Title", text: $title.string)
                .font(.title2.bold())
            ForEach(items.keys, id: \.self) { id in
                if let item = items[id] {
                    Toggle(item.text, isOn: Binding { item.done } set: { items[id]?.done = $0 })
                }
            }
            .onDelete { offsets in
                for id in offsets.map({ items.keys[$0] }) { items[id] = nil }
            }
            TextField("Add item", text: $draft)
                .onSubmit {
                    items[UUID().uuidString] = Item(text: draft, done: false)
                    draft = ""
                }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { StatusView(status: container.status) }
        }
    }
}

struct StatusView: View {
    let status: ContainerStatus

    var body: some View {
        switch status {
        case .connecting: ProgressView()
        case .connected: Image(systemName: "circle.fill").imageScale(.small)
        case .disconnected, .closed: Image(systemName: "circle").imageScale(.small)
        }
    }
}
```

Compared with FluidNotes, `NotesModel`'s container plumbing, `NotesError`, the connection mirror,
the `as?` cast and the manual `close()` are gone, because every one of them is now either a type
or an observable property. A UIKit editor still keeps its IME, selection and undo handling. That
is native text-system work that no DDS API removes. But `NoteText` loses:

- `string(_:)` and the CoreFoundation helpers (`NoteEditor.swift:172-186`), because inserts carry
  a `String`;
- `edits(of:)` (`:156-170`), because `TextChange.edits` replaces it;
- the partial-failure branch (`:94-104`), because edits no longer throw.

## Performance

These numbers come from a release build (`swiftc -O`) with Swift 6.4 on an M1 Max. Each figure is
the best of 5 repetitions, then the minimum across 3 runs. Treat the absolute values as an upper
bound: other agents were building throughout, with a load average of 133–204. The ratios between
rows are the reliable part. Nothing was measured on a device.

| Operation | 1 char | 10K, ASCII | 10K, mixed | 1M, ASCII | 1M, mixed |
|---|---|---|---|---|---|
| `String` to `JSString` | 83–87 ns | 2.5 µs | 31 µs | 240 µs | 3.0 ms |
| `JSString` to `String` | 162 ns | 17 µs | 24 µs | 1.46 ms | 2.8 ms |
| UTF-16 copy (the floor for today's `getText`) | | 0.6 µs | 0.6 µs | 42 µs | 45 µs |
| UTF-16 offset to `String.Index`, warm | | 39 ns | 59 ns | 39 ns | 85 ns |
| UTF-16 offset to `String.Index`, new string\* | | 0.28 µs | 19.6 µs | 21 µs | 1.96 ms |

\* Includes copying the string to force fresh storage, which is about 20 µs at 1M. For ASCII
text the mapping itself is O(1), so that row is mostly the copy.

The map and observation rows:

| Operation | Time |
|---|---|
| Hand-built `JSONValue` for a 3-field struct | 0.62 µs |
| `Codable` to `JSONValue` through a direct encoder (prototype in `bench.swift`) | 0.99 µs |
| Foundation `JSONEncoder` to `Data`, for reference only (excluded by §3) | 1.59 µs |
| `@Observable` mutation, no observer | 114 ns |
| `@Observable` mutation, re-armed tracker (what one observing view costs) | 2.26 µs |

What this means:

- **Per-keystroke conversion is noise.** About 0.1–0.2 µs each way, against an 8.33 ms frame.
  `insert(_:at:)` costs the same as today plus one small transcode.
- **Converting the whole document is the real cost**, and B keeps it off hot paths. Reading
  `string` builds a `String` in O(n): 1.5–2.8 ms at 1M units, about 35–60× the cost of today's
  UTF-16 copy. That is fine for titles and labels. Editors take `TextChange` deltas, whose cost
  grows with the size of the edit, not the document. Nothing caches `string`: a cache would be a
  second copy of the text.
- **`String.Index` positions would be O(n) per edit** on non-ASCII text, which is why Q1
  recommends against C.
- **Typed map values cost about 1 µs per encode or decode.** There is no Foundation round trip
  through text, and no cache of decoded values. A SwiftUI list that reads 100 items decodes 100
  times, about 0.1–0.2 ms. Add a cache only if a profile asks for one. `keys` allocates an array
  of `String` on every read. That is O(count) per render, which is fine at checklist scale.
- **Observation adds about 0.1 µs per change with no observer**, plus about 2 µs for each tracker
  that fires. A 1,000-op catch-up adds about 0.1 ms of registrar work, and SwiftUI coalesces the
  re-renders into the next frame. The 4 ms catch-up slice in §2 is unaffected.
- **Allocations:** one native object per DDS, created once at load, plus one `Subscription` per
  editor. For each op, the delta's insert text becomes one `String`, and small strings live inline
  with no allocation. Reads allocate only when they return a `String` or a decoded value.
- **Two cheap wins are available in `FluidJS`, separate from this proposal:**
  - `JSString.init(_:)` is 12–25× slower on non-ASCII text, because it walks `String.utf16`
    (`Sources/FluidJS/JSString.swift:21`). Bulk transcoding from UTF-8 would fix that.
  - `String(decoding:as: UTF16.self)` has no ASCII fast path: 17 µs, against 2.5 µs in the other
    direction. A native `string` getter could special-case ASCII.
