# Native Fluid threading: put the interactive graph in the UI's isolation domain

Independent design by Astra, 2026-11-06. Scope: design and standalone language/runtime experiment only. No production sources, examples, harness files, or git state were changed.

## Decision

**Choose D: one synchronous, non-Sendable container core, with statically isolated owners. The app-facing `FluidContainer` owns its core on `MainActor`; the background/headless `Container` actor owns a different core.** They reuse the same protocol/runtime/DDS/lifecycle implementation, not two implementations of Fluid. A summarizer is a separate background container with a separate graph and connection.

This is C's simple app API without C's library-wide main-thread restriction. It preserves architecture §2's important rule—one isolation domain per live container, synchronous DDS code—without requiring a distinct executor for every container. Multiple UI containers share MainActor; their graphs are still independent.

Do **not** make `FluidContainer` a MainActor façade around a background actor that still owns its DDSes. It must own the graph itself. Do not annotate every DDS `@MainActor`; plain synchronous DDS classes remain usable by either owner.

For FluidNotes, remove the cross-executor text replica protocol. Keep a thin native editor adapter: UTF-16 editing, selection/reference tracking, IME handling, undo, and incremental text-storage updates are still real work. The merge-tree remains the collaboration algorithm; UIKit should not need a second collaboration algorithm merely to reach it.

## Evidence and baseline

Inspected this checkout while other agents were working; line references below describe the inspected version, not a stable commit. In particular, `FluidContainer.swift` and `OdspClient.swift` did not exist when inspected, although NotesModel already calls their planned API. I did not inspect the other designer's answer.

Toolchain actually run:

```text
swift-driver version: 1.168.6 Apple Swift version 6.4
(swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx27.0.0
Apple M1 Max; macOS 27.0 (26A428)
```

The repository manifest uses tools 6.2, iOS 18/macOS 15. The spike explicitly uses **Swift language mode 6**, `-strict-concurrency=complete`, and `-warnings-as-errors`, with no default-MainActor or upcoming-feature flag. Compiler 6.4 is not proof of behavior on compiler 6.2 or the oldest supported OS. Those remain compatibility gates.

### Source observations

- [ARCHITECTURE.md §2](../../ARCHITECTURE.md): the executor rule applies to the entire owned graph, not independently to every DDS.
- [Container.swift](../../Sources/FluidContainerLoader/Container.swift), lines 16, 98–179, 317–409, 507–519, 649–710, 764–800: actor ownership; load and connection suspensions; synchronous `drain`; asynchronous gap fetch and send; `withMap` mutates before awaiting network; child summarizer and shutdown.
- [ConnectionManager.swift](../../Sources/FluidContainerLoader/ConnectionManager.swift), lines 9–40: synchronous mutable connection state; `nonisolated(nonsending)` connection/disconnection helpers. A connection is assigned before handshake suspension and client identity afterward.
- [DeltaManager.swift](../../Sources/FluidContainerLoader/DeltaManager.swift), lines 62–89 and 140–159: sequence sorting/deduplication/gap gating, processed events, and client sequence allocation. `pending.removeFirst()` and repeated sorting are potential backlog costs, not actor costs.
- [Events.swift](../../Sources/FluidContainerLoader/Events.swift), lines 5–26: `ListenerList` stores ordinary synchronous closures. Container's public `onDelta/onQuorum/onAudience` currently demand `@Sendable`; that is a boundary restriction, not an emitter requirement.
- [DocumentDeltaConnection.swift](../../Sources/FluidDriverBase/DocumentDeltaConnection.swift), lines 12–29, 34–62, 94–123, 166–180: socket actor, handshake buffering, a single typed stream, cooperative disposal. The mutex protects synchronous handshake-details access; it does not justify adding locks to DDSes.
- [DocumentService.swift](../../Sources/FluidDriverDefinitions/DocumentService.swift), lines 43–91: Sendable service/storage/connection protocols and Sendable transport events; delta stream disposal belongs to the caller, not service disposal. These are good I/O boundaries. Container still uses older concrete/raw socket APIs and needs adaptation to this new surface.
- [SharedString.swift](../../Sources/FluidSequence/SharedString.swift), lines 6–38: synchronous UTF-16 reads/inserts/removes. `getText` builds the result by scanning segments; do not call it for the whole document on every keystroke.
- [SharedSegmentSequence.swift](../../Sources/FluidSequence/SharedSegmentSequence.swift), lines 16, 61–69, 119–131: inline delta callback after local submission, and explicit synchronous reentrancy guard.
- [SequenceEventClass.swift](../../Sources/FluidSequence/SequenceEventClass.swift), lines 17–35: `ranges` lazily resolves positions from the current client. The event is not an immutable, historical snapshot.
- [SharedMap.swift](../../Sources/FluidMap/SharedMap.swift), lines 21–60: synchronous value-change callback, reads and writes.
- [NotesModel.swift](../../Examples/FluidNotes/FluidNotes/NotesModel.swift): `@MainActor` model, two FIFO streams, `session(_ container: isolated FluidContainer, ...)`. [SharedStringSync.swift](../../Examples/FluidNotes/FluidNotes/SharedStringSync.swift) correctly materializes lazy ranges inside the event. [TextSync.swift](../../Examples/FluidNotes/FluidNotes/TextSync.swift) tracks unacknowledged local edits and transforms crossing edits. [NoteEditor.swift](../../Examples/FluidNotes/FluidNotes/NoteEditor.swift) keeps a second text copy and transforms selections.
- [harness/PROTOCOL.md](../../harness/PROTOCOL.md): one JSON-RPC request in flight; deterministic driver/sequencer; protocol output on stdout and logs on stderr. Most channel peers need no asynchronous host at all.

## 1. Correctness: the turn is the unit, not the task

### Required invariants

1. **Local apply is synchronous.** On return from a DDS edit, local visible state, pending-operation bookkeeping, and that edit's synchronous events have happened. This does not mean the server has acknowledged it, or even that the socket has sent it. A UIKit input callback can apply the edit and read the resulting DDS state without another remote op intervening.
2. **Process sequenced operations in order.** Deduplicate replay, stop at gaps, fill them, validate sequence/client/MSN invariants, then process. Scheduling order of unrelated Swift Tasks is not a sequencer.
3. **An apply stack is indivisible with respect to other tasks.** Protocol processing, runtime routing, DDS mutation, synchronous listeners and required bookkeeping have no `await`, queue dispatch or detached task between them. The TypeScript [deltaManager.ts](../../reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts), lines 1090–1186, sets `currentlyProcessingOps`, validates, calls `handler.process`, clears the flag, then emits `op`.
4. **Event order is observable.** A `sequenceDelta` listener reads positions/state corresponding to the event while that synchronous stack is active. The TypeScript [sequence.ts](../../reference/fluidframework-3.11.0/packages/dds/sequence/src/sequence.ts), lines 548–560, submits local changes before emitting delta events. Do not move these events to another queue or await listeners.
5. **Serialization does not outlaw synchronous reentrancy.** A listener can call back into the same stack. Preserve DDS-specific guards and permitted behavior, including SharedString's default prohibition of reentrant local mutations (`sequence.ts`, lines 385–395). A serial actor does not replace this guard. Read-only listeners remain useful and valid.
6. **Preserve transaction/batch boundaries, not merely integer sequence order.** TS [deltaQueue.ts](../../reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts), lines 158–176, drains until empty/paused/error, explicitly requiring same-turn processing for grouping. Arbitrarily yielding every N logical ops can change observer and batching semantics even if final text converges. Never yield inside grouped batch expansion or local transaction completion.

