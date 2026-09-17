#!/usr/bin/env bash
set -euo pipefail

cd "${CURSOR_WORKSPACE:-/workspace}"

export MIX_ENV=test

mix local.hex --force
mix local.rebar --force
mix deps.get
mix compile --warnings-as-errors

mkdir -p priv/plts
if [[ ! -f priv/plts/project.plt ]]; then
  mix dialyzer --plt
fi
