# AGENTS.md

Guidance for AI agents working in the Alloy repository.

## Project

Alloy is a minimal, OTP-native Elixir agent harness. See [README.md](README.md) for architecture and [CONTRIBUTING.md](CONTRIBUTING.md) for contribution workflow.

## Development commands

```bash
mix deps.get
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
```

Run the full suite before finishing work. CI uses Elixir 1.19 and OTP 27 with `MIX_ENV=test`.

## Cloud Agents

This repository ships a Cursor Cloud Agent environment in `.cursor/`.

| File | Purpose |
| --- | --- |
| `.cursor/environment.json` | Environment definition (Docker base + install hook) |
| `.cursor/Dockerfile` | Elixir 1.19 / OTP 27 base image aligned with CI |
| `.cursor/install.sh` | Idempotent bootstrap: deps, compile, Dialyzer PLT |

After checkout, the install script fetches dependencies, compiles with `--warnings-as-errors`, and builds the Dialyzer PLT when missing. Re-run `./.cursor/install.sh` if `mix.lock` changes.

Quality gates match CI — verify with:

```bash
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
```

Tests use `Alloy.Provider.Test`; no live LLM API keys are required for development or CI. Do not commit secrets. Use Cursor environment secrets for any optional live provider smoke tests.