An event's “same state” guarantee is not perpetual immutability: earlier synchronous listeners might legally mutate another DDS; retaining the live event and consulting it later is not supported. If an asynchronous consumer needs historical values, capture a value snapshot in the original listener.

### Actor reentrancy is a separate correctness problem

A function being actor-isolated does not make its entire async execution atomic. [SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md) permits other work during suspension. The spike deterministically reads 0, awaits a gate, lets another call write 99, then resumes and overwrites it with 1. Neither MainActor nor a custom serial executor fixes that.

Current risks to resolve during migration, rather than assume away:

- Two callers can enter `connect()` while `protocolHandler == nil`; `disconnect()` can happen during storage/handshake waits. MainActor would still allow this. Serialize connection attempts with a single in-flight task plus monotonically increasing lifecycle/connection generation. After every external await, check cancellation, generation and terminal state before installing results. Dispose stale returned connections.
- `sendMessages` loops with an await per message; separate invocations may interleave at those awaits. A single ordered writer must own the transport send sequence. `flushSignals` already has a one-writer guard, but separate op/signal writers must preserve any required cross-kind ordering too.
- A gap fetch can return after a disconnect/reconnect or newer storage fetch. Merge only into its valid generation; do not overwrite newer protocol state.
- Shutdown must mark terminal state **before** waiting for children or sockets. Late events cannot resurrect a disposed container.

Use synchronous core transitions that return effects; perform I/O outside them, then synchronously consume validated results. Never hold a “currently processing op” flag across an await or await user code during apply. `nonisolated(nonsending)` avoids an isolation transfer; it does not prevent reentrancy across its suspension points.

### Local edits must also leave the device

Direct DDS access must not lose the flush currently supplied by `Container.withMap` (lines 514–518). During adoption, connect runtime submission to an owner-local **coalesced flush wake-up**: a synchronous submission hook marks pending work and yields a token to an already-running owner pump. It does not create a Task per edit and does not await. The pump flushes only after the current edit/event stack unwinds; before applying another incoming transaction it first closes any pending local turn whose reference sequence must remain fixed. Outbox grouping, pending registration and physical CSN preparation remain synchronous on the owner; only immutable prepared messages cross to the single socket writer. Preserve the runtime's configured immediate/turn-based batching contract, and differential-test the boundary rather than assume Swift task scheduling equals JS microtask scheduling.

For compound app edits expose a synchronous `edit` scope that closes the local turn before returning; it can throw a flush error but never waits for a network acknowledgment. Direct DDS mutations still wake the automatic pump. This is essential for a raw `initialObjects` API: without it a locally successful keystroke could sit unsent until unrelated network activity. The synthetic spike does not implement Fluid outbox semantics.

### Candidate verdicts

| Candidate | Core ordering | Synchronous UIKit/DDS turn | Decision |
|---|---|---|---|
| A: separate container actor + UI replica | Yes, if apply is synchronous and ingress ordered | No: two independently editable states | Valid optional background-client architecture, wrong default editor API. Requires replica reconciliation, stable anchors, or forbidding optimistic UI edits. |
| B: actor on MainActor executor | Yes, with immutable executor and synchronous apply | Yes through checked `assumeIsolated` + isolated access | Technically works, demonstrated. Reject as default public API: shared execution is not shared static isolation, and raw DDS/closure bridging is not free. |
| C: everything `@MainActor` | Yes, absent suspension/reentrancy mistakes | Yes, naturally | Reject library-wide isolation: forces headless clients, bootstrap and summarizers onto UI's domain. |
| D: plain shared core + MainActor UI owner / background actor owner | Yes; exactly one owner per graph | Yes for UI-owned graphs | **Recommend.** Small ownership boundary, direct DDS API, background reuse without unchecked transfer. |

### Is a second OT layer ever necessary?

For A's particular optimistic design, **some reconciliation is necessary**. UI inserts at offset 10 while the background DDS receives a remote insertion before offset 10; an unversioned `insert(10)` command is now referring to the wrong place. Main-thread responsiveness does not eliminate this race, and actor FIFO would not solve it. Two-party OT is one valid solution; anchored operations with versioned acknowledgements or an editor-native replica are alternatives. Simply copying remote snapshots loses edits/selection.

For a MainActor-owned interactive graph, there is no such cross-executor race. The UI edit and local DDS application happen in the same synchronous turn; remote processing cannot cut between them. **No additional UI↔DDS OT is needed for concurrency.** You still need selection/anchor transforms for remote edits, and IME composition may require its own transient buffering policy. That is not permission to delete every text adapter.

## 2. Performance and where work runs

### Budget

120 Hz allows 8.33 ms per frame; 60 Hz allows 16.67 ms, including layout/rendering and unrelated app work. Apple's guidance says main-thread update work below roughly 5 ms is usually ready in time; 100 ms is a discrete-interaction hang threshold, **not a typing target**. [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness). The fetched Markdown is saved in the spike's `results/apple-responsiveness.md`.

**Design target, not measured Fluid performance:** keep typical local DDS mutation plus immediate listeners below 1 ms, and a normal ingress apply turn below 2 ms, leaving room for the actual editor. Measure p50/p95/p99, large paste, rich text, live remote bursts and allocations on a lower-end supported iPhone. No hard worst-case budget can be promised for arbitrary documents or arbitrarily large atomic ops.

### Work placement

