# T1 — SharedTree change family

## Handoff state

**Partial implementation, not native change-family certification. No git writes.**
Resume from identity foundation commit `72109d9` plus the uncommitted work below.
Other lanes' files are untouched; PROTOCOL.md edits are confined to T1.

Native `FluidTree`:
- Existing RevisionTagCodec, ChangeAtomIdCodec, DefaultAtomIdAliasAllocator.
- New SequenceFieldEditor and editor-produced SequenceMark/SequenceMarkEffect.
  Insert, remove, revive, move, moveIn/moveOut, returnNodes and buildChildChanges.
  Handles overlapping move destinations by splitting IDs and idOverride.
  Preserves upstream zero-count behavior (not identical for every operation).
- No sequence compose/invert/rebase or codecs yet. Mark effects currently model
  editor outputs only, not Rename or AttachAndDetach. No optional/modular port.

Test-first evidence: SequenceEditorTests initially failed to compile with
`cannot find type 'SequenceMark' in scope` (`/tmp/t1-sequence-red.log`). After
implementation, all eight FluidTree tests pass, including 1,000 real-TS identity
fixtures and 1,000 new sequence-editor fixtures covering 7,000 edit outputs.
The latter are structural editor tests, NOT field codec or algebra certification.
Fixture generator: `sequence-fixtures.ts`. No Foundation JSON on the fixture path.

## Comparison rules and current failure

Coordinator's decision is implemented in `oracle.ts`:
- Algebra results: modular 5 exact bytes, semantic/byte roundtrip, plus a tagged
  structural projection preserving Maps, Sets, undefined and metadata.
- Individual edits: context revision supplied; exact modular wire bytes for
  gates 2.0/2.43/2.80/2.117 -> modular 3/4/5/5. Gate selection uses the actual
  Message codec builder. See PROTOCOL.md for runtime precedence and overrides.
- `codec-precondition.ts` is retained unchanged. Seed 17 now passes.
- `wire-check.ts` passes 1,000 seeds / 24,000 individual edits / four gates, TS
  versus TS only. It does not prove that generated histories share a valid base.

The full TS farm now fails at **seed 75**, `0x8a0` (inconsistent cell ordering).
`history-precondition.ts` reproduces it with three edits: remove b[2..5), revive
root:32 at b[3], revive root:32..34 at b[2]. These cannot describe the same base
cell order. The old generator invented detached root IDs at arbitrary positions;
a forest-backed generator with real detach history must replace that assumption.
`scenario.ts` only extracts the original generator; it does not alter its random
schedule. No seed is skipped, no failing assertion suppressed.

## Verified commands

From `harness`:

```
npm run check
npx tsx src/tree/wire-check.ts
npx tsx src/tree/codec-precondition.ts
npx tsx src/tree/history-precondition.ts
npm run fuzz:tree-changes -- --self --seeds=1000
```

The wire check and both documentation repros pass. The full farm is RED at 75.
The latest global `npm run check` fails solely in concurrent H4 work:
`src/routing/oracle.ts:181` TS2352 (partial storage cast). Do not modify that lane.
T1 is additionally checked with the same strict compiler options scoped to tree.

From repository root:

```
swift test --scratch-path .build/t1 --filter FluidTreeTests
```

All eight pass; log `/tmp/t1-sequence-tests.log`. Target-only fallback if another
lane temporarily fails to compile:

```
swift build --scratch-path .build/t1 --target FluidTreeTests
xcrun xctest .build/t1/out/Products/Debug/FluidTreeTests.xctest
```

## Next work, in dependency order

1. Build valid shared histories with actual tombstones/detach IDs and forest
   application; retain seed-75 repro as documentation. Finish upstream axioms.
2. Red tests for sequence compose/invert/rebase and both codecs, then port their
   dependencies and implementation. Editor-only types must grow to full marks.
3. Optional-field handler/codecs.
4. ModularChangeFamily cross-field keys, node changes, invalidation/amendment,
   modular codecs and Swift peer transport.
5. Full 1,000-seed Swift-vs-TS gate under BOTH comparison contracts; plant and
   revert the required rebase tie-break mutation. Not performed in this pass.

No npm install. No git writes. Use `.build/t1`; leave other agents' lanes alone.
