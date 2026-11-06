# F2 SharedString — implemented and differential gates passed

No git writes. All work remains available for the coordinator's review/commit. Other lanes'
changes in Package.swift, main.swift, peer.ts and the shared runtime files were preserved.

## Delivered scope

- FluidSequence SharedSegmentSequence/SharedString on SharedObject<SequenceLocalOpMetadata> and
  FluidMergeTree: detached/attached operation lifecycle, pending acknowledgment, regenerate/resubmit,
  repeated cycles, squash, LIFO rollback, stash, reentrancy and collaboration identity changes.
- SequenceInterval/BaseSequenceInterval, typed numeric/sided/sentinel endpoints, pending
  StayOnRemove-to-SlideOnRemove acknowledgment, shared pending property manager, conflict/delete
  handling, normalization-time and reconnect rebasing, disposal and transient event references.
- LocalIntervalCollection, IntervalCollectionMap, IdIntervalIndex, OverlappingIntervalsIndex,
  EndpointIndex, SequenceIntervalOverlapSet and SequenceIntervalEndSet. Query ordering uses
  anchored segment order, not collapsed visible positions; overlap search uses the TS max-end tree.
- Legacy/V1 content summaries with header/body chunks and catchups; full/compressed interval
  formats, old label prefix and identity-less/optional-property snapshots, load and same-sequence
  grouped catchups. Sixteen pinned TS fixtures compare complete blob bytes and reload/re-summarize.
- Lazy ordered SequenceEvent ranges/first/last, operation/message context, sequenceDelta,
  interval events, and split/append/unlink/ack maintenance events in observed TS order.
- SharedStringAdapter.swift and createClient capability registration. The default generator now
  includes numeric, sided and sentinel intervals and compares maintenance events too.
- Coordinator-authorized runtime MSN integration: IDeltaManager.minimumSequenceNumber; loader
  initializes from snapshot and advances before processing; existing parent/context forwarding;
  mock processed-message updates; Sequence reads the global runtime minimum when summarizing.
  A cross-DDS-minimum regression proves the channel need not receive another operation.

## Verification evidence

All logs are under `harness/artifacts/f2/`.

| Check | Evidence |
| --- | --- |
| 55 FluidSequence tests plus datastore forwarding regression, full package | `f2-complete-tests.log` — PASS |
| Final SharedString TS/Swift 0..499, expanded sided/sentinel/maintenance generator | `f2-complete-mixed.log` — PASS |
| SharedString TS/TS 0..199, same expanded generator | `f2-expanded-ts.log` — PASS |
| Merge-tree TS/Swift 0..499 after engine fixes | `f2-final-mergetree.log` — PASS |
| Byte-exact legacy/V1 × interval V1/V2 × empty/unicode/multi-chunk/interval fixtures | `f2-complete-tests.log`, SequenceSummaryFixtureTests — PASS |
| Differential interval batch rollback, stash, repeated reconnect | `f2-complete-lifecycle.log` — PASS |
| Planted forward-to-backward interval sliding fault caught, then reverted | `f2-differential-slide-mutation.log` / `.jsonl`, `f2-differential-slide-restored.log` — expected failure then PASS |
| Harness typecheck | `f2-final-typecheck.log` — PASS |
| Shared peer builds | `f2-complete-peer-build.log` — PASS |
| All 11 previously certified DDSes TS/Swift 0..49 after runtime MSN integration | `f2-msn-certified11.log` — PASS |
| Datastore differential 200 seeds after runtime MSN integration | `f2-msn-datastore.log` — PASS |
| Container summary + GC differential 20 seeds | `f2-msn-summarize.log` — PASS |
| Loader service 0..2 on tinylicious | `f2-msn-service.log` — PASS |
| Container/datastore service:m2 0..2, including its planted divergence checks | `f2-msn-service-m2.log` — PASS |

All final runs are terminal with exit 0. The final mixed farm includes the global-MSN integration
and repeated-resubmit-cycle fix. `f2-msn-final-mixed.log` and `f2-expanded-500-current.log` also
passed 500/500 on preceding snapshots. The implementation and requested gates are complete;
review/commit belongs to the coordinator, and no git writes were performed by this lane.

## Important source findings preserved by tests

- TS removes null properties before serializing inserted segments; reserved interval ID/labels
  belong to serialized payloads, not the public property bag.
- Acked endpoint relocation recreates refs in the normal reference list. Reusing slide buckets
  reverses later event order. Forward/backward slide groups flush as destinations change.
- Already-locally-removed overlaps slide before a remote removal delta; newly removed segments
  slide after it. Split maintenance fires with the right leaf's temporary ordinal/parent, before
  insertion into the tree. That intermediate position is intentionally not normalized away.
- Reconnect retains TS's one local short identity by retagging pending long-ID stamps in Swift.
- Property matching ignores key order while retaining the first segment's original serialized
  order. Live coalescing and both snapshot formats use the same matchProperties port.
- Legacy interval header serializes before Client.summarize advances its collaboration window.
- The TS harness adds timestamp=0 to delivered envelopes; the Swift harness mirrors this.
- MockFluidDataStoreRuntime.applyStashedOp takes DDS content directly, not an address wrapper;
  peer.ts now awaits and forwards the correct value. The standalone lifecycle differential tests it.

## Commands / isolated checks

Build with `swift build --scratch-path .build/f2 --product fluid-swift-peer`. Install that executable
at `.build/debug/fluid-swift-peer` by temporary copy + atomic rename; live farms keep their original
inode. The merge-tree driver hardcodes `.build/f1/debug/FluidMergeTreePeer`, so install the f2-built
merge-tree executable there in the same way. Do not alter a live executable in place.

Full-package sequence tests work now. Earlier concurrent tree compilation failures were handled
with `/tmp/fluid-f2-tests/Package.swift`, whose symlinks point to live source/tests and whose targets
include FluidTestRuntimeUtils and fixture resources. No stale copied implementation is tested.

`npx tsx src/sequence-fixtures.ts` generates the 16 fixtures from TS only.
`npx tsx src/sequence-lifecycle.ts` runs batch rollback/stash/repeated-reconnect differential checks.
`npm run fuzz:summarize -- --seeds=20` uses its existing `.build/m3` harness scratch directory.
Other integration gates used `--scratch-path=.build/f2` where supported. No npm install was run.

## Oracle precondition (unchanged)

Session creates a connected read-only summarizer before editors, excluded from editor/reconnect
selection. Joins/cross-loads use summarizers; editor summaries still compare against twins.
`sequence-oracle-precondition.ts` proves the upstream legacy editor-summary loss and successful
read-only summarizer reload in legacy and V1. Default remains legacy. No seed skip, byte
normalization, event exclusion or default-V1 substitution was used.

Upstream: test-dds-utils/src/ddsFuzzHarness.ts:95-102,733-740,954-959,1502-1514.
The recursive transport uses upstream tree-backed MockStorage; loaded runtime MSN comes from
snapshot metadata, independently of the global last sequence. Obliterate remains disabled as
in the originally scoped sequence/merge-tree lane.