- **URLSession / socket waits:** asynchronous transport actors and Sendable data. Waiting does not occupy MainActor. CPU decoding after an await is not automatically off-main; explicitly put parsing/decoding in `@concurrent` functions or the ordered I/O worker. Do not sprinkle `Task {}` inside a MainActor loader and call it offloading.
- **Initial snapshot download/decode/load + large initial catch-up:** background bootstrap before publishing any DDS reference. Build a disconnected non-Sendable graph in an `@concurrent` function, replay to a chosen sequence boundary, return it as `sending PreparedContainer`, and install it exactly once in its final owner. Keep protocol/runtime/merge-tree/IDs/pending state together, not just visible text. No UI listeners or actor-capturing callbacks exist on the graph yet.
- **Handoff protocol:** let a single transport owner buffer ingress while bootstrap consumes a prefix through sequence S. Stop the bootstrap reader at a legal boundary; await its completion; package the graph, checkpoint and remaining ordered events. Transfer ownership, install host hooks, drain the tail on the final owner, and only then publish ready/editable state. Events arriving during transfer remain in the same owned queue/stream. No two iterators consume one `AsyncStream`; no ops are dropped to bound memory. The spike proves graph transfer, not this full network cutover.
- **Already-published graph:** never move it to a worker while app code retains DDSes. `sending` cannot prove that safe, and an optional property set to nil does not revoke other aliases. Initial load is the easy off-main case. Live reconnect catch-up still applies on the final owner. Decode ahead, optimize the core, and only yield at oracle-compatible boundaries. A huge atomic apply can hitch; background mode with a proper UI replica is the explicit escape hatch for workloads that exceed the interactive budget.
- **Summarization:** keep TS's separate summarizer child, represented here by the background `Container` actor. It owns its own graph and independently follows the sequenced log, with TS election/parent-generation/ack semantics. The existing Swift child lifecycle in Container and TS [summaryManager.ts](../../reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/summary/summaryManager.ts), lines 97–99, 142 and 296–303, provide the shape. Summary traversal, serialization, compression and upload never traverse the UI graph from a worker. Do not pretend a second TS container intrinsically meant a second JS thread; Swift can schedule this independent graph off-main.
- **Compression:** preserve exact current op semantics first. `Outbox.virtualizeBatch` performs serialization → grouping → compression → splitting **before** `submitBatch` allocates physical CSNs and `onFlush` registers pending state. Therefore “just move LZ4 to a Task” breaks the synchronous flush contract. Inbound `RemoteMessageProcessor` and `OpDecompressor` also retain chunk/batch/unrolling state. Keep state transitions on their owner. A later optimization can extract pure byte compression/decompression into an ordered staging pipeline, with immutable input, sequence/generation tags and a commit barrier; reserve the correct physical-message/CSN mapping before exposing completion and validate against the oracle. Do not claim this extraction is already solved. Initially, bootstrap and summarizer compression are off-main; steady-state compression remains synchronous until profiled and deliberately refactored.

The large-load cost is likely graph work, copies and unbounded drains, not a few microseconds crossing an actor. These are hypotheses from implementation shape, not a profile. Fixing a scheduling API cannot make `getText()` scans, `removeFirst()` backlog shifts or large LZ4 work disappear.

### Measured executor costs

Standalone package: [`.build/threading-astra`](../../.build/threading-astra). Five optimized rounds of 20,000 calls after 1,000 warm-up calls; `ContinuousClock`; non-inlined increments; consumed checksums. Each asynchronous observation is a **completed round trip from MainActor and back**, not an isolated one-way hop or kernel context switch. Do not divide it by two and advertise a universal Swift hop cost. No contention control, energy measurement, or phone involved.

Final release run (raw log `results/release-final.txt`; first successful run retained as `results/release.txt`):

| Path | Median ns/completed call | Observed round-mean range |
|---|---:|---:|
| Synchronous MainActor counter | 2.77 | 2.70–2.85 |
| Same-executor actor via checked `assumeIsolated` | 153.66 | 151.99–171.25 |
| MainActor → default actor → MainActor | 11,512.52 | 10,263.00–13,012.75 |
| MainActor → Dispatch-backed serial actor → MainActor | 14,307.10 | 13,024.56–17,659.61 |

The first release run had lower medians (2.23 ns sync; 122.53 ns checked bridge; 7,467.98 ns default-actor round trip; 8,125.03 ns queue-actor round trip). The change across runs is a useful warning about machine-load sensitivity; these are round means, not latency percentiles. Debug also passed (log `results/debug.txt`), but its timings are not used for performance decisions.

The checked bridge is ~0.15 µs in the final run; there is no performance argument that it is prohibitively slow. Its cost is API complexity. Conversely, 10,000 independently awaited main/default round trips at this median would consume about 115 ms in scheduling/call overhead alone. Batch immutable ingress once per transport batch/allowed apply turn, never hop per segment or per event listener.

Synthetic 100,000 append-op background build/catch-up plus handoff: **1.261 ms** (first run 1.585 ms; debug 21.283 ms). This is an intentionally tiny DDS-shaped array, **not Fluid MergeTree**, JSON parsing, snapshot IO, network catch-up, or evidence of phone readiness.

## 3. Strict concurrency and app ownership

The core, runtime, managers and DDSes stay **non-Sendable**. No `@unchecked Sendable`, `nonisolated(unsafe)`, custom lock per DDS, or unsafe cast. A MainActor view model may retain a DDS from a MainActor `FluidContainer` because both aliases stay in the same region. A headless client accesses its graph through an actor-isolated transaction/session; return only Sendable values across that boundary.

A bare `let` DDS property does not make its mutable referent immutable or Sendable. The spike's `Escape.swift` fails when a detached task tries to mutate a MainActor-owned DDS. `BadTransfer.swift` fails when a source continues using a graph after passing it as `sending` to its owner. Bootstrap uses a fresh disconnected region, not a live actor property.

Driver protocols already require Sendable handles and transport values. Send `Data`/byte arrays, `JSONValue`, snapshots and typed immutable ops; `JSONValue` and `JSString` are Sendable, and `JSObject` is conditionally Sendable. Do not send channel instances, event objects retaining segments, runtime closures or mutable caches. Exactly one ordered ingress consumer hands batches into the core. If decoding is parallelized, resequence completion before apply; the simpler initial implementation is one decode worker.

### Verified language mechanisms

The links below were read from upstream Swift Evolution; runnable claims also have compiler/runtime probes. Feature version is not deployment availability.

- [SE-0392](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md): custom actor executors. The spike runs one actor with `MainActor.sharedUnownedExecutor` and another with a retained `SerialExecutor`/DispatchQueue. `unownedExecutor` is fixed for actor lifetime. Do not start on a private executor then change that property to main.
- [SE-0424](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0424-custom-isolation-checking-for-serialexecutor.md): `checkIsolated` supports checking non-task executor entry. The spike also enters the main-executor actor from `DispatchQueue.main.async`, modeling a synchronous framework callback rather than merely an inherited Swift Task.
- [SE-0313](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0313-actor-isolation-control.md): `isolated Container` makes a synchronous actor transaction possible. It does **not** simultaneously give the closure MainActor isolation.
- [SE-0420](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0420-inheritance-of-actor-isolation.md): `isolation: isolated (any Actor)? = #isolation` lets shared async helpers inherit the owner. The spike passes a main-owned non-Sendable DDS to such a helper. This is method isolation, not a way to stamp an arbitrary class with per-instance isolation forever.
- [SE-0414](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md) and [SE-0430](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md): disconnected-region transfer and `sending`; used for bootstrap handoff, with a rejection probe for retained use.
- [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md): explicit `nonisolated(nonsending)` preserves caller isolation; `@concurrent` explicitly leaves it. Both compile and run. Do not assume the default change is enabled merely because a Swift 6.2+ compiler is installed; the proposal identifies `NonisolatedNonsendingByDefault` as an upcoming feature flag.
- [SE-0431](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md): closure values retain dynamic isolation; an arbitrary invocation requires await. The spike invokes a MainActor closure through that type. Useful for task dispatch, **not** a replacement for synchronous DDS listeners.
- [SE-0417](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md): task-executor preference is not an override for actor isolation. No proposed API here depends on it; not separately benchmarked/implemented.
- [SE-0395](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md): Observation is presentation invalidation, not a transport or serial executor. The spike compiles an `@MainActor @Observable` model and SwiftUI `@Bindable` view.
- [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md): module-default isolation is a build choice, not a library-wide solution. Use explicit owner annotations; keep core/DDS modules neutral. No dependence on this setting in the spike.

