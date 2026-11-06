#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
case_name=${1:-string-1000000}
bin=$(swift build --package-path Benchmarks -c release --show-bin-path)
"$bin/FluidBench" "$case_name" --profile > "Benchmarks/Raw/profile-${case_name}.log" &
bench_pid=$!
sample "$bench_pid" 3 1 -file "Benchmarks/Raw/profile-${case_name}.txt"
wait "$bench_pid"
