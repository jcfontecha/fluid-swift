#!/usr/bin/env python3
"""Fresh process per workload; 3 repetitions; every subprocess has a 9-minute bound."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
CASES = ['string-10000', 'string-100000', 'string-1000000', 'typing', 'map-ops', 'map-summary', 'map-load', 'container', 'ids']
p = argparse.ArgumentParser()
p.add_argument('environment', choices=['macos', 'ts', 'simulator'])
p.add_argument('--device')
p.add_argument('--binary')
p.add_argument('--repetitions', type=int, default=3)
a = p.parse_args()
if a.environment == 'macos' and not a.binary:
    bin_dir = subprocess.check_output(['swift', 'build', '--package-path', 'Benchmarks', '-c', 'release', '--show-bin-path'], cwd=ROOT, text=True).strip()
    a.binary = str(Path(bin_dir) / 'FluidBench')
output = ROOT / 'Benchmarks' / 'Raw' / f'{a.environment}.jsonl'
env = dict(os.environ, FLUID_BENCH_FIXTURE=str(ROOT / 'Benchmarks/container.json'))
with output.open('w') as f:
    for repetition in range(a.repetitions):
        for case in CASES:
            if a.environment == 'ts':
                cmd = ['node', '--import', 'tsx', 'src/bench/bench.ts', case]
                cwd = ROOT / 'harness'
            elif a.environment == 'macos':
                cmd = [a.binary or str(ROOT / 'Benchmarks/.build/release/FluidBench'), case]
                cwd = ROOT
            else:
                cmd = ['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', a.device, 'dev.fluid.benchmark', case]
                cwd = ROOT
            start = time.time()
            run = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=540)
            rows = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
            if run.returncode or not rows:
                raise RuntimeError(f'{cmd}: {run.returncode}\n{run.stdout}\n{run.stderr}')
            for row in rows:
                row.update(repetition=repetition, environment=a.environment, load=os.getloadavg(), wallSeconds=time.time()-start)
                f.write(json.dumps(row) + '\n')
                f.flush()
                print(json.dumps(row), flush=True)