### Why B is possible but not the recommended API

This compiles and runs (real implementation in the spike):

```swift
actor InjectedContainer {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        MainActor.sharedUnownedExecutor
    }
    @MainActor func sync<R: Sendable>(
        _ body: @Sendable (isolated InjectedContainer) throws -> R
    ) rethrows -> R {
        try assumeIsolated(body)
    }
}
```

Within `sync`, the body accesses DDS state under the container's static isolation. A MainActor caller can get a Sendable result. A callback installed there can enter `MainActor.assumeIsolated` to touch UI, because the actor permanently uses that executor. The spike demonstrates this without unsafe annotations. For an injectable version the main-only bridge must also reject a private-executor configuration, and the executor object must stay alive.

But directly mutating MainActor view-model state in the `(isolated Container)` closure fails (`Bridge.swift`). Trying to hide the mismatch behind `sync(_ body: (DDS) -> R)` fails region checking (`RawBridge.swift`: “sending 'body' risks causing data races”). **`swiftc -typecheck` alone missed that second diagnostic; `swiftc -c` caught it.** This is why a compiling/linking spike matters. B would require scoped access, MainActor-aware DDS proxies, or a carefully audited unsafe abstraction. It is a legitimate low-level option, not the cleanest default for UIKit users who need to retain real DDS references.

## 4. App-facing API and events

These are proposed public signatures, not declarations already present in the repository. Domain names use existing types where available; `ContainerLoadRequest`, `ListenerToken`, `ContainerEvent`, `ConnectionState`, and `OdspContainerServices` stand for the corresponding loader/static public models to define or reuse. The standalone spike proves the isolation shapes, not a build of these production modules.

```swift
// FluidContainerLoader: headless clients, service peers, summarizer child.
public actor Container {
    public static func open(
        _ request: ContainerLoadRequest,
        serviceFactory: any IDocumentServiceFactory
    ) async throws -> Container

    public var initialObjects: JSObject<any Channel> { get }
    public func transaction<R: Sendable>(
        _ body: @Sendable (isolated Container) throws -> R
    ) rethrows -> R
    public func connect() async throws
    public func disconnect() async
    public func dispose() async
}

// FluidStatic: owns its graph on main, NOT a wrapper around the above actor.
@MainActor public final class FluidContainer {
    public var initialObjects: JSObject<any Channel> { get }
    public var connectionState: ConnectionState { get }
    public var isDirty: Bool { get }
    public var disposed: Bool { get }
    public func edit<R>(_ body: () throws -> R) throws -> R
    @discardableResult
    public func on(_ event: ContainerEvent,
                   _ listener: @escaping @MainActor () -> Void) -> ListenerToken
    public func off(_ token: ListenerToken)
    public func connect() async throws
    public func disconnect() async
    public func dispose() async
}

// FluidOdspClient: configuration/driver handles may be Sendable;
// the interactive creation/result surface is explicitly main-isolated.
public struct OdspClient: Sendable {
    public init(properties: OdspClientProps)
    @MainActor public func getContainer(
        _ itemId: String,
        containerSchema: ContainerSchema
    ) async throws -> (FluidContainer, OdspContainerServices)
}
```

Internally both owners hold one `ContainerCore` plus shared `ContainerSession` lifecycle logic. `ContainerSession` is non-Sendable; its async I/O helpers use explicit `nonisolated(nonsending)`/isolated parameters. Owners provide only the task-entry isolation, public access boundary and host lifecycle. Do not copy connection/reconnect/summarizer logic into two classes. The bootstrap helper has the key signature:

```swift
@concurrent
func prepare(_ request: PreparedLoadRequest) async throws
    -> sending PreparedContainer
```

Requests must contain only Sendable configuration/driver handles, not pre-existing DDS objects. `PreparedContainer` contains the entire disconnected graph and checkpoint, with no outstanding graph-using task when returned.

### Event surface

- **DDS callbacks are synchronous, owner-local, non-Sendable closures.** Keep inline invocation and explicit unsubscription. `@Sendable` is not a promise of delivery on an actor and needlessly prevents owner-local captures.
- MainActor `FluidContainer` lifecycle listeners can be explicitly `@MainActor`; store them on that owner, not in a shared cross-actor callback bag. A background `Container` can register listeners in an isolated session or accept `@Sendable` boundary callbacks where needed.
- **AsyncSequence is for transport and copied notifications.** A listener can snapshot Sendable deltas/revisions into a stream for analytics or background consumers. Such a consumer cannot infer that a later DDS read matches the queued notification. Never stream a live `SequenceDeltaEvent`.
- **Observation is for rendering.** Update minimal presentation fields synchronously inside DDS listeners. SwiftUI may render later/coalesce updates; that is fine for display but cannot replace per-op text editing semantics. Do not annotate every internal merge-tree node `@Observable`.

A MainActor model retains both container and DDS. For SharedMap, initialize a `title` presentation field from `map.get("title")`; on `valueChanged` for that key, synchronously read it again and assign `title`. A SwiftUI `Binding(get:set:)` uses `container.edit { try map.set(...) }` synchronously (handle errors in the model), not through a `Task`. For SharedString, expose cheap status/count fields to SwiftUI and retain the UIKit text adapter; binding an entire document to `TextEditor` string replacement on every event is the wrong granularity.

The spike contains compiling macOS SwiftUI access and an iOS 18 simulator-targeted UIKit/SwiftUI module proving an `@MainActor` delegate can retain a plain DDS, edit it synchronously, and receive its callback inline. That probe's replacement operation is a minimal type/isolation demonstration, **not** the proposed real SharedString editor algorithm.

### FluidNotes exact behavior

