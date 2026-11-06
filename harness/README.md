# Differential counter harness

Node 22, npm, ESM. Install with `npm ci` in this directory.

```
npm run check
npm run fixtures
npm run fuzz -- --peers ts,ts --seeds 0..499
npm run fuzz -- --peers ts,swift --seeds 0..499
npm run replay -- traces/0.jsonl
npm run --silent peer:ts
```

`swift` launches `../.build/debug/fluid-swift-peer`; build that executable separately.
Peer slots are independent processes, including `ts,ts`. Clients rotate across slots.
Each seed gets fresh processes, deterministic Mulberry32 scheduling, and a final checkpoint.
The driver continues after session failures, exits nonzero, and saves every RPC exchange in
`traces/<seed>.jsonl` with peer configuration, seed, and failure reason. Startup failures stop
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
