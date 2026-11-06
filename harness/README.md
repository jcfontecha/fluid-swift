# Differential DDS harness

Node 22, npm, ESM. Install with `npm ci` in this directory.

```
npm run check
npm run fixtures
npm run fuzz -- --dds all --peers ts,ts --seeds 0..199
npm run fuzz -- --dds counter,map,directory --peers ts,swift --seeds 0..499
npm run replay -- traces/0.jsonl
npm run --silent peer:ts
```

`swift` launches `../.build/debug/fluid-swift-peer`; build that executable separately.
Peer slots are independent processes, including `ts,ts`. Clients rotate across slots.
Each DDS gets independent processes; each seed resets all clients, starts a fresh RPC trace,
and uses deterministic Mulberry32 scheduling and a final checkpoint.
The driver continues after session failures, exits nonzero, and saves every RPC exchange in
`traces/<dds>-<peer-kinds>-<seed>.jsonl` with peer configuration, seed, and failure reason. Startup failures stop
immediately. Replay compares every response byte-for-byte and rechecks checkpoint divergence;
a reproduced failure exits nonzero. A fixed/different response is reported as changed, never
silently counted as reproduction. RPC responses time out after 10 seconds.

The oracle imports only installed 3.11.0 npm packages. It disables the datastore mock's default
ID compressor, captures factory submissions, and delivers through `MockContainerRuntime.process`.
Summary loading uses `MockSharedObjectServices.createFromSummary` and the real counter factory
load method. Summaries use the public DDS `summarize` method, without rebuilding the tree.

The exact counter summary for value 5 is:

```json
{ "type": 1, "tree": { "header": { "type": 2, "content": "{\"value\":5}" } } }
```

The golden semantics fixture is generated with seed `0x5eed1234`; it contains explicit edge
cases, 1,000 random binary doubles and 1,000 random decimal spellings, plus UTF-16 string and
property-order cases. Its only top-level fields are the four arrays specified in the task.

M1 real-service differential run (build Swift first):

```
swift build  # from repository root
npm run service -- --seeds 0..9
```

Uses private temporary tinylicious storage on port 7073. See the service-mode
protocol section for the raw observation contract and transport trace distinction.

The CLI exits after cleanup: the upstream TS summarizer retains 120-second race
timers after disposal. This does not alter any oracle/client processing.

## Lockstep oracle and remaining surface

Each subject has a same-ID TS twin hosted on the first TS peer. Every subject call
(including joins, membership, reconnect, local edits and local acknowledgements) is
repeated on its twin. Twin output never enters the sequencer. Outbound responses,
state, summary and domain-event journals compare as exact JSON text. Across replicas,
canonical state compares structurally; each summary cross-loads in fresh clients on
both configured peers. Twin-only `queries` (TaskManager assignments, register `keys()`
order, SharedArray entry bookkeeping) compare against the twin; TaskManager and SharedArray
generators also choose operations from them, as the upstream fuzz models do.
See PROTOCOL.md for the full comparison contract and `src/entropy.ts` for UUID inputs.

`src/oracle-precondition-check.ts` retains the original minimal Directory counterexample;
raw summary equality across unrelated local histories is not an upstream invariant.

Counter, Map and Directory are certified implementations; the other eight factories
deliberately fail Swift creation with `not implemented`. Their red suites are the
contract for porting: implement the DDS and its peer adapter exactly as the PROTOCOL.md
per-DDS table states, then run `--peers ts,swift`. Do not mistake registered red factories
for completed ports. Runtime flush/rollback/stash
foundation checks run with `npm run foundation`; the random scheduler does not yet
select these modes, disconnected remote edits or outstanding acknowledgements.

SharedObject handle graph attachment/GC, full listener reentrancy, typed decode-before-
bunch handling, complete rollback branches and full upstream public surfaces remain
outside the current coverage. Quorum/audience utilities are initial utilities, not full
EventEmitter ports. Domain event recording is not proof of complete base-class events.

Local experiment logs live under ignored `results/e1/`; no generated sweep logs belong in the
commit. No E1 command stages, commits or changes branches.

E1 debugging record (the logs themselves are not kept):
- Directory twin-event mismatches (seeds 1, 4, 5, 194, then mixed seed 316) all came from
  a Swift Directory that reinterpreted pending state instead of porting it. The remote-clear
  valueChanged order follows pending key *lifetimes*, which an acknowledged first set does
  not move. SharedDirectory/SubDirectory and MapKernel are now 1:1 ports of `directory.ts`
  and `mapKernel.ts`.
- Planted divergences are caught at the first twin `summarize` comparison (map and
  directory seed 0); a planted summary mutation failed map seed 4000 and passed once removed.
- `npm run foundation` checks turn-based submit, rollback, state, summary and flush for
  Counter and Map against TS. It first failed on the CSN after a rollback: TS never returns a
  rolled-back op's clientSequenceNumber, so the next flush sends CSN 2.

Before random scheduling, each seed exercises a deterministic lifecycle on a subject
(and its twin): undefined/handle writes; Task volunteer/complete/subscribe/abandon;
Queue complete/release; Pact set/delete; and Array indexed insertion, move, move undo,
toggle, bulk insertion and deletion. Random Directory operations walk the actual nested
tree. This prevents operation coverage from depending entirely on lucky seeds.

The SharedArray oracle is red on state convergence (`ts,ts` seeds 56, 78, 121, 189 of 0..199), independently of Swift.
Run `tsx src/oracle-array-precondition-check.ts` for the six-op, one-TS-process proof;
it asserts the actual divergent result and exits successfully when the counterexample
is present. The fuzz gate itself remains strict and exits nonzero. See PROTOCOL.md.