`textViewDidChange` already runs synchronously on MainActor and computes UTF-16 changes. Apply those edits directly to SharedString inside one synchronous `container.edit` scope before returning. Ignore the corresponding local delta for text-storage patching (UIKit already applied it). For a remote event, resolve ranges **inside** the listener, patch textStorage synchronously, and update selection/anchors. Guard adapter-generated delegate callbacks against echo. Preserve CoreFoundation/NSString handling of lone surrogates; do not copy the probe's simple String conversion into production.

Keep `TextEdit` diff and selection utilities where useful; remove `TextSyncEndpoint`, acknowledgment counters, the two streams and remote/local transform queues. Do not rely on SwiftUI `updateUIView` as the remote-op consumer. Explicitly test marked text, dictation/autocorrect, multi-code-unit characters, large paste, undo and remote deletion around the caret. Same-executor ownership removes one race; it does not make TextKit/IME correctness automatic.

## 5. Lifecycle, backgrounding, and tests

**Disposal:** synchronously flip a terminal flag/increment generation; stop accepting edits, cancel stored reader/writer/reconnect/timer/summarizer tasks, detach listener tokens, finish output streams and resolve pending continuations exactly once. Then await socket/child cleanup. Idempotent concurrent disposal callers share completion. Do not rely on `deinit` to asynchronously close sockets; avoid stored-task retain cycles by weak owner captures while waiting. `IDocumentService.dispose` does not close delta connections, so call each connection's async disposal explicitly. Disconnect is resumable; dispose is terminal.

**Backgrounding:** app scene lifecycle requests disconnect/suspend; don't assume a WebSocket will run indefinitely while iOS suspends the process. Keep the graph/pending ops for reconnection, cancel ping/retry loops, and persist supported pending state if survival across process death is required. A save acknowledgment is not implied by local apply or socket submit. Stop or relinquish the child summarizer; do not wait minutes for its normal shutdown deadline when the OS gives a short lifecycle opportunity. On foreground, reconnect with a new generation, verify handshake identity, fill gaps and rebase/resubmit pending local state in TS order. Backgrounding one window should not close a document still used in another active scene; lifetime belongs to the document session, not a transient SwiftUI view.

**Multiple containers:** UI containers share MainActor and have independent connection/generation/pending state. There is no global ordering requirement between documents. All background summarizers/headless actors can run independently; no need for one dedicated OS thread per document. MainActor sharing can still cause head-of-line stalls across windows; this is a measured workload limit, not a reason to hide a replica protocol in every client.

**Deterministic tests:** retain synchronous core tests and the stdio request/response ordering. Use injected transport, explicit event ingress and virtual clocks for lifecycle tests. No `sleep` to await “probably drained”; expose a test barrier at a known sequence and logical batch boundary. For actor-host tests, `await transaction` then read/assert a Sendable snapshot. For UI-owner tests use `@MainActor` tests. Record events inline and assert the state read during each event, not only final convergence. Test stale handshake completion, stale gap fetch, disposal during load, reconnect while sends are pending, large grouped batches, listener reentrancy and cancellation. The spike's gate test proves why these tests are needed; it does not replace the differential harness.

## 6. Concrete migration

1. **Extract the owned graph without changing DDS semantics.** Move synchronous protocol/runtime/delta/outbound/election state and apply operations out of `Container` into internal non-Sendable `ContainerCore`. Move shared lifecycle sequencing into owner-inheriting `ContainerSession`; keep async effects outside core transitions. Preserve references and callbacks within that ownership graph.
2. **Fix target layering before adding wrappers.** `FluidContainerLoader` currently imports `FluidStatic` for root resolution; `FluidStatic` cannot simply import it back. Put the neutral core/session in a lower target depending on runtime/driver definitions, not FluidStatic. Keep schema/root-object integration in FluidStatic, using a factory/loader seam. Both Loader's background host and Static's main host use this lower layer. No dependency cycle and no duplicate runtime.
3. **Container:** retain the actor as background owner and headless API; make its synchronous body/isolated session the access unit. Do not add a custom queue by default; Swift's actor executor is sufficient. Use a separate background owner for summarizer children even when the parent is UI-owned. Move parent notifications through Sendable values and generation-aware callbacks, not by assuming parent is always a `Container` actor.
4. **ConnectionManager:** consume `any IDocumentService` / `any IDocumentDeltaConnection`; remove dependence on the obsolete concrete connection API. Preserve nonsending owner isolation, add generation/state validation after awaits, single-flight connect, and one ordered send pump. Distinguish resumable disconnect from terminal dispose.
5. **DeltaManager:** keep synchronous. Preserve gap/dedup/MSN/CSN/event order and complete-batch drains. Separate “prepare incoming immutable data” from “commit/apply”. Profile queue storage; a cursor/deque can replace repeated front removal without changing ordering, but do not fold unmeasured algorithm changes into the ownership migration.
6. **In-flight FluidContainer:** make it `@MainActor final class` owning the shared core/session, not another actor and not an actor wrapper. Keep direct `initialObjects` access. Give listeners tokens and deterministic unsubscription. Wire the automatic local-flush wake-up and synchronous compound-edit scope so direct DDS edits actually submit. Build/catch up off-main before publication through `sending`; install UI lifecycle callbacks only after adoption.
7. **OdspClient:** MainActor-isolate interactive `getContainer`; keep Sendable driver configuration and explicit background preparation. Return an already adopted, valid container. Headless users use the loader's background host with the same driver; avoid an ambiguous `executor:` option whose value silently changes the safety of the returned DDS references.
8. **FluidNotes:** replace isolated actor session + dual streams with direct main-owned DDS access. Delete cross-executor OT, preserve native text/selection/IME glue, and unregister listeners on close. Fence overlapping opens with an open generation/task so stale completion cannot replace a newer note.
9. **Validate migration separately:** differential scenarios for unchanged wire/summary behavior; then real-device editor/reconnect/background/IME tests and performance traces. No build of the changing repository or paid model calls were used for this design experiment.

## 7. Reproduction and what was actually proved

From repository root:

```sh
swift --version
swift run --package-path .build/threading-astra -c release threading-spike
swift run --package-path .build/threading-astra -c debug threading-spike
sh .build/threading-astra/check-negative.sh
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-ios18.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -emit-module -module-name UIKitAccess \
  .build/threading-astra/Probes/UIKitAccess.swift \
  -emit-module-path .build/threading-astra/results/UIKitAccess.swiftmodule
```

The runnable spike asserts:

- Plain non-Sendable DDS retained safely by a MainActor observable model; local mutation and immediate event-state read complete before the input handler returns.
- 100 incoming ops processed in order by one MainActor consumer; each callback observes its own state, not the final batch state.
- 100,000 synthetic catch-up ops executed off-main; a `sending` graph then adopted by the UI owner; a second graph adopted by the background actor.
- A Dispatch-backed custom actor executor runs correctly; an actor using MainActor's executor supports checked synchronous access from a native Dispatch main callback.
- Both compiler-checked isolated-parameter and nonsending helpers accept owner-local DDS state; isolated-any invocation works asynchronously.
- Idempotent UI-host disposal and a deterministic actor-reentrancy counterexample.
- Four unsafe patterns are rejected by actual code generation, not merely syntax/type checking.

