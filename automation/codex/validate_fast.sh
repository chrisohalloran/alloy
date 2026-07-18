#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

echo "[codex-validate-fast] Compiling $(basename "$repo_root")"
mix compile

if [ -f .formatter.exs ]; then
  echo "[codex-validate-fast] Checking formatting"
  mix format --check-formatted
fi
