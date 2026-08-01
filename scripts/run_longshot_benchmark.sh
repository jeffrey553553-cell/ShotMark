#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${SHOTMARK_LONGSHOT_BENCHMARK_DIR:-/tmp/shotmark-longshot-benchmark}"
RUNTIME_ROOT="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies"
NODE_BIN="${SHOTMARK_NODE_BIN:-$(command -v node || true)}"

if [[ -x "$RUNTIME_ROOT/node/bin/node" ]]; then
  NODE_BIN="$RUNTIME_ROOT/node/bin/node"
  export NODE_PATH="${NODE_PATH:-$RUNTIME_ROOT/node/node_modules}"
fi

if [[ -z "$NODE_BIN" ]]; then
  echo "error: Node.js is required to render the browser benchmark." >&2
  exit 1
fi

cd "$ROOT_DIR"
if [[ $# -gt 0 && -n "$1" ]]; then
  "$NODE_BIN" scripts/generate_longshot_benchmark.mjs "$OUTPUT_DIR" "$1"
else
  "$NODE_BIN" scripts/generate_longshot_benchmark.mjs "$OUTPUT_DIR"
fi
SHOTMARK_LONGSHOT_BENCHMARK_DIR="$OUTPUT_DIR" \
  swift test --filter LongScreenshotStitcherTests/testRenderedBrowserBenchmarkCorpusWhenAvailable