No unsafe annotations are needed for the recommended ownership design. The B experiment intentionally uses the documented runtime-checking `assumeIsolated` APIs; the recommended path does not.

### Open risks / next decisive evidence

- **Real graph transfer:** the small disconnected graph transfers cleanly. The full runtime has callbacks, drivers, caches and factories; audit all reachability and compile its real `sending PreparedContainer` before claiming background bootstrap is integrated. If it retains owner/task aliases, fix ownership rather than mark it unchecked. A value-only prepared snapshot is a safe smaller first step but leaves final graph construction on-main and must be timed honestly.
- **Bootstrap network cutover** is specified, not implemented/proved by this spike. Exercise ops arriving during every handoff boundary, gap fetch, cancellation and reconnect; retain all causal signal/op ordering required by the reference.
- **Local turn scheduling** must preserve the current flush, grouping and pending-registration semantics with raw DDS access; the proposed coalesced owner pump is not implemented by the synthetic spike. Test local input immediately followed by a remote batch, nested events and disconnect.
- **Compression and reconnect backlog** can still block main in the current implementation. Pure offloading cannot cross pending/CSN/batch boundaries casually. Need real profiling and differential validation before altering those paths.
- **Atomicity vs frame time:** an arbitrarily expensive single logical transaction cannot be both synchronous/indivisible and guaranteed under 5 ms. Do not make that promise. Profile realistic document limits and preserve the explicit background/replica option.
- **UIKit runtime:** UIKit/SwiftUI access compiled for iOS simulator, but this task did not run a real UITextView or a phone. IME/undo/selection remain mandatory product validation for the implementation.
- **Deployment matrix:** only installed Swift 6.4/macOS 27 runtime was executed. Verify Swift 6.2 and iOS 18/macOS 15 runtime availability/behavior in CI/device validation.

**Ship the ownership model, not a new synchronization protocol.** The clean default is for a phone editor to touch its actual DDS immediately, while loading, transport and a genuinely separate summarizer do their heavy work elsewhere.

## Convergence round

