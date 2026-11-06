# First native Fluid performance baseline

Measured 2026-11-06. **Diagnostic baseline, not a stable CI threshold or an on-device result.**
All nine workloads completed in release Swift on macOS and the iOS Simulator, and in the real
Fluid 3.11.0 packages on Node. No production implementation was optimized.

## Environment and interpretation

- Apple M1 Max, MacBookPro18,4, 32 GiB RAM; macOS 27.0 (26A428), arm64.
- Apple Swift 6.4, `-c release` (`-O`, whole-module optimization); deployment targets macOS 15 / iOS 18.
- iPhone 18 Pro Simulator, iOS 27.0, arm64; UUID `CCB6A9E7-B40B-475E-82F3-EDE71EA740F9`.
  It runs on the same Mac CPU. **These are Simulator numbers, not physical iPhone measurements.**
- Node 22.22.3, default production V8 JIT; existing harness dependencies, no install. TS is
  transpiled by the already-installed tsx; there is no Node debug inspector or coverage instrumentation.
- Three fresh processes per workload/environment. Tables show median elapsed time, observed
  min–max, and median process-lifetime peak RSS. Lower time ratios are better; ratios divide by TS.
  Swift uses `ContinuousClock` and `task_info(MACH_TASK_BASIC_INFO).resident_size_max`;
  Node uses `performance.now()` and `process.resourceUsage().maxRSS` (KiB converted to bytes).
  RSS includes startup, setup, runtime/JIT overhead and loaded code; it is **not DDS heap usage**.
  Raw `setupPeakRSSBytes` lets future investigations distinguish setup from the timed phase.
- This is a shared, actively developed checkout. Other agents/builds and Simulator services were
  running. Final runs are sequential between environments, but external work was not suspended.
  One-minute host load ranges are recorded below. Treat ratios as diagnostic, not precise hardware
  comparisons; rerun on an idle host and a physical device before enforcing tight regression gates.
- No actor hops, I/O or locks are added to synchronous DDS loops (§2). Container timing measures
  runtime snapshot hydration/routing, not network, protocol handshake or the Container actor's connect path.

## Results

Host load during macos: 53.3–61.5. Host load during simulator: 26.3–40.7. Host load during ts: 43.6–53.3. 

### SharedString remote ops, 10K UTF-16 units

| Environment | Median ms | Min–max ms | Peak RSS MiB | Time / TS | RSS / TS |
|---|---:|---:|---:|---:|---:|
| Swift macOS | 678.975 | 676.141–706.247 | 14.92 | 2.89× | 0.08× |
| Swift iOS Simulator | 663.302 | 657.384–663.851 | 36.53 | 2.82× | 0.19× |
| TS Node | 235.021 | 233.619–247.100 | 196.25 | 1.00× | 1.00× |

### SharedString remote ops, 100K UTF-16 units

| Environment | Median ms | Min–max ms | Peak RSS MiB | Time / TS | RSS / TS |
|---|---:|---:|---:|---:|---:|
| Swift macOS | 728.404 | 725.337–730.491 | 16.45 | 3.03× | 0.08× |
| Swift iOS Simulator | 708.090 | 684.521–722.578 | 38.02 | 2.94× | 0.18× |
| TS Node | 240.540 | 236.080–243.399 | 205.61 | 1.00× | 1.00× |

### SharedString remote ops, 1M UTF-16 units

| Environment | Median ms | Min–max ms | Peak RSS MiB | Time / TS | RSS / TS |
|---|---:|---:|---:|---:|---:|
| Swift macOS | 916.334 | 910.267–922.070 | 28.92 | 3.80× | 0.14× |
| Swift iOS Simulator | 890.871 | 870.252–912.241 | 49.92 | 3.70× | 0.24× |
| TS Node | 240.970 | 237.263–245.296 | 206.69 | 1.00× | 1.00× |

### Merge-tree local typing + ack, 1M UTF-16 units

100 local insert/ack pairs, not network round-trip latency. Mean per pair within the median batch: macos 53.4 µs, simulator 62.9 µs, ts 140.5 µs.

| Environment | Median ms | Min–max ms | Peak RSS MiB | Time / TS | RSS / TS |
|---|---:|---:|---:|---:|---:|
| Swift macOS | 5.338 | 5.267–5.373 | 15.58 | 0.38× | 0.09× |
| Swift iOS Simulator | 6.293 | 6.288–6.351 | 37.69 | 0.45× | 0.21× |
| TS Node | 14.051 | 13.899–14.182 | 175.58 | 1.00× | 1.00× |

### SharedMap sequenced sets/deletes

| Environment | Median ms | Min–max ms | Peak RSS MiB | Time / TS | RSS / TS |
|---|---:|---:|---:|---:|---:|
| Swift macOS | 91.745 | 91.556–92.404 | 6.59 | 8.60× | 0.04× |
| Swift iOS Simulator | 84.103 | 83.499–84.105 | 28.89 | 7.88× | 0.16× |
| TS Node | 10.672 | 9.607–10.750 | 184.20 | 1.00× | 1.00× |

