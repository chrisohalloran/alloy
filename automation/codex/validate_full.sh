#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

"$script_dir/validate_fast.sh"

if [ -d test ] || find apps -type d -name test -print -quit 2>/dev/null | grep -q .; then
  echo "[codex-validate-full] Running tests"
  MIX_ENV=test mix test
fi

if grep -Eqi 'credo' mix.exs; then
  echo "[codex-validate-full] Running Credo"
  mix credo
fi

if grep -Eqi 'dialyxir|dialyzer' mix.exs; then
  echo "[codex-validate-full] Running Dialyzer"
  mix dialyzer
fi