2026-11-06. This section supersedes the conflicting recommendations above; the earlier design remains intact as the record of the independent proposal. I read [Opus's entire design](threading-opus.md), every Swift source in its spike, its negative probes and their runner, and the reported measurements. I also checked the reference scheduler, flush and batching implementations and the differential harness contract. No production implementation is implied by this review. Opus's spike was being extended concurrently during my final check; the measurements discussed here are its original reported runs. My compiler-input fingerprints are saved in [source-hashes.txt](../../.build/threading-astra/Convergence/results/source-hashes.txt); I did not edit its sources or document.

The parent's common-ground summary is right. Both designs want one plain, synchronous, non-Sendable graph per container; MainActor ownership for interactive apps, a separate owner and graph for headless/summarizer clients; off-main preparation followed by exclusive adoption; synchronous local DDS events; and deletion of FluidNotes' cross-executor replica protocol, not its native text/selection/IME adapter. The synchronous outbound enqueue plus one ordered writer is essential under **either** ownership API. Opus's 197–199/200 CSN reorderings are a reproduction in its stand-in of the current async-send shape, not a measured production failure rate.

### 1. Public ownership API — concede

**Adopt Opus's explicit, non-optional `isolation owner: isolated any Actor` API. Drop my two public owner types.** My objection to a runtime `executor:` setting does **not** apply to this signature. An ordinary executor argument merely changes where code runs; an `isolated` parameter changes the function's statically checked isolation. The returned non-Sendable container belongs to that actor's region. A MainActor caller cannot pass a background actor and then receive that live graph for UI use: the compiler rejects the return across the isolation boundary.

For an app the extra `isolation: MainActor.shared` is a small, useful declaration of ownership. It buys one container implementation and the same API for `isolation: self` in a headless actor. My concrete MainActor type is more immediately discoverable, but not sufficiently safer to justify a second public host/access model given these diagnostics. Keep private `PeerHost` and `SummarizerHost` actors as **clients owning graphs**, not a second public container species. No custom executor, `assumeIsolated` bridge, unchecked Sendable conformance or runtime owner switch is needed.

This conclusion depends on the complete construction contract, not just spelling an argument explicitly:

- Every public live-container factory requires a **non-optional** isolated actor, with no default and no nil-owner overload. `start(on:)` is internal, once-only, and creates its pump in that owner's isolation (including the isolated-parameter capture).
- The factory starts/adopts the graph before returning it. Its result is ordinary `FluidContainer`/`Container`, **not `sending`**. Only the unpublished background preparation result is `sending`.
- The graph and its DDS aliases stay non-Sendable. All access is through the owning app model/actor; retained DDS references are fine **inside that region**. Async graph methods explicitly preserve caller isolation with `nonisolated(nonsending)` unless they already have an isolated parameter. Library targets remain actor-neutral.
- Factories/configuration entering background preparation must be Sendable, and no graph-using task or owner-capturing callback survives that preparation. The actual graph's transfer still needs compilation and cutover validation; the tiny spike is not that integration.

**Additional evidence:** [Convergence/check.py](../../.build/threading-astra/Convergence/check.py) imports a module compiled read-only from Opus's `FluidModel` sources and compiles the client probes through object generation in Swift 6 mode, complete strict concurrency, warnings as errors. Both valid ownership examples compile. All four misuse variants are rejected: MainActor requesting a different actor's graph; a `@concurrent` caller receiving a main-owned graph; rebinding an already main-owned graph; and sending an aliased main-owned DDS to another actor. See [compiler-summary.txt](../../.build/threading-astra/Convergence/results/compiler-summary.txt) and the individual diagnostic logs.

I separately compiled and ran Opus's unchanged N6 race program with TSan, placing the executable/log under my spike: **1 TSan data-race warning, lost updates in 7/50 trials** ([log](../../.build/threading-astra/Convergence/results/n6-tsan.txt)). Opus reports lost updates in 30/50; the differing rate is scheduling-dependent, not a disagreement. The bug is the accepted nil-owner task escape; it is not evidence that every use of an optional isolated helper is broken. My earlier simple owner-inheriting read helper does not spawn such a task. Nevertheless, a container adoption API must exclude nil. These new checks used the same installed Apple Swift 6.4; they do not certify Swift 6.2 or older deployment runtimes.

### 2. Catch-up yielding — synthesize

**Yes, yield during live catch-up, with a fixed 4 ms target for interactive owners, but only after a complete reference-compatible batch/apply boundary.** This is not a retreat from synchronous apply. TS already pauses at `batchEnd`; my earlier warning should have distinguished introducing an illegal suspension from choosing an earlier *legal* scheduler pause. Adopt TS's pause/resume shape, not its 50 ms initial budget and successive 10 ms increases for an interactive mobile editor. The 4 ms value is an internal scheduling policy, not a public executor/performance knob or a hard maximum stall.

The boundary is concrete: observe the runtime's real `batchBegin`/`batchEnd` state, mark a pause at `batchEnd`, and return through the entire synchronous DDS/runtime/delta processing stack, including listeners and post-process bookkeeping, **before** suspending. Never suspend inside grouped-batch expansion, decompression/unrolling of one physical message, an open multi-message batch, an individual DDS apply, or a local `orderSequentially` scope. A socket array boundary or every N messages is not a substitute. A single atomic batch can exceed 4 ms; finish it, measure the overrun, and yield afterward. Bootstrap before publication remains off-main.

The reference [deltaScheduler.ts](../../reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/deltaScheduler.ts) pauses the inbound queue at `batchEnd` and schedules a timer resume; [deltaQueue.ts](../../reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts) then finishes the worker stack before noticing the pause. Preserve that distinction. A paused inbound drain should return control to the owner pump, with a generation-checked later-turn resume, rather than monopolizing its job handler while awaiting through the whole backlog. Flush and lifecycle work must remain serviceable; causal ordering within the inbound op/signal stream still must not change. Recheck disposal, connection generation and pause state before resuming; never start a second drain.

Opus's responsiveness experiment is useful but narrower than its headline:

- It reports 760–955 ms unsliced and 6.0–9.6 ms maximum main-timer gaps sliced; its R3 `Task.yield` case reports 7.9–9.2 ms longest Fluid slices. That supports slicing, **not** a 4 ms hard bound or “never more than about 9 ms.”
- The original measured spike had no Fluid batch metadata in `Wire.swift` and tested the budget after every stand-in message. Those R1–R4 measurements demonstrate singleton-message slicing, not a real `deltaScheduler` port or grouped-batch correctness. During this round Opus added synthetic `batchEnd` markers and `Batches.swift` probes for boundary preservation and flush grouping; I read those additions too. They target the right distinction, but do not retroactively make R1–R4 grouped/compressed-runtime measurements, and I am not claiming new results for its in-progress tests.
- `FrameProbe` counts timer gaps crossing frame-period thresholds, not rendered/dropped frames. Its roughly 800 ms freeze counts as one over-threshold gap, not one missed frame. Report “zero gaps over 16.67 ms in those clean runs,” not a measured zero dropped display frames. Its discarded contention run included an 89 ms gap and remains relevant to responsiveness risk.
- `Task.yield()` is not a guaranteed full run-loop turn or a rendering barrier: it can immediately resume the same task ([Swift's documented implementation](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/Task.swift#L738-L770)). Prefer the reference-shaped later-turn/timer resume for the initial scheduler; validate actual iOS input/render opportunities and multiple busy containers. The macOS 1-microsecond timer experiment is evidence for feasibility, not a prescribed portable timer resolution. A headless owner needs no UI frame promise, but uses the same legal-boundary machinery.

**Keep the differential harness exact.** I do not accept the proposal to stop comparing timing-dependent reference sequence numbers. The [protocol](../../harness/PROTOCOL.md) explicitly compares a Swift subject and its lockstep TS twin after identical calls, including outbound JSON, events and summaries. RefSeq, CSN, pending metadata and batch shape remain load-bearing comparison fields.

Instead make scheduling an explicit input to scheduler-level tests: inject a virtual clock and controlled later-turn wake-ups into both hosts; replay the same ordered local turns, inbound complete batches, flush checkpoints and lifecycle events. When testing different budgets, each resulting schedule gets its **own identical twin replay**, not a comparison between independently racing wall clocks. Record the sequence/batch boundary at which input actually entered, then replay it against the oracle. This keeps exact payload/event comparisons without requiring two machines to take the same milliseconds. Existing synchronous channel harness calls need no timing relaxation. Add scheduler/container cases for singletons, multi-message and grouped/compressed batches, edits between slices, stale resumes and disposal. Separately measure native responsiveness; do not use those timing races as an exact-byte oracle.

### 3. Local flush — concede the forced flush, synthesize the pump

**Our automatic mechanisms are the same idea:** submission mutates local state and appends to the outbox synchronously; the first pending edit schedules one coalesced owner-local flush wake-up; that flush prepares/group-compresses messages, registers pending state and allocates CSNs synchronously, then enqueues immutable messages to one transport writer. It is not a task per edit, a network await in a DDS method, or an acknowledgement before returning. Flush before inbound processing changes the local batch's reference sequence, and preserve the reference's other flush sites, including connection changes and pending-state capture.

**My proposed `edit {}` closing the turn on return was wrong for default TurnBased batching.** In [containerRuntime.ts `orderSequentially`](../../reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts#L3914-L3989), the reference explicitly leaves the batch open in TurnBased mode. Two synchronous edit scopes followed by a raw DDS mutation in the same turn must not become three batches merely because Swift exposes a convenient closure. Remove the new `FluidContainer.edit` API. If callers need an explicit grouping scope, port the existing runtime `orderSequentially` contract, including nesting and error/rollback behavior: outermost exit flushes in Immediate mode, not automatically in TurnBased mode. Do not advertise arbitrary closure failure as transactional rollback unless the runtime actually supports it.

There is still a qualification to Opus's “flush job equals JS microtask.” Its FIFO `.flush` job cannot run while the same loop is inside `await processInbound`; the pre-next-op `flush()` is what closes local work done during a slice. And neither a serial actor nor an AsyncStream grants JavaScript's microtask priority over unrelated owner jobs. Two FIFO producers also do not determine a universal command/socket interleaving ([Apple on actor scheduling](https://developer.apple.com/videos/play/wwdc2021/10254/)). We must specify/test the host's logical turns, not equate `Task {}` scheduling with `Promise.resolve().then`.

The merged pump therefore treats a flush wake-up as a coalesced end-of-turn checkpoint, independently of the inbound backlog: once a synchronous host turn unwinds, service its scheduled flush before the next controlled host turn; if incoming processing is what runs first, apply the reference's synchronous pre-inbound flush barrier. A scheduler pause returns to that pump rather than holding it inside a draining job. Never synchronously flush from `submitLocal` in TurnBased mode, and never interrupt the active callback/apply stack. Native caller tasks can still be scheduled differently from JS tasks; compare identical explicit turns in the harness and document the coalescing boundary, not a nonexistent cross-runtime wall-clock batching guarantee. The spike proves ordered enqueue, not this complete microtask/turn emulation. Implement and test this scheduling seam as part of the migration, not by weakening the oracle.

### 4. Other corrections and improvements — synthesize

**Synchronous lifecycle entry points are better than my mandatory async surface.** Accept TS-shaped `connect`, `disconnect`, `close` and `dispose` calls: they synchronously initiate/record transitions, with results reported through owner-local events. But synchronous `dispose()` means immediate terminal invalidation, **not** that socket/child cleanup has finished or that pending edits were acknowledged. The current driver requires async disposal; internal cleanup can remain async and have an internal completion barrier for tests. Keep single-flight connect and lifecycle generations across all real awaits. A background disconnect does not guarantee a save ack; explicit pending-state persistence is still needed to survive process termination.

Opus's spike is not disposal/cancellation proof. `Container.dispose()` only finishes its stream and clears the task handle; already-buffered jobs remain drainable, and an already-running `processInbound` has no terminal/generation check. Finishing a stream or dropping a task handle does not cancel that work. Its loader also creates a live connection/writer before JSON decoding; throwing or cancelling afterward requires explicit cleanup, not just dropping the graph. A synchronous terminal flag, task cancellation, listener detachment and validated late-completion rejection from my original design remain mandatory.

**Lifetime safety is separate from race safety.** The example's container-owned listener strongly captures that container; this is a retain cycle even though all references belong to one isolation region. Unowned DDS-to-container and editor callbacks can trap if a DDS outlives its host or an adapter is replaced. Use explicit listener tokens/removal and teardown of host hooks; closed DDS edits must fail through the existing closed-runtime checks, not crash on an unowned reference. Preserve the necessary runtime lifetime or detach those hooks before releasing it. Do not accept “same region” as an answer to ownership lifetime.

**Keep the ordered buffered transport unless replacement is justified.** I accept synchronous `submit` and `submitSignal` on the Sendable driver edge, backed by **one** FIFO writer per connection generation. CSN assignment and enqueue are indivisible on the graph owner; actual network writes happen later and can fail. Opus's I3 should say that, not literal synchronous wire transmission. Ops and signals share the writer when their relative order matters. A Sendable transport `AsyncSequence` is fine; only DDS live-state events must remain synchronous. Replacing the existing buffered inbound stream with `attach(deliver:)` is not intrinsically necessary for this design. If a sink is used to feed the common pump, install/buffer it from handshake onward; “attach after connect” must not lose the early events.

**Do not inherit unmeasured performance claims.** “Compression is under 1 ms” does not follow from a 614,400-byte threshold and generic GB/s LZ4 throughput: batches can be larger, serialization/grouping allocate, and phone costs are unmeasured. Keep compression synchronous within the flush contract until a measured, ordered staging design preserves physical CSNs and pending registration. Likewise, the stand-in SharedString has no merge-tree or local/remote rebasing and clamps offsets. Its view-equals-local-DDS checks are not proof of multi-client text convergence or selection correctness. They prove the isolation/event shape they were built to test.

**Keep the native editor adapter, not either sketch verbatim.** Direct MainActor DDS calls remove the UI replica protocol. They do not validate IME, undo, UTF-16 diffs or error recovery. Opus's `shouldChangeTextIn` sketch removes text and then inserts; if the second call throws and the delegate returns false, UIKit can reject a change already partially applied to the DDS. My earlier `didChange` sketch likewise needs an explicit partial-failure policy. Use the existing native editor path and real runtime grouping/error semantics; do not infer rollback from same-actor execution. Keep incremental remote patching, selection/reference updates, echo suppression and deterministic unsubscription, and validate the actual UIKit flow during implementation.

### Final recommended signatures

These replace §4's two-owner proposal. Existing domain types keep their existing meanings; signatures describe the target design, not already-implemented production declarations. Only the app's holder is MainActor-isolated, not `FluidContainer` or the DDS modules.

```swift
// Loader: one plain graph type, owner selected at adoption, not by executor configuration.
public final class Container: IContainer { /* non-Sendable */ }

public func loadExistingContainer(
    _ props: ILoadExistingContainerProps,
    isolation owner: isolated any Actor
) async throws -> Container

// Internal only. Sendable request; no outstanding graph-using work on return.
@concurrent
func prepare(_ request: PreparedLoadRequest) async throws
    -> sending PreparedContainer

// Internal once-only adoption on Container; captures owner in its event-loop task.
func start(on owner: isolated any Actor)

// Static: thin non-Sendable facade over that same owner-local Container.
public final class FluidContainer {
    public var initialObjects: JSObject<any Channel> { get }
    public var connectionState: ConnectionState { get }
    public var isDirty: Bool { get }
    public var disposed: Bool { get }
    public var attachState: AttachState { get }
    public let events: ListenerList<FluidContainerEvent>
    public func connect()
    public func disconnect()
    public func dispose()
    public nonisolated(nonsending) func attach() async throws -> String
    public nonisolated(nonsending) func create<T: SharedObjectKind>(
        _ kind: T.Type
    ) async throws -> T
}

public final class OdspClient: Sendable { // immutable Sendable configuration
    public init(properties: OdspClientProps)
    public func getContainer(
        _ id: String,
        containerSchema: ContainerSchema,
        isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: OdspContainerServices)
    public func createContainer(
        _ containerSchema: ContainerSchema,
        isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: OdspContainerServices)
}

// Runtime batching, not a new app-facing forced-flush edit API.
public func orderSequentially<R>(_ body: () throws -> R) throws -> R

// ListenerList's ordinary synchronous owner-local surface; neither closure nor Event
// needs Sendable. Keep the existing token shape and explicit removal.
@discardableResult
public func on(_ listener: @escaping (Event) -> Void) -> Int
public func off(_ token: Int)

// The changed outbound requirements on IDocumentDeltaConnection: synchronous enqueue.
func submit(_ messages: [IDocumentMessage])
func submitSignal(_ content: String, targetClientId: String?)
```

App call: `try await client.getContainer(id, containerSchema: schema, isolation: MainActor.shared)` inside a MainActor model, which retains the result and DDS references. Headless call: the same factory with `isolation: self` inside its owning actor, returning only Sendable observations to outsiders. On `IContainer`, use Opus's synchronous `connect()`, `disconnect()`, `close(_:)`, `dispose(_:)` and `nonisolated(nonsending) getEntryPoint() async throws -> AnyObject`. Keep cleanup completion internal; do not make raw DDS access asynchronous to accommodate it.

Verdict: converged

I would accept one merged design: Opus's explicit non-optional isolated-owner factories and single non-Sendable container graph, owned by MainActor in apps and by private hosts elsewhere, with background `sending` preparation; direct synchronous DDS access and events; synchronous FIFO submission to one ordered transport writer; automatic TurnBased flush checkpoints without my forced-flush `edit` scope; and a 4 ms interactive catch-up target enforced only at fully unwound reference batch boundaries. Carry forward lifecycle generations, terminal invalidation, cleanup/lifetime discipline and the native editor adapter. Preserve exact differential comparisons by controlling/replaying logical scheduling, not deleting refSeq fields. This is convergence on that corrected merged design, not certification that either standalone spike has already implemented the production scheduler, cancellation or editor path.