### SharedMap summarize, 100K keys

| Environment | Median ms | Min–max ms | Peak RSS MiB | Time / TS | RSS / TS |
|---|---:|---:|---:|---:|---:|
| Swift macOS | 499.555 | 491.991–519.908 | 49.84 | 3.45× | 0.21× |
| Swift iOS Simulator | 433.358 | 428.640–437.698 | 64.28 | 2.99× | 0.28× |
| TS Node | 144.903 | 143.611–157.731 | 232.98 | 1.00× | 1.00× |

### SharedMap load, 100K keys

| Environment | Median ms | Min–max ms | Peak RSS MiB | Time / TS | RSS / TS |
|---|---:|---:|---:|---:|---:|
| Swift macOS | 211.292 | 207.434–212.129 | 59.06 | 1.83× | 0.22× |
| Swift iOS Simulator | 202.835 | 201.699–203.129 | 69.28 | 1.76× | 0.26× |
| TS Node | 115.361 | 111.820–119.743 | 263.09 | 1.00× | 1.00× |

### Container runtime snapshot load + 3K catch-up ops

| Environment | Median ms | Min–max ms | Peak RSS MiB | Time / TS | RSS / TS |
|---|---:|---:|---:|---:|---:|
| Swift macOS | 354.171 | 351.026–364.527 | 58.11 | 1.88× | 0.23× |
| Swift iOS Simulator | 346.143 | 336.848–352.254 | 73.30 | 1.84× | 0.29× |
| TS Node | 188.021 | 185.464–196.216 | 253.36 | 1.00× | 1.00× |

### ID compressor generate/finalize/normalize, 100K IDs

| Environment | Median ms | Min–max ms | Peak RSS MiB | Time / TS | RSS / TS |
|---|---:|---:|---:|---:|---:|
| Swift macOS | 7.479 | 7.363–7.528 | 6.25 | 0.33× | 0.03× |
| Swift iOS Simulator | 11.566 | 11.456–11.722 | 26.25 | 0.52× | 0.15× |
| TS Node | 22.329 | 21.059–22.336 | 180.09 | 1.00× | 1.00× |

## Workload contract

- PRNG: UInt32 LCG, seed `0x12345678`, `state = state * 1664525 + 1013904223` modulo 2³².
  Each string starts as one ASCII `x` segment (exact UTF-16 sizes 10,000/100,000/1,000,000),
  then receives 3,000 sequenced operations from 16 client IDs. Repeating remove/annotate/insert,
  single-unit ranges, insert `z`, annotation `{bold:true}`, uniformly seeded positions, refSeq = seq−1,
  minSeq = max(0, seq−64). No concurrent refSeq skew; this isolates sequenced apply, not rebase.
  SharedString processing/event/interval dispatch runs, but no explicit intervals/listeners are installed.
  Final length is asserted to equal the initial size in both ports.
- Typing uses the **merge-tree Client** under SharedString, one local insertion followed immediately
  by its sequenced local acknowledgment and minSeq advancement, 100 seeded positions at 1M.
  It excludes input/UI, DDS local submission and real network latency. Final length = 1,000,100.
- Map ops: 10,000 remote sequenced operations, alternating numeric-value set and delete of the
  same key (5,000 pairs); final size 0. Op/envelope construction is inside both timed loops.
- Map summary/load: 100,000 deterministic keys `k0`…`k99999`, numeric values 0…99999,
  populated before timing. Summarize includes blob JSON serialization; load starts with an in-memory
  summary and includes JSON parsing/hydration. TS `getAttachSummary()` includes its summary stats;
  Swift uses `summarize()`. Both produce 189 blobs; loaded map size is asserted at 100,000.
- Container: deterministic TS runtime-created summary, 100K map keys plus the existing harness's
  directory/counter, second datastore, aliases, blob redirect table and ID compressor. The generator
  captures a real TS-emitted Map op envelope, then makes 3,000 deterministic catch-up writes from it.
  Generation uses seed 42, fixed entropy and timestamp 1700000000000. The generated JSON is omitted
  from version control because it is several MB; regenerate it with the command below. Both timings
  exclude file read/outer JSON decode and include runtime load, target Map activation, op routing,
  and assertions that A/map has 103,003 entries and `catchup2999 == 2999`.
- IDs: session `00000000-0000-4000-8000-000000000001`, write version 2, 100 batches of
  1,000 generated IDs; finalize each creation range, normalize every ID to op space and back.
  Checksums match across all three environments (94,702,256).
- Fresh processes deliberately include cold V8 execution in the batch. There is no discarded
  warmup or forced GC; these are finite catch-up/startup workloads, not steady-state JIT throughput.

