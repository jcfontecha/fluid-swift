# T1 — SharedTree change family

## Current state

**Incomplete. The full TS oracle gate is red; no native change-family peer exists.**

Implemented native foundation in the single `FluidTree` target:
- `RevisionTag` / `RevisionTagCodec`, backed by `FluidIdCompressor`.
- `ChangeAtomId` / `ChangeAtomIdCodec`, preserving implicit-context revisions.
- `DefaultAtomIdAliasAllocator`, including the upstream assertion cases.

Six Swift Testing tests cover compressor finalization, remote-origin decoding,
implicit/explicit/root atom revisions, malformed input and the upstream six alias
reservation permutations with four modifiers. The initial four tests failed
against throwing skeletons before implementation. One fixture test additionally
compares 1,000 seeded real-TS identity scenarios byte-for-byte, before and after
compressor finalization. These fixtures are not change-family differential proof.

A temporary `localId + 1` atom-encoding mutation failed the fixture comparison and
roundtrip assertions. It was reverted, rebuilt and the tests rerun successfully.

## Oracle and exact failure

`oracle.ts` imports installed 3.11.0 internals directly: ModularChangeFamily,
ModularEditBuilder, real sequence/optional editors, codecs and RevisionTagCodec.
Each seed builds eight required edits plus sixteen random kinds over a common
base: sequence insert/remove/move/revive, optional set/clear, nested sequence
edits and cross-field moves. The conceptual base has two sequences of at least
12 nodes, populated optional and nested fields, and detached root IDs 32–34.
There is not yet a forest applying and validating this conceptual base.

It observes compose, undo, rollback and rebase (including composed/inverted
bases), using modular codecs 3/4/5, sequence 2/3 and optional 2. Current axioms:
codec semantic/byte roundtrip, singleton composition, rebase over empty and
rebase over composition. Independent TS executions compare exact encoded strings.
No seed skipping, normalization or writer-version exclusion.

The initial fixed-eight-edit farm passed 1,000 seeds. That weaker schedule was
replaced, not retained as the gate. **The current farm fails at seed 17.**

Two-edit reproduction in `codec-precondition.ts`:
1. Move three nodes from sequence b at index 2 to sequence a at index 9.
2. Rebase a concurrent move in b (index 2, count 1, destination 7) over it.
3. Compose the first change and rebased second change.
4. The real result includes a Rename and two revisions. Modular codec 3's
   sequence codec 2 encodes Rename as AttachAndDetach without explicit revisions,
   then its internal roundtrip decoder asserts `0x996` (missing context revision).
5. Supplying a context revision instead asserts `0x964`: tagged encoding permits
   only one matching non-rollback revision. Codecs 4/5 roundtrip the same result.

This proves the **raw multi-revision result serialization contract** fails in TS,
not that normal SharedTree submission fails. Do not fix it by patching the oracle
or deleting seed 17. Next investigate the upstream transaction/commit revision
replacement path and explicitly distinguish raw algebra-result comparison from
single-revision wire serialization before choosing the comparison contract.

## Commands

From `harness`:

```
npm run check
npm run fuzz:tree-changes -- --self --seeds=1000
npx tsx src/tree/codec-precondition.ts
npx tsx src/tree/identity-fixtures.ts
```

The fuzz command is expected RED at seed 17. The minimal repro succeeds when it
confirms the upstream failures and v4/v5 roundtrips. The default fuzz invocation
without `--self` fails explicitly: no Swift peer has been implemented.

From repository root:

```
swift test --scratch-path .build/t1 --filter FluidTreeTests
```

If concurrently edited unrelated test targets do not compile, build and execute
only T1 (this checkout currently selects the Xcode SwiftPM build system):

```
swift build --scratch-path .build/t1 --target FluidTreeTests
xcrun xctest .build/t1/out/Products/Debug/FluidTreeTests.xctest
```

The first full filtered build encountered F1 ModelTests compilation errors; no
F1 files were changed. The target-only build and actual Swift Testing execution
succeeded. After concurrent edits settled, the final standard
`swift test --scratch-path .build/t1 --filter FluidTreeTests` also passed all six
tests. `npm run check` passed.
Local experiment logs: `/tmp/t1-red.log`, `/tmp/t1-planted-test.log`,
`/tmp/t1-final-build.log`, `/tmp/t1-final-tests.log`, `/tmp/t1-full-final.log`
(not durable artifacts).

## Remaining, dependency order

1. Resolve the raw-result versus tagged-wire codec precondition above. Complete
   forest-backed valid-history generation, upstream axioms, fixture/replay and
   native-peer transport. Neither TS self-comparison nor identity fixtures count
   as the required native change-family differential.
2. Port key sequence/optional/modular compose/invert/rebase unit tests, red
   against native APIs. Those algebra tests and APIs do not exist yet.
3. Remaining atom/revision machinery (range maps, revision replacer, metadata),
   field handlers and their codecs; ModularChangeFamily node maps, cross-field
   keys, invalidation/amendment and modular codecs. None of this is certified.
4. Full 1,000-seed Swift-vs-TS farm for all enabled kinds and versions; plant and
   revert an algebra divergence such as concurrent-insert tie-breaking.

No git writes or dependency installation. Shared Package.swift/package.json/
PROTOCOL.md edits are minimal; other agents' files remain untouched by T1.
