# Threading and concurrency model

Design for the native Swift Fluid client's threading, isolation and app-facing event model.
Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.1, macOS 27.0, Apple M1 Max
(MacBookPro18,4). Every Swift claim below was checked against that compiler. The spike is
`.build/threading-opus/` (see [Evidence](#evidence)).

## Recommendation

**The container is owner-isolated.** The container, runtime, datastores and DDSes are plain,
non-Sendable, synchronous classes with no isolation of their own. Region-based isolation
(SE-0414) confines the whole graph to whichever isolation domain owns it: `MainActor` in an app,
a private actor for the summarizer, harness peers and background tools. Each container runs one
event-loop task on its owner's executor, which plays the role of the JS event loop.

Five rules follow:

1. **Load off-main, hand off with `sending`.** A `@concurrent` loader connects the socket,
   parses and hydrates the snapshot, and applies the stored ops. It returns the graph as a
   `sending` value (SE-0430) that the owner adopts in 0.05 ms. The compiler proves nothing else
   still references it.
2. **Steady state runs on the owner, synchronously.** Local edits apply inside the input handler.
   Remote ops apply one at a time inside the event loop, and their events fire synchronously.
   UI code holds DDS references directly and reads DDS state in the event's turn.
3. **No `await` where TS has none.** `submit` and `submitSignal` become synchronous FIFO
   enqueues, as they are in TS (`IDocumentDeltaConnection.submit(messages): void`). Today's
   `async` submit reorders CSNs in 197–199 of 200 trials.
4. **Catch-up on the owner yields at batch boundaries.** This ports `deltaScheduler.ts` with a
   4 ms budget, so a 3000-op reconnect catch-up never stalls main for more than about 9 ms.
5. **Events stay synchronous callbacks.** Observation is an app-side adapter for SwiftUI
   rendering. It is not an event API. The library exposes no `AsyncSequence` of DDS events.

FluidNotes' two-party OT layer (`TextSync.swift`, `SharedStringSync.swift`) is deleted. It exists
only because today's design puts the UI and the DDS in different isolation domains.

## 1. Correctness

### TS ordering invariants

| # | Invariant | TS source |
|---|---|---|
| I1 | A local edit applies to the DDS synchronously in the caller's turn and returns. | `sharedString.ts` → merge-tree `client.ts` → `submitLocalMessage` (no await) |
| I2 | Local ops in one turn form one batch, flushed after the turn. An inbound op flushes the open batch first, so a batch shares one reference sequence number. | `containerRuntime.ts` `scheduleFlush`, TurnBased: `Promise.resolve().then(() => this.flush())` (line 5428); the comment at 5399 on inbound ops calling `flush()` directly |
| I3 | Assigning a CSN and writing to the wire is one synchronous step. The service nacks a CSN gap and drops a duplicate. | `driver-definitions` `submit(messages): void`; deli `lambda.ts` `checkOrder` (1385–1421) |
| I4 | Inbound ops process in sequence order, one at a time. A batch processes "immediately and in the single turn", starting on a fresh stack, never inside the socket callback. | `deltaQueue.ts` `ensureProcessing` / `processDeltas` |
| I5 | Other work (input, rendering) may run between batches, never inside one. | `deltaScheduler.ts`: after 50 ms (+10 ms per turn), `inbound.pause()` at `batchEnd`, `setTimeout(resume)` |
| I6 | Listeners read DDS state in the event's turn. `SequenceDeltaEvent` ranges resolve lazily against live segments. | `sequenceDeltaEvent.ts`; `SequenceEventClass.ranges` is `lazy` in the port |
| I7 | Every TS `await` is a reentrancy point. Swift may await where TS awaits (storage fetch, connect, summary upload) and nowhere else. | follows from I1–I6 |

The actor-reentrancy hazard is I7. Every Swift `await` inside container code lets any other job
on that executor run. JS has the same property at its awaits, so faithful porting means the
synchronous segments in Swift match the synchronous segments in TS. Each extra Swift await is a
new interleaving point that TS clients never see.

### Each candidate against the invariants

| | I1 local apply | I2 turn batch | I3 CSN order | I4/I5 inbound | I6 same-turn read |
|---|---|---|---|---|---|
| (A) private-executor actor + app OT, today | **No.** The UI edits its own replica; the DDS applies later on another executor. | Inside the actor, yes | **No.** `sendMessages` awaits per message (`Container.swift:557`); `flushSignals` awaits per signal (`:382`). Spike [4]: 197–199/200 trials reordered. | Yes inside the actor | **No.** `onDelta`/`onQuorum`/`onAudience` take `@Sendable` listeners (`:142–150`), and `withEntryPoint`/`withPresence` take `@Sendable` bodies (`:402`, `:615`), so they cannot capture a DDS (N5). |
| (B) actor with an injected executor | Only from synchronous code. `assumeIsolated` is unavailable in async functions (N8). The UI cannot keep a DDS reference (N1). | Yes | As (A) unless the edge changes | Yes | Only via `assumeIsolated` inside each callback, a runtime trap if it is wrong |
| (C) `@MainActor` on every class | Yes | Yes | Edge dependent | Yes | Yes |
| (D) owner-isolated (recommended) | Yes. Spike [1]. | Yes, flush job | Yes. Spike [4]: 0 nacks in 400 ops from 5 writers. | Yes, with yields at batch boundaries | Yes. Spike [1]: the view equals the DDS inside all 200 remote events. |

(C) passes the ordering checks and fails elsewhere; see [Rejected alternatives](#rejected-alternatives).

### Is an app-side OT layer ever necessary?

No, as long as the UI and the DDS share one isolation domain. The layer exists because (A) makes
the text view a second replica in another domain, and two replicas editing concurrently need a
merge protocol. With (D) there is one replica. The view applies each `sequenceDelta` at its
position, which is exact at that instant because nothing else can run between the DDS apply and
the callback. The OT layer also carries costs that do not go away:

- It is a second merge algorithm on top of merge-tree, with its own tie-break (`winsTies`). The
  app's view of concurrent inserts is decided by app code, not by merge-tree.
- It must be written per DDS. LWW map keys are easy. SharedMatrix and SharedTree are not.
- UI positions never correspond to DDS positions at any instant, so local references,
  intervals and presence cursors cannot be shared between the view and the DDS.
- Every keystroke needs at least one cross-executor round trip (13.5–16 µs), and every remote op
  needs two hops (socket → container → main).

The one transform the app still owns is the editor's own: moving the selection through a remote
edit (`NSRange.transformed(by:)` in `TextEdit.swift`). That is caret bookkeeping, not OT.

## 2. Mobile performance

**Budget.** A frame is 8.33 ms at 120 Hz (ProMotion) and 16.67 ms at 60 Hz. UIKit layout and
Core Animation commits need most of it, so Fluid should take at most 4 ms of main time in any
one stretch. That figure is the delta scheduler's budget.

**Steady state is cheap.** From `Benchmarks/RESULTS.md` (same Mac, unoptimized port): a
merge-tree local insert plus ack is 53 µs, a sequenced SharedString remote op is 226–305 µs,
and a SharedMap op is about 9 µs. Typical collaboration rates are a few ops per second, which
is under 1% of main.

**Where the expensive work goes:**

| Work | Where | Evidence |
|---|---|---|
| Snapshot download | URLSession in the driver, off main | — |
| Snapshot parse and hydrate | `@concurrent` loader, off main | Spike R1: 5.3 MB JSON decoded and hydrated in 92–108 ms, off main |
| Catch-up at load (stored ops) | `@concurrent` loader, off main | R1: 3000 ops in 319–479 ms; main max gap 1.25–1.88 ms; 0 dropped frames |
| Hand-off to the owner | Owner | 0.04–0.05 ms (start the loop, bind the UI model) |
| Socket ops that arrive during load | Buffered in the container's job queue, drained on the owner after the hand-off | Spike [1] |
| Op JSON parse | The socket actor, before it yields (`DocumentDeltaConnection.receive`, as today) | — |
| Reconnect catch-up (the container is already owned by main) | Owner, sliced at batch boundaries | R2 unsliced: main frozen 760–955 ms. R3/R4 sliced at 4 ms: max gap 6.0–9.6 ms, 0 dropped 60 Hz frames, a queued keystroke ran mid-catch-up. Slicing adds 0–20% wall time. |
| Summarization | A separate summarizer container owned by a private actor (TS also uses a child container, but on the same JS thread) | Spike [1]: a peer container on a private actor ran entirely off main |
| Outbound compression | Runtime flush, on the owner, only for batches ≥ 614,400 bytes (`compressionDefinitions.ts:42`). LZ4 runs at GB/s, so this is under 1 ms. | — |
| Inbound decompression and batch reassembly | Runtime op processing, on the owner (part of I4) | — |

**Heavy work goes off-main without breaking isolation.** A graph built inside a `@concurrent`
function is one disconnected region. Returning it as `sending` transfers it to the caller. Once
MainActor owns it, it cannot leave: sending a MainActor-owned container elsewhere is a compile
error (N2). That is why reconnect catch-up slices on main instead of moving off-main.

**Driver CPU work must be `@concurrent`.** Container code is `nonisolated(nonsending)` and runs
on the owner. A driver function that is `nonisolated(nonsending)` also runs on its caller's
executor, so a parse inside it runs on main when the container calls it on main. The ODSP driver
marks `downloadSnapshot`, `fetchSnapshotCore` and `OdspNetwork.fetch` `nonisolated(nonsending)`
today. That is fine from the `@concurrent` loader. On reconnect and refresh paths called from
the owner, though, any parse or decode in those functions lands on main. The rule: parsing,
decoding and decompressing at the edge happens in `@concurrent` functions or in driver actors.

**Hop costs**, measured from MainActor in release builds (`Spike bench`, median of 5, two runs):

| Operation | ns |
|---|---:|
| Synchronous DDS edit (insert + remove, detached string) | 66.8–67.5 |
| Synchronous DDS read (`SharedMap.get`) | 25.9–26.3 |
| `await` an actor that shares MainActor's executor (B) | 48.8–49.0 |
| `actor.assumeIsolated { }` on a main-executor actor (B) | 138–146 |
| `MainActor.assumeIsolated { }` | 193–195 |
| `Task { }` on MainActor, spawn and run (about the cost of one owner job, e.g. the flush) | 1,170–1,175 |
| `await` a default actor and return (main → pool → main) (A) | 13,524–13,818 |
| `await` a dispatch-queue-executor actor and return (B, private queue) | 14,447–16,229 |
| `await Task.yield()` on MainActor, a full run-loop turn | 18,298–38,031 |
| Socket → MainActor `AsyncStream` element, median latency | 22,666–29,125 |
| Socket → MainActor `AsyncStream` element, p99 latency (host loaded) | 51,833–219,750 |

Per keystroke, (D) costs 0 hops: the DDS edit, then a synchronous enqueue to the socket's FIFO.
(A) costs a hop to the container and a hop back for the sync acknowledgement (the round trip
measures 13.5 µs), plus the OT transform. Per remote op, (D) costs one hop (socket →
owner, about 25 µs latency, about 1 µs of main CPU), and (A) costs two.

## 3. Swift 6 strict concurrency

**DDS classes stay as they are**: non-Sendable, synchronous, unannotated. No `@MainActor`, no
`@unchecked Sendable`, no locks. Region isolation, not annotations, keeps them safe:

- An app holds DDS references in `@MainActor` objects (`@Observable @MainActor` models, view
  controllers, `UIViewRepresentable` coordinators). Spike [1]: `EditorModel` holds
  `SharedStringLite` and `SharedMapLite` directly.
- A closure registered on a DDS from MainActor code may capture MainActor state. It is a
  non-Sendable closure stored in a non-Sendable object in the same region, called synchronously
  from DDS code on main (spike `EditorModel.init`).
- Tasks capture the `@MainActor` holder, which is Sendable by isolation, not the DDS. The
  compiler rejects detached access (N3) and sending the graph to another actor (N2). Capturing
  the same DDS in `TaskGroup.addTask { @MainActor in … }` inside a loop produced "pattern that
  the region-based isolation checker does not understand how to check. Please file a bug" in
  6.4. Capturing the holder in plain inherited `Task { }` compiles and runs.
- Public structs crossing modules need explicit `Sendable`: public types get no implicit
  conformance.

**Every async function in the container graph is `nonisolated(nonsending)`** (SE-0461). A plain
`async` method on a non-Sendable class is `@concurrent` in Swift 6 language mode, and the
compiler rejects calling it from owner-isolated code with "sending 'self' risks causing data
races" (N7, hit for real in the spike's `yieldTurn`). Turning on the upcoming feature
`NonisolatedNonsendingByDefault` for `FluidContainerLoader`, `FluidStatic` and
`FluidOdspClient` makes that the default; it accepts N7 unchanged. `ConnectionManager` is
already `nonisolated(nonsending)`.

**The owner is a non-optional `isolated any Actor`.** The obvious SE-0420 shape,
`isolation: isolated (any Actor)? = #isolation`, is unsound in 6.4. From a `@concurrent`
caller, `#isolation` is nil, the loop task runs nonisolated, and it races the caller's later use
of the graph with no diagnostic. N6 compiles cleanly. Built with `-sanitize=thread`, it reports
data races and loses updates in 30 of 50 runs. With a non-optional parameter, every misuse is a
compile error (N4, plus the scratch probes behind it).

**The I/O edges hand in Sendable values.** `ISequencedDocumentMessage`, `IDocumentMessage`,
`INack` and `ISignalMessage` are Sendable structs. The delta connection is a Sendable object
(an actor today):

- Outbound: `submit(_:)` and `submitSignal(_:targetClientId:)` are `nonisolated` and
  synchronous. They yield into an `AsyncStream` continuation, which is thread-safe and FIFO,
  and the socket actor drains it. Wire order is call order. Socket errors surface as the
  connection's `disconnect` event, as in TS.
- Inbound: the connection yields events into the container's job queue (an
  `AsyncStream<Job>.Continuation`). It buffers until the owner's loop starts, so ops that arrive
  during an off-main load are not lost or reordered.
- Storage: the container awaits driver calls from `nonisolated(nonsending)` code. URLSession
  completes elsewhere, and the await resumes on the owner.

The only `Mutex` is the one at the edge that already exists (`DocumentDeltaConnection.connected`).
The container graph needs none.

## 4. The app-facing API

| Mechanism | Same-turn read (I6) | Granularity | Use |
|---|---|---|---|
| Synchronous callbacks (`ListenerList`, `sequenceDelta`) | **Yes.** Spike [3]: the listener read 1, 2, 3. | Per op | All DDS and container events |
| `AsyncSequence` | **No.** Spike [3]: the consumer read 3, 3, 3; it runs in a later turn. | Per op, delayed | Not offered by the library |
| Observation `withObservationTracking` | **No.** Spike [2]: `onChange` fires synchronously on main inside op apply, but in willSet, so it reads the old value. | Per property | SwiftUI invalidation only |
| `Observations { }` (SE-0475) | **No.** Spike [2]: three changes coalesced into one later value (1 → 4). | Per transaction | Coarse async observation |

Only synchronous callbacks preserve the TS guarantee, so the library's event surface is
`ListenerList` with non-Sendable closures, exactly TS's `on("…")`. SwiftUI's need is different:
it reads state at render time, so willSet invalidation is what it wants.

**SwiftUI binds to a SharedMap through per-key `@Observable` cells.** An app-side adapter
subscribes to `valueChanged` and updates the cell for that key, so a view that reads key `a`
re-renders only for `a` (spike [2], `ObservableMap`). The adapter belongs in the app. A
reusable `FluidSwiftUI` target would be a new cross-cutting layer and needs approval first.

**SharedString binds through `UITextView`/`NSTextView`, never `TextEditor(text: $string)`.**
`TextEditor`'s binding replaces the whole string, which forces a diff, loses intent and
positions, and cannot keep a remote edit from moving the caret. The representable's delegate
edits the SharedString in `textView(_:shouldChangeTextIn:replacementText:)` and applies
`sequenceDelta` to `textStorage` inside the callback (code below).

## 5. Lifecycle

**Disposal.** `dispose()` is synchronous, as in TS. It finishes the job queue and closes the
socket, and the loop task ends. DDS objects stay valid Swift objects. Once the runtime closes
its channels, edits throw, because `SharedObject.verifyOpen` checks `closed`. The loop holds the container weakly, and DDS-to-runtime
closures are `unowned`. Disposal does no async work and needs no `deinit` logic.

**Cancellation.** `getContainer` honors task cancellation while it loads: URLSession cancels,
and the loader checks between phases. A cancelled load drops the disconnected graph, which
nothing else references, so there is no cleanup race. After load, cancelling the caller's task
does not dispose the container; TS has no such coupling. Do not tie a container to a SwiftUI
`.task` of the view that displays it. The app model owns it.

**iOS backgrounding.** On `scenePhase == .background`, call `container.disconnect()` inside
`beginBackgroundTask`, so the in-flight batch can be acked and the service sees a prompt leave.
Pending local ops stay in `PendingStateManager`. On `.active`, call `connect()`: the reconnect
resubmits pending ops and runs the sliced on-main catch-up. If iOS kills the socket while the
app is suspended, the same path runs as a connection error. Ops still unacked when iOS
terminates a suspended app are lost unless stashed; see [Open risks](#open-risks).

**Multiple containers.** Each container has its own loop on its own owner. Several containers on
MainActor share main's budget. Background documents (prefetch, widgets, App Intents) live on
private actors. A container cannot move from one owner to another; to show a background
document, load it again on the new owner.

**Summarizer.** The summarizer is a separate container (as in TS) owned by a private
`SummarizerHost` actor. It loads its own snapshot, so it shares no state with the parent.
Parent to child is async calls with Sendable values, which `Container.swift` already does
(`summarizerChild`, `await child.connect()`). Child to parent is a Sendable job
(`.summarizerStopped(generation)`) yielded into the parent's job queue. The parent no longer
needs to be an actor.

**Deterministic tests and harness peers.** Unit tests are `@MainActor` (Swift Testing) or own the
container from a test actor. They call DDS and container APIs synchronously and await only the
I/O they drive. Harness peers must not block their owner: `FluidServicePeer.main` loops on
blocking `readLine()` on the main thread (`main.swift:55`). That is harmless today because the
containers are actors elsewhere, but it would starve a MainActor-owned loop. Peers should own
their containers in a private `PeerHost` actor, which the spike does, and keep `readLine()` on
main. Ordering stays deterministic: two FIFO sources (commands, socket jobs) interleave on one
serial executor in arrival order, exactly as the Node peers do.

## 6. API and migration

### Public signatures

```swift
// FluidContainerDefinitions: loader.ts IContainer. No longer an actor protocol.
public protocol IContainer: AnyObject {
    var connectionState: ConnectionState { get }
    var isDirty: Bool { get }
    var closed: Bool { get }
    var attachState: AttachState { get }
    var clientId: JSString? { get }
    var audience: any IAudience { get }
    var readOnlyInfo: ReadOnlyInfo { get }
    var containerMetadata: JSObject<JSString> { get }
    var events: ListenerList<ContainerEvent> { get }
    func connect()                        // TS connect(): void
    func disconnect()                     // TS disconnect(): void
    func close(_ error: (any Error)?)     // TS close(error?): void
    func dispose(_ error: (any Error)?)   // TS dispose(error?): void
    nonisolated(nonsending) func getEntryPoint() async throws -> AnyObject
}

// FluidContainerLoader: createAndLoadContainerUtils.ts. Runs on `owner`; the heavy part is an
// internal @concurrent load that returns `sending Container`, then `start(isolation:)` binds it.
public func loadExistingContainer(
    _ props: ILoadExistingContainerProps, isolation owner: isolated any Actor
) async throws -> Container

public final class Container: IContainer { /* container.ts; not Sendable */ }

// FluidDriverDefinitions: storage.ts IDocumentDeltaConnection. Synchronous edge, as in TS.
public protocol IDocumentDeltaConnection: AnyObject, Sendable {
    var details: IConnected { get }
    func attach(_ deliver: @escaping @Sendable (DocumentDeltaConnectionEvent) -> Void)  // TS on("op" | "signal" | …)
    func submit(_ messages: [IDocumentMessage])                    // TS submit(): void
    func submitSignal(_ content: String, targetClientId: String?)  // TS submitSignal(): void
    func dispose()
}

// FluidStatic: fluidContainer.ts IFluidContainer.
public final class FluidContainer {
    public var connectionState: ConnectionState { get }
    public var isDirty: Bool { get }
    public var disposed: Bool { get }
    public var attachState: AttachState { get }
    public var initialObjects: JSObject<any Channel> { get }
    public let events: ListenerList<FluidContainerEvent>  // connected, disconnected, saved, dirty, disposed
    public func connect()
    public func disconnect()
    public func dispose()
    public nonisolated(nonsending) func attach() async throws -> String
    public nonisolated(nonsending) func create<T: SharedObjectKind>(_ kind: T.Type) async throws -> T
}

// FluidOdspClient: odspClient.ts.
public final class OdspClient: Sendable {
    public func getContainer(
        _ id: String, containerSchema: ContainerSchema, isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: OdspContainerServices)
    public func createContainer(
        _ containerSchema: ContainerSchema, isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: OdspContainerServices)
}
```

The spike compiles and runs this exact shape (`Client.getContainer(clientId:snapshot:isolation:)`)
with a MainActor caller (`isolation: MainActor.shared`) and with an actor caller
(`isolation: self` in `PeerHost`). From MainActor the call does not hop; the compiler knows
`MainActor.shared` is the current isolation.

### SwiftUI and UIKit

```swift
@MainActor
@Observable
final class NotesModel {
    private(set) var note: NoteText?
    private(set) var connection = ConnectionState.disconnected
    @ObservationIgnored private var container: FluidContainer?

    func open(itemId: String) async throws {
        let (container, _) = try await client.getContainer(
            itemId, containerSchema: Self.schema, isolation: MainActor.shared)
        guard let text = container.initialObjects["text"] as? SharedString else {
            throw NotesError.missingText
        }
        self.container = container
        note = NoteText(text: text)
        connection = container.connectionState
        container.events.on { [weak self] _ in
            // Same turn as the event: the container's state is current.
            self?.connection = container.connectionState
        }
    }
}

/// UITextViewDelegate for a SharedString. One replica: the view mirrors the DDS synchronously.
@MainActor
final class NoteText: NSObject, UITextViewDelegate {
    let text: SharedString
    weak var view: UITextView?

    init(text: SharedString) {
        self.text = text
        super.init()
        text.sequenceDelta = { [unowned self] event in
            guard !event.isLocal, let view else { return }
            // Ranges resolve against live segments, so they are read here, in the event's turn.
            apply(event, to: view)
        }
    }

    func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
        do {
            if range.length > 0 {
                try text.removeText(range.location, NSMaxRange(range))
            }
            if !string.isEmpty {
                try text.insertText(range.location, JSString(utf16: ContiguousArray(string.utf16)))
            }
            return true
        } catch {
            return false
        }
    }
}
```

`container.events.on` captures `container` itself, which is fine: the closure, the container
and the model are all in MainActor's region. `apply(_:to:)` is the body of today's
`NoteText.receive`, fed by `event.ranges`: edit `textStorage`, then move the selection with
`NSRange.transformed(by:)`.

### Migration steps

1. **FluidContainerDefinitions.** `IContainer: Actor` becomes `IContainer: AnyObject` with TS's
   synchronous `connect`/`disconnect`/`close`/`dispose`. `ListenerList` is unchanged; it is
   already non-Sendable and synchronous.
2. **Container.** Change `public actor Container` to `public final class Container`. Add
   `start(isolation:)` (internal) with the single event loop. It drains one job queue: socket
   events, the turn-based flush, timer fires and summarizer notices. It replaces
   `reader = Task { for try await event in connection.events { try await self.receive(event) } }`
   (`:175`). The noop, summary, summary-ack and presence timers become nonisolated sleeping
   tasks that yield `.timer(id)` jobs; stale ids are ignored. Delete the hop-and-closure APIs
   (`withEntryPoint`, `withPresence`, `onDelta`/`onQuorum`/`onAudience` with `@Sendable`).
   Callers read state and register `ListenerList` listeners directly. The remaining async
   functions become `nonisolated(nonsending)`, or the target turns on
   `NonisolatedNonsendingByDefault`.
3. **Load split.** Move `load()` plus the storage catch-up into an internal `@concurrent`
   function returning `sending Container`. It covers the document service, storage, snapshot,
   protocol state, runtime and stored ops. No task may capture the container inside it, and the
   compiler enforces this (N4). `loadExistingContainer(_:isolation:)` calls it and then
   `start(isolation:)`.
4. **DeltaManager.** It stays synchronous. Add inbound pause/resume and the `deltaScheduler.ts`
   port: check the budget at runtime `batchEnd`, 4 ms on device, and yield with `Task.yield()`.
   The spike shows `Task.yield` on MainActor lets the run loop reach `beforeWaiting`
   (331–501 turns per catch-up run).
5. **ConnectionManager.** It is already `nonisolated(nonsending)`. Keep it, holding the new
   synchronous connection.
6. **Driver edge.** `IDocumentDeltaConnection.submit` and `submitSignal` become synchronous and
   non-throwing, implemented as a FIFO enqueue that the socket actor drains. `sendMessages`
   makes one call per batch with no await. `flushSignals` loses its awaits and its
   `flushingSignals` guard. Inbound events go to an `attach(deliver:)` sink instead of a
   container-side `for try await`. Edge CPU work (parse, decode, decompress) is `@concurrent`.
7. **Summarizer.** The child container moves into a private `SummarizerHost` actor. `summarizerHost: Container` becomes the
   parent's job sink.
8. **fluid-static `FluidContainer` (in flight).** Build it as a non-Sendable final class over
   `Container` with the synchronous TS surface above, not an actor. `OdspClient.getContainer`
   takes `isolation:`.
9. **FluidNotes.** Delete `TextSync.swift`, `SharedStringSync.swift` and
   `FluidNotesTests/TextSyncTests.swift`. In `NotesModel`, delete `SessionEvent`, both
   `AsyncStream`s, the `session(_:inbound:outbound:)` function and the two tasks. The model
   holds the container and builds `NoteText(text:)`. `NoteText` edits the SharedString in
   `shouldChangeTextIn` and applies `sequenceDelta` to `textStorage`. Keep `TextEdit.swift` for
   the selection transform. Drop `TextSync.swift` from the test target in `project.yml`.
10. **Harness peers.** Put the containers in a private `PeerHost` actor so blocking `readLine()`
    on main never starves an event loop.
11. **Tests.** Container tests become `@MainActor` or own a test actor. Synchronous reads lose
    their `await`.

### Rejected alternatives

- **(A) Private-executor actor plus an app-side sync layer.** It breaks I1 and I6 at the app
  boundary and I3 inside (spike [4]). It needs an OT layer per DDS, which is infeasible for
  Matrix and Tree. It costs a 13.5 µs round trip per keystroke and two hops per remote op.
- **(B) Actor with an injectable executor (SE-0392).** On MainActor's executor it behaves like
  (D), but the type system still sees two domains. The UI cannot keep a DDS reference (N1),
  synchronous access works only in synchronous code (N8), and every crossing callback needs a
  runtime-trapping `assumeIsolated` (138–195 ns). An actor's executor is fixed for its
  lifetime, so it cannot load off-main and then run on main. A switching executor would be
  serial, but UI code would trap or buffer edits whenever it is in background mode, which
  brings back a second replica during catch-up.
- **(C) `@MainActor` on every class.** It forces load, summarization, harness peers and tests
  onto main. A `@MainActor` class's methods run only on main, so snapshot hydration and
  catch-up cannot run off-main and be adopted later. A load then means the 0.9 s freeze of R2
  plus the snapshot parse. It also writes a UI actor
  into a port whose layers mirror TS packages. (D) gives the same UI ergonomics when the owner
  is MainActor, without that cost.
- **A Fluid global actor (`@FluidActor`).** It is (A) with all containers serialized on one
  executor: the UI still hops.
- **Task executor preference (SE-0417).** It applies only to nonisolated async code and does not
  move actor-isolated state (`withTaskExecutorPreference` compiles in 6.4 but does not apply).
- **`isolation: isolated (any Actor)? = #isolation` on `start`/`getContainer`.** Unsound in 6.4
  (N6, TSan-confirmed). It would save one argument at the call site.
- **`AsyncSequence` events.** They lose the same-turn guarantee (spike [3]) and coalesce
  (`Observations`, spike [2]).

## Open risks

1. **Long reconnect catch-up on main.** Slicing keeps frames, but the total is still about 1 s
   per 3000 SharedString ops. The port's merge-tree is 2.8–3.8× slower than TS
   (`RESULTS.md`), and that is the lever. A reload-and-swap path (load fresh off-main, transfer
   pending ops through stashed state) is possible, but it changes DDS object identity under the
   UI. Not designed here.
2. **`Task.yield` and Core Animation on iOS.** Measured on macOS only: the run loop reached
   `beforeWaiting` between slices. Verify on a device with Instruments' hitch tracing, and
   compare against a timer-based yield (R4).
3. **Several MainActor containers.** Each has its own 4 ms budget, so several busy containers
   could exceed a frame together. A shared main-thread scheduler may be needed.
4. **Toolchain edges.** The N6 hole, and the region checker failing on `TaskGroup.addTask` in a
   loop. Later compilers may tighten or change these rules. Keep `Negative/check.sh` in CI for
   the design's load-bearing diagnostics.
5. **IME marked text.** Applying remote edits inside a `UITextView` marked-text range during
   composition needs care. This is editor work, independent of threading.
6. **Delta scheduler budget versus TS.** 4 ms instead of 50 ms means more interleaving points
   during catch-up, so local ops may carry different reference sequence numbers than a TS
   client's would. Any valid refSeq is correct, but the differential harness must not compare
   timing-dependent refSeqs.
7. **Termination while backgrounded.** Unacked local ops are lost unless pending state is
   stashed to disk (TS `getPendingLocalState` / `applyStashedOp`).
8. **The spike's DDS is a stand-in.** Op cost is a memmove over a 4M-unit array (106–160 µs/op);
   the real costs are in `RESULTS.md`. All numbers are macOS on an M1 Max, not an iPhone.

## Evidence

Spike: `.build/threading-opus/`, a standalone SwiftPM package, `swift-tools-version: 6.2`,
`swiftLanguageModes: [.v6]` (complete strict concurrency), zero warnings. It sits inside the
repo's gitignored `.build/`, so `swift package clean` or deleting `.build` removes it.

- `Sources/FluidModel/` stands in for the port's layers. `Container.swift` is the
  owner-isolated container: `start(on:)` event loop, turn-based flush, delta scheduler,
  synchronous FIFO submit. `Loader.swift` holds the `@concurrent` load returning `sending` and
  the `Client.getContainer(…, isolation:)` API. `DeltaConnection.swift` is the synchronous edge.
  `OrderingService.swift` applies deli's CSN rules. `DDS.swift` holds the SharedString and
  SharedMap stand-ins. `Alternatives.swift` holds the (A) and (B) shapes.
- `Sources/Spike/` holds the claims, the frame probe (a 1 ms main-queue timer plus a CFRunLoop
  `beforeWaiting` observer) and the benchmarks.
- `Negative/` holds the compile-failure cases, `check.sh`, and the N6 race demo.

Commands, run from `.build/threading-opus`:

```sh
swift build -c release
./.build/release/Spike claims      # [1]–[4], [6]
./.build/release/Spike load        # [5] R1–R4
./.build/release/Spike bench       # [7]
./Negative/check.sh                # N1–N8
swift build --sanitize=thread --build-path .build-tsan
./.build-tsan/debug/Spike claims   # 0 ThreadSanitizer reports
./.build-tsan/debug/Spike load     # 0 ThreadSanitizer reports
swiftc -swift-version 6 -parse-as-library -sanitize=thread Negative/N6-race-run.swift -o /tmp/n6 && /tmp/n6
```

Results (host load average 9–16 from other agents' builds during every run):

- **[1] Owner-isolated UI.** All checks passed. The MainActor `EditorModel` holds the DDSes,
  types 200 characters synchronously, and applies 200 remote deltas inside `sequenceDelta` on
  main, with the view equal to the DDS inside every event. A peer container owned by a private
  actor applied the same 629 ops off main. 0 nacks, 0 duplicates. The SharedMap converged.
- **[2] Observation.** A change to key `b` did not invalidate a reader of `a`. `onChange` fired
  synchronously on main inside op apply and read the old value (nil). The listener read the new
  value. `Observations` returned 1, then 4 after three changes.
- **[3] AsyncSequence.** The listener read `[1, 2, 3]`; the `AsyncStream` consumer read
  `[3, 3, 3]`.
- **[4] Reentrancy.** Today's actor with `async` submit sent CSN 3 before CSN 2 in 199/200 and
  197/200 trials (deli gap nack). The owner-isolated container with synchronous FIFO submit had
  0 nacks and 0 duplicates over 400 ops from five interleaving writers.
- **[5] Load** (5.3 MB snapshot JSON, 4M-unit string, 100K keys, 3000 ops behind; three clean
  runs):

  | Run | Wall time ms | Longest Fluid slice ms | Main max gap ms | Dropped 120/60 Hz | Run-loop turns | Keystroke |
  |---|---:|---:|---:|---|---:|---|
  | R1 off-main load + catch-up | 412–584 | — (off main) | 1.25–1.88 | 0/0 | 412–586 | — |
  | R2 on main, unsliced | 760–955 | 759–954 | 759–954 | 1/1 (one long gap) | 3 | waited for the whole catch-up |
  | R3 on main, 4 ms, `Task.yield` | 770–1035 | 7.9–9.2 | 8.0–9.2 | 0–2 / 0 | 335–384 | ran mid-catch-up (seq 70–98) |
  | R4 on main, 4 ms, `Task.sleep(1µs)` | 711–1154 | 5.9–9.5 | 6.0–9.6 | 0–1 / 0 | 331–501 | ran mid-catch-up (seq 20–91) |

  The R1 hand-off took 0.04–0.05 ms. A first run under heavier contention (load average 15)
  recorded R1 at 25.9 ms and R3 at 89 ms max gap and was discarded as noise; the three later
  runs agree. The view-update cost is included in R2–R4 (the editor is open), but not in R1
  (the UI binds after load).
- **[6] Injected executor.** A MainActor-executor actor was entered with `assumeIsolated` from
  synchronous MainActor code and ran on main. A `DispatchSerialQueue` executor ran off main.
- **[7] Benchmarks.** See the hop-cost table in §2.
- **Negative cases** (`Negative/check.sh`, each compiled with
  `swiftc -swift-version 6 -parse-as-library -emit-sil`, because region checks run on SIL and
  `-typecheck` misses them):

  | Case | Result |
  |---|---|
  | N1 (B) keep a DDS from `assumeIsolated` | rejected: `type 'SharedString' does not conform to the 'Sendable' protocol` |
  | N2 (D) send a MainActor-owned container to an actor | rejected: `sending 'self.container' risks causing data races` |
  | N3 (D) `Task.detached` touches a MainActor-owned DDS | rejected: `non-Sendable type 'SharedString' of property 'text' cannot exit main actor-isolated context` |
  | N4 (D) start the loop in the loader, then return `sending` | rejected: `sending 'container' risks causing data races` |
  | N5 (A) `@Sendable` listener captures a DDS | rejected: `capture of 'text' with non-Sendable type 'SharedString' in a '@Sendable' closure` |
  | N6 optional `#isolation` owner | **compiles**; TSan: data race, lost updates in 30/50 runs |
  | N7 plain `async` method called from owner code | rejected: `sending 'self' risks causing data races` (accepted with `NonisolatedNonsendingByDefault`) |
  | N8 (B) `assumeIsolated` in an async function | rejected: `instance method 'assumeIsolated' is unavailable from asynchronous contexts` |
- **Also verified to compile in 6.4:** `Task.immediate` (SE-0472) and
  `withTaskExecutorPreference` (SE-0417).

## Convergence round

A second pass, after reading `specs/design/threading-astra.md` and its spike in
`.build/threading-astra/`. The brief's list of agreements is accurate. Two more belong on it:
both designs keep `ListenerList`-style synchronous listeners with explicit unsubscription, and
both keep outbound compression inside the synchronous flush, because CSN allocation follows it.
Astra's account of the `Outbox.virtualizeBatch` order is the more precise one.

**Their spike.** Where the two spikes measure the same thing, the numbers agree. The checked
`assumeIsolated` bridge is 153.66 ns (mine: 138–146). MainActor → default actor → MainActor is
11.5 µs (mine: 13.5–13.8), and through a Dispatch-queue actor it is 14.3 µs (mine: 14.4–16.2).
Their four rejection probes match my N2–N4. Their spike has no outbox, flush, submit,
multi-message batches or catch-up yielding, so points 2 and 3 rest on the TS source and on two
claims I added to my spike, [8] and [9].

**New evidence.** Run from `.build/threading-opus` (Swift 6.4, M1 Max, host load average 3–8):

```sh
./Convergence/check.sh                                # P1 compiles; M1–M7 rejected
swift build -c release && ./.build/release/Spike batches    # [8], [9]; three runs
swift build --sanitize=thread --build-path .build-tsan
./.build-tsan/debug/Spike batches                     # 0 ThreadSanitizer reports
```

`Negative/check.sh`, `Spike claims` and `Spike load` still pass. The R3 rerun gave a 6.91 ms
max gap, inside the earlier 6.0–9.6 ms range.

### 1. Public ownership API: synthesize

**Astra's objection does not apply to an `isolated` parameter.** It applies to an `executor:`
value, which the type system cannot see (that is candidate B). An `isolated any Actor` parameter
isolates the callee to its argument, and the non-Sendable result can only be returned to a
caller with that same isolation. `Convergence/check.sh` compiles
`loadExistingContainer(isolation:)` against each misuse:

| Case | Result |
|---|---|
| M1: a MainActor caller names another actor as owner | rejected: `non-Sendable 'Container'-typed result can not be returned from actor-isolated global function 'loadExistingContainer(isolation:)' to main actor-isolated context` |
| M2: a `@concurrent` caller names `MainActor.shared` | rejected: the same error, `… from main actor-isolated global function … to @concurrent context` |
| M3: the right owner, then the local result is sent to another actor | rejected: `sending 'container' risks causing data races` |
| M6, M7: the owner given as `#isolation!` (from MainActor, from `@concurrent`) | rejected, as in M1 and M2 |

A wrong owner is therefore a compile error, not a silent change in safety. My form does give the
compiler static proof that the container, and every DDS reached from it, is used only on that
owner. The proof comes from region isolation. Its one known hole is the optional `#isolation`
default (N6), and neither design uses that form for anything that starts a task.

**Astra is right that apps should not have to make this choice.** Every app passes
`MainActor.shared`, so in an app the argument is noise. A `@MainActor` class is also checked by
global-actor isolation, which is older than region checking, gives clearer diagnostics and has
fewer edge cases (in 6.4 the region checker rejected a `TaskGroup` loop with "please file a bug", §3). And the
facade is Sendable as a handle: a detached task or a Sendable registry can hold it and `await`
it, while its DDSes still cannot leave main.

| Case | Result |
|---|---|
| P1: a `@MainActor FluidContainer` wraps the loader container. The app model keeps a DDS and a listener; a `PeerHost` actor owns a loader container whose listener appends to the actor's own state; `Task.detached` captures the facade | compiles, no warnings |
| M4: `Task.detached { await container.initialObjects.edit() }` | rejected: `non-Sendable type 'DDS' of property 'initialObjects' cannot exit main actor-isolated context` |
| M5: a DDS read from the facade on main is sent to another actor | rejected: `sending 'text' risks causing data races` |

This also matches the TS layering. fluid-static's `IFluidContainer` is the app API, and the
summarizer and the service peers use the loader's `IContainer`. `FluidServicePeer/main.swift`
already calls `loadExistingContainer` directly rather than going through fluid-static.

**Reject Astra's headless `actor Container` with `transaction { (isolated Container) in … }`.**
It is the same scoped access Astra rejects in B: callers cannot keep a DDS outside a
transaction. A listener registered inside the `@Sendable` body cannot touch the host's own state
synchronously, because that state sits outside the library's actor. A service peer that records
state at event time would have to hop, which breaks I6 again. It is also a second access model to
document and test. The explicit-owner loader API gives a headless host the same direct access an
app has (P1's `PeerHost`).

**Hold synchronous lifecycle methods.** `FluidContainer.connect()`, `disconnect()` and
`dispose()` stay synchronous, as TS declares them (`fluidContainer.ts` lines 205, 217, 248).
Astra's `async` versions add await points where TS has none (I7). A synchronous `dispose()`
trivially satisfies Astra's own rule (set the terminal state before any wait). Socket teardown
finishes the outbound FIFO and needs no await.

### 2. Catch-up yielding: concede where, hold the budget

**What TS does.** `deltaQueue.ts` `processDeltas` (lines 158–176) drains while the queue is
non-empty, not paused and error-free. During catch-up, only `DeltaScheduler` pauses it, and only
from its `batchEnd` handler (`deltaScheduler.ts` 88–139). `containerRuntime.ts` emits `batchEnd`
after the last message of a batch (`processInboundMessages`, lines 3576 and 3668–3671). A grouped
batch is one sequenced message, expanded inside one worker call. A chunked op reaches
`batchEnd` only with its last chunk. So TS never pauses inside a batch, during a grouped-batch
expansion or partway through reassembly. It pauses only when more ops are queued
(`shouldRunScheduler`, 176–180) and the slice has passed 50 ms. That limit grows by 10 ms per
further turn and resets at idle. The Swift runtime already emits both events
(`ContainerRuntime.swift:183`, `:218`).

**Concede.** Astra's rule is correct, and my spike was looser than my own text. Migration step 4
says to check the budget at `batchEnd`, but the spike yielded after any message once the slice
ran over. That matched step 4 only because every spike message was a batch of one. The spike now
yields only when `message.batchEnd` is true, and the seeded ops arrive in runtime batches of 1–8
messages.

**Where catch-up may yield.** This is the complete list:

1. Only in the owner's event loop, immediately after a runtime `batchEnd`, and only when more
   inbound messages are queued and the slice is over budget.
2. Never in the synchronous core. That rules out DeltaManager, runtime and DDS processing,
   grouped-batch expansion, chunk reassembly, a listener and a flush. It also rules out the step
   between an inbound op flushing the open local batch and that op being processed: the two
   happen together, synchronously.
3. A local edit made in the gap gets the batch end as its refSeq, and the next inbound message
   flushes it before that message applies ([9]). In TS, `outboxSequenceNumberCoherencyCheck`
   throws if that ever breaks. The Swift port does not have this check yet. Port it too.

Anything that can run in such a gap could also run between two TS batches, at a socket delivery
or at a scheduler pause. [8] measures this with 3000 ops in 429 batches, applied to a 1M-unit
string on main, over three runs:

| Run | Event trace, nothing else running | A keystroke posted into every gap |
|---|---|---|
| No slicing | the baseline; 82–121 ms | none ran mid-catch-up |
| 4 ms budget, yield at batch ends | identical to the baseline; 19–21 yields | 18–21 ran mid-catch-up and none saw a half-applied batch. Every op's refSeq was a batch end. Longest slice 4.83–5.32 ms; 81–93 ms total |
| Budget 0, yield at every batch end | identical; 428 yields | 428 ran and none saw a half-applied batch. Every refSeq was a batch end |
| Budget 0, yield after any op (the hazard) | identical; 2999 yields | 2574–2591 of about 3000 ran inside a half-applied batch, and their ops carried mid-batch refSeqs |

Where catch-up yields never changes the trace by itself. The damage comes from work that runs in
a gap inside a batch. That is Astra's hazard, now reproduced.

**Budget: hold a fixed 4 ms slice, without the 10 ms per-turn increment.** 4 ms leaves room in
an 8.33 ms frame and stays under the roughly 5 ms of main-thread update work that Apple's
guidance says usually finishes in time (Astra's citation). TS grows the slice so that a long catch-up still finishes "fairly quickly"
(`deltaScheduler.ts` 106–108). A fixed slice already does that in Swift, because a yield on main
costs 18–38 µs (§2): the 4 ms runs took 81–93 ms, against 82–121 ms unsliced. A slice overruns
by at most one batch (5.32 ms worst case). Use one constant for every owner. On a private owner,
a yield costs microseconds and lets that owner's timers run, which is what the TS pause is for.

**How the differential harness stays exact.** The lockstep harness never runs the event loop.
One request is in flight at a time, `process` delivers one sequenced message, and `flush` is
explicit (`harness/PROTOCOL.md`). Peers call the synchronous core directly; for example,
`FluidRoutingPeer/main.swift:69` calls `runtime.processInboundMessages`. The scheduler lives only
in the owner's loop, so no budget can change a lockstep trace. The rule is to keep it there, and
never in DeltaManager or the runtime. Live service runs compare converged state, because TS's
own 50 ms wall-clock rule makes its refSeqs depend on timing too (open risk 6). [8] tests the
property that is exact: the same log under budgets of nil, 4 ms and 0 gives identical event
traces, and with injected edits every refSeq is a batch end. That test belongs in the container
tests.

### 3. Local flush: hold the mechanism, reject `edit {}`

**Both designs use the same mechanism.** Astra's "owner-local coalesced flush wake-up" is my
`.flush` job. `submitLocal` appends to the outbox and posts one `.flush` job per turn into the
container's own FIFO. Each inbound message calls `flush()` before it applies. There is no Task
per edit and no await. [9] measures it. 50 edits in one synchronous turn sent nothing during the
turn and one 50-message batch after it. With an inbound op already queued, a new local edit's
batch was flushed before that op applied (`flushSizes [50, 1]`) and carried the refSeq from
before the inbound op.

**Compared with TS.** TS schedules `Promise.resolve().then(flush)` (`containerRuntime.ts`
5396–5434), a microtask that runs before the next macrotask. Inbound ops still close a batch by
calling `flush()` directly (the comment at 5397–5402). The Swift job runs after whatever is
already queued on the owner, and that same direct flush on the inbound path covers the gap. One
difference remains: two app turns queued back to back before the flush job can share one batch,
where TS would send two. That is legal, because the ops come from the same client with the same
refSeq in the same order. Only the number of batches changes.

**Astra is right about one gap in the port.** Today the only thing that sends is
`Container.withEntryPoint`, which flushes at the end of its body (`Container.swift:613–620`).
The Swift `ContainerRuntime.submit` has no `scheduleFlush`. Port `scheduleFlush` into
`ContainerRuntime`, including `FlushMode.Immediate` and the staging-mode threshold. Its
TurnBased case calls a hook that the container injects, which posts `.flush` to the owner's
loop. That hook is the Swift `Promise.resolve().then`. My migration step 2 lists the flush job
but did not name this wiring.

**Reject `edit {}`.** fluid-static has no such API, and the flush job already sends every
direct edit. The scope would also change batching: `edit { a }; b` in one turn would send two
batches where TS sends one. For an atomic compound edit, TS has
`ContainerRuntime.orderSequentially` (`containerRuntime.ts:3914`), with rollback. Port that if a
caller needs it. Tests that need their ops on the wire wait for the flush job, as [9] does.

### 4. The rest of Astra's doc

Better than mine; adopt:

- **TS's guards after its awaits.** "Await only where TS awaits" is not enough by itself. Each
  of those awaits needs the check TS runs after it: a single in-flight connection
  (`connectionManager.ts`, `pendingConnection` at line 151 and lines 515–557), a disposed or
  aborted check after each await (567, 719), and a stale gap-fetch check. Port them as TS has
  them. Astra's connection generation is the same idea.
- **SharedString's reentrancy guard stays** (`sequence.ts` 383–395). A serial owner does not
  replace it.
- **Region diagnostics need SIL.** Astra found the same thing I did: `swiftc -typecheck` misses
  `sending` errors. CI runs `Negative/check.sh` and `Convergence/check.sh`, which compile to SIL.
- **Never stream a live `SequenceDeltaEvent`.** Astra states this, and the Outbox ordering
  argument for synchronous compression, more precisely than I did.

Weaker; hold mine:

- **Bootstrap cutover.** Astra specifies, without implementing it, a handoff that stops at a
  boundary and packages a checkpoint with the remaining events. Mine is simpler and already runs
  in [1] and [5]. The loader never reads the socket stream. From connect onward, the stream
  buffers into the container's job queue, and the owner's loop skips any op at or below its last
  sequence number (`deltaManager.ts` does the same with `lastQueuedSequenceNumber`). There is no
  second iterator and nothing to package.
- **A "background mode with a UI replica" escape hatch** for oversized catch-up keeps candidate
  A's OT layer as an option. Leave it out. The lever for a slow catch-up is merge-tree speed (open
  risk 1).
- **`isolation: isolated (any Actor)? = #isolation` on shared helpers** is fine for a helper
  that finishes before it returns. It is unsound for anything that starts or stores a task (N6;
  TSan reported races in 30 of 50 runs). State that rule wherever the form appears.
- **The layering note is out of date.** `FluidContainerLoader` no longer imports `FluidStatic`
  (`Package.swift`). The synthesis needs one new dependency, `FluidOdspClient` →
  `FluidContainerLoader`, just as TS `odsp-client` depends on `container-loader`. It creates no
  cycle.

### Final API signatures

```swift
// FluidStatic: fluidContainer.ts IFluidContainer. The app API; it owns its graph on main.
@MainActor
public final class FluidContainer {
    public var connectionState: ConnectionState { get }
    public var isDirty: Bool { get }
    public var disposed: Bool { get }
    public var attachState: AttachState { get }
    public var initialObjects: JSObject<any Channel> { get }
    public let events: ListenerList<FluidContainerEvent>  // connected, disconnected, saved, dirty, disposed
    public func connect()                                 // TS connect(): void
    public func disconnect()                              // TS disconnect(): void
    public func dispose()                                 // TS dispose(): void
    public func attach() async throws -> String
    public func create<T: SharedObjectKind>(_ kind: T.Type) async throws -> T
}

// FluidOdspClient: odspClient.ts. No owner argument; the result belongs to MainActor.
public struct OdspClient: Sendable {
    public init(properties: OdspClientProps)
    @MainActor public func getContainer(_ id: String, containerSchema: ContainerSchema)
        async throws -> (container: FluidContainer, services: OdspContainerServices)
    @MainActor public func createContainer(_ containerSchema: ContainerSchema)
        async throws -> (container: FluidContainer, services: OdspContainerServices)
}

// FluidContainerLoader: the headless layer (summarizer child, service peers, background documents).
public final class Container: IContainer { /* container.ts; a plain class, not Sendable */ }
public func loadExistingContainer(
    _ props: ILoadExistingContainerProps, isolation owner: isolated any Actor
) async throws -> Container

// Internal: the off-main half (document service, snapshot, protocol state, runtime, stored ops).
@concurrent
func prepareContainer(_ props: ILoadExistingContainerProps) async throws -> sending Container
```

`IContainer`, `IDocumentDeltaConnection` (synchronous `submit` and `submitSignal`) and the
ConnectionManager notes in §6 are unchanged. Inside the runtime, `ContainerRuntime` gains TS's
`scheduleFlush`, and its TurnBased case calls the hook the container injects to post `.flush`.

### Verdict

Verdict: converged.

The merged design gives each container one plain, synchronous, non-Sendable graph with exactly
one owner. Apps use fluid-static's `@MainActor FluidContainer`, which `@MainActor
OdspClient.getContainer` returns without an owner argument. Headless hosts (the summarizer
child, service peers and background documents) use the loader's `Container` through
`loadExistingContainer(_:isolation:)`, which takes a non-optional `isolated any Actor`. The
compiler checks both paths (M1–M7). Loading runs in a `@concurrent` function that returns the
graph as `sending`. DDS and container events are synchronous listeners on the owner;
Observation and AsyncSequence are app-side adapters. FluidNotes' OT layer is deleted, and its
native text, selection and IME adapter stays. `submit` is a synchronous FIFO enqueue. The ported
`scheduleFlush` posts one flush job per turn to the owner's loop, and inbound ops flush the open
batch first. Catch-up yields only in that loop, at a runtime `batchEnd` with more ops queued, on
a fixed 4 ms slice. The lockstep harness bypasses the loop. Lifecycle methods are as synchronous
as TS's, with TS's connection guards after each await. I reject three of Astra's items: the
transaction-scoped headless actor, `edit {}`, and the async lifecycle methods. Each departs from
TS, and each has a TS-faithful replacement above, so I do not count them as open disagreements.