## Sampled hotspots — no fixes in this lane

Retained human-readable stacks: `Raw/profile-string.txt`, `Raw/profile-summary.txt`.
They were sampled separately from the reported timing runs, using release macOS binaries.
Samples are inclusive, not additive percentages; sampling under contention is directional.

1. **Reference sliding materializes the merge-tree's segment list.** String sample:
   `Client.processOperation → Client.slideReferences → MergeBlock.segments.getter`.
   435/788 main-thread samples were under `slideReferences`; 372 were immediately under recursive
   segment enumeration, with array growth, retain/release and allocation in descendants.
2. **Minimum-sequence maintenance also traverses/scours the tree.**
   `SharedSegmentSequence.processMessagesCore → Client.advanceMinimum → MergeTree.zamboni`:
   223/788 samples under minimum-sequence advancement. Inspect its recursive scans/segment copying
   before attributing the mixed-op cost purely to insertion or document length.
3. **Map serialization / JS number formatting.** In the summary sample, 366/371 samples were
   in the timed summarize closure. `SharedMap.summarize → JSON.stringify → JSON.write` and
   `JSON.numberToString → String.UnicodeScalarView.append` are prominent; `JSObject.entries/keys`
   and allocation/copying also appear. This is a CPU serialization hotspot, not evidence of disk I/O.

`xctrace` Time Profiler was available and recorded `Raw/mergetree.trace` locally (ignored binary
artifact); `Raw/xctrace-toc.xml` retains recording provenance. The recording ended early when the
launched target exited. The hotspot counts above come from the explicit `sample` captures, not
from an assumed successful eight-second trace.

## Reproduce

From the repository root, using the existing Xcode and harness dependencies:

```sh
# Deterministic real TS summary + captured wire-op template; no npm install.
(cd harness && npm run bench:ts -- generate)
# Optional: repeat generation and compare SHA-256; output should be byte-identical.
shasum -a 256 Benchmarks/container.json

swift build --package-path Benchmarks -c release --product FluidBench
python3 Benchmarks/run.py macos
python3 Benchmarks/run.py ts
xcrun simctl list devices available
Benchmarks/simulator.sh CCB6A9E7-B40B-475E-82F3-EDE71EA740F9
(cd harness && node node_modules/typescript/bin/tsc --noEmit -p src/bench/tsconfig.json)
python3 Benchmarks/report.py

# Single Node workload:
(cd harness && npm run bench:ts -- string-1000000)
# Single Swift workload (do not use .build/release: SPM repoints it after Simulator builds):
bin=$(swift build --package-path Benchmarks -c release --show-bin-path)
FLUID_BENCH_FIXTURE="$PWD/Benchmarks/container.json" "$bin/FluidBench" container

# Sampling, separate from timing runs:
Benchmarks/profile.sh string-1000000
Benchmarks/profile.sh map-summary
xcrun xctrace record --template 'Time Profiler' --time-limit 8s \
  --output Benchmarks/Raw/rerun.trace --launch -- "$bin/FluidBench" string-1000000 --profile
xcrun xctrace export --input Benchmarks/Raw/rerun.trace --toc
```

`run.py` uses three repetitions and a 540-second subprocess timeout. Each measured batch here
completed in seconds. `simulator.sh` builds an ad-hoc-signed, command-line-style iOS app bundle,
installs it with simctl, and launches each workload with `simctl launch --console`. There is no UI
or XCTest instrumentation in the measurement. It leaves the Simulator booted for further profiling;
shut it down after use with `xcrun simctl shutdown <UUID>`.

## Public API / packaging limitations

The main package exports only the ContainerLoader library (plus Counter). Map and IdCompressor
are reachable transitively, but merge-tree, SharedString and test runtime utilities are not exported
as products. Without changing the main manifest, this package symlinks those source directories
under benchmark-only module names (`BenchMergeTree`, `BenchSequence`, `BenchTestRuntimeUtils`,
`BenchCounter`), with a Swift module alias for Sequence's merge-tree import. All benchmark calls
use public Swift APIs; no production source is copied, patched or optimized. The package itself
still depends on the main package by path and has no new third-party dependencies.

TS uses protected/internal DDS dispatch through reflection, matching the existing differential
harness approach. Container setup adapts the existing `summarize/container-oracle.ts` locally,
without editing that harness or requiring a network service.

Raw JSONL retains all 81 measurements, checksums, peak/setup RSS, host load and process wall time.
`Raw/environment.json` records tool versions, fixture size/hash and the base commit. Because other
agents are editing this checkout, the commit alone does not identify the measured source exactly;
this is an uncommitted working-tree baseline, not a release artifact or a physical-device gate.

Generated fixture: 5,844,641 bytes; SHA-256 `8f4d9753402be1e51eab0f2f70c86205f56e279eb99883fbc7ccd5c6b091e88d`.
