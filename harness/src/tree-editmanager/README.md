# T3 — SharedTree EditManager

Differential harness for the native Swift port of `shared-tree-core/editManager.ts`,
`branch.ts`, `core/rebase/utils.ts` (rebaseBranch, findAncestor, findCommonAncestor) and the
EditManager summary codecs (v3, v4, v6, v7, `shared-branches|v0.2`). The change family is the T1
`ModularChangeFamily` on both sides.

## Commands

- `npm run fuzz:tree-editmanager -- --self --seeds=N`: generates each scenario on the real TS
  EditManagers, replays it on fresh TS EditManagers and compares records (determinism check).
- `npm run fuzz:tree-editmanager -- --seeds=N [--first=K]`: builds `FluidTreeEditManagerPeer` in
  release with `--scratch-path .build/tree-em` and compares its records with the TS records.
- `npx tsx src/tree-editmanager/fixtures.ts`: regenerates
  `Tests/FluidTreeTests/Fixtures/edit-manager.json` for `EditManagerTests.swift`.
- Strict check: `npx tsc --noEmit -p src/tree-editmanager/tsconfig.json`.

Failures write the scenario, first divergent row and both record arrays to
`traces/tree-editmanager/`. The peer has a 60-second response deadline.

## Scenario

`scenario.ts` picks each action from the live TS state, so every edit is valid in its peer's local
view (trunk length at the peer's last processed seq plus the deltas of its local commits). Peer 0
is an observer that never edits. Actions:

| action | effect |
| --- | --- |
| `edit` | 1–3 local commits (insert, remove, move, cross-field move, nested insert; optional custom metadata) applied to the peer's local branch, submitted as one message with refSeq = last processed seq |
| `noop` | the peer reports its refSeq to the sequencer |
| `sequence` | the oldest queued message of a peer gets the next seq; msn = max(msn, min client refSeq) |
| `deliver` | the peer decodes (modular v5) and adds the next sequenced message, optionally split into two bunches with the same seq, then advances the msn |
| `retention` | `setHistoryRetention(true / false / 0 / 1 / 2 / 4)` |
| `fork`, `rebaseFork`, `disposeFork` | forks of the local branch, which EditManager tracks for trimming |
| `join` | a new peer loads a summary (random format) of a summarizable peer and continues from its seq |

All EditManagers share one ID compressor; each minted revision is finalized immediately, so
op-space revisions decode under any originator session.

## Records

After each action the touched peer records: latest sequence number and longest branch length;
every trunk commit (encoded revision + modular v5 bytes); the local branch head and every local
commit; every live fork head; and, when the local branch is at the trunk head, the encoded summary
in all five formats (calling `getSummaryData`, which trims, at the same points on both sides).
Wire rows record each submitted edit's bytes; sequencer rows record seq, msn and refSeq; join rows
record the loaded summary bytes.

## Not covered

Shared (non-main) branches (`addNewBranch`, `sequenceBranchCreation`) are ported but not driven
by the scenario, so the vSharedBranches `branches` array and branch ids are only encoded empty.
Edits on forks, `removeAfter`, transactions and the telemetry batcher are out of scope.
