#!/usr/bin/env bash
# Search latency on 10k synthetic records, optimized like the shipped app (budget: p95 < 50 ms).
set -euo pipefail
cd "$(dirname "$0")/.."
exec scripts/test.sh -c release -Xswiftc -enable-testing --filter SearchBenchmarkTests "$@"
