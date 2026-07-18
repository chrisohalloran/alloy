# Alloy v0.12.4 — Implementation Spec (single release)

You are implementing a full release for `alloy`, an Elixir agent-harness library (Hex package).
Work through ALL work packages below, in order. Baseline is green: 629 tests, 0 failures.

## Ground rules

- Elixir 1.20 / OTP 28. `deps/` and `_build/` are already present — do NOT run `mix deps.get` (no network).
- Gates that must pass before you consider yourself done: `mix format --check-formatted && mix credo --strict && mix test`. Run `mix test` after each work package, not just at the end.
- Do NOT create git commits. Leave all changes in the working tree.
- No new dependencies. No changes under `.claude/`, `announcements/`, `automation/`, `doc/`.
- Every behaviour change ships with tests. Prefer request-shape tests using the existing test plumbing (see `test/alloy/provider/` and `Alloy.Provider.Test` which records calls).
- Match existing code style: typespecs on public functions, `@moduledoc`/`@doc` updated when behaviour changes, no comments that narrate the diff.
- Alloy's philosophy: minimalist harness ("Pi philosophy on the BEAM"). Thin deterministic code, no new subsystems, no new processes.
- This file (RELEASE_SPEC.md) is untracked working material — do not add it to git, do not mention it in docs.

## WP1 — Fix shipped defect: `Alloy.Testing` default tools reference an unshipped module

`lib/alloy/testing.ex:57,71` defaults `:tools` to `[Alloy.Test.EchoTool]`, but that module
lives in `test/support/echo_tool.ex` and the Hex package ships only `lib` (see `mix.exs`
`files:`). A Hex consumer calling `run_with_responses/2` without `:tools` gets
`UndefinedFunctionError` when `Alloy.Tool.Registry.build/1` calls `mod.name()`.

- Replace the default with an inline tool built via `Alloy.Tool.inline/1` defined inside
  `lib/alloy/testing.ex`, mirroring `test/support/echo_tool.ex` behaviour (same tool name
  and echo semantics so existing tests keep passing).
- Add a regression test asserting every module referenced by `lib/` code resolves within the
  `:alloy` application (e.g. assert the default tools list contains no module whose source
  lives under `test/`). A simple robust form: build the default config and assert each tool
  is either an `%Alloy.Tool.Inline{}` or a module in `Application.spec(:alloy, :modules)`.

## WP2 — Compaction: batched tool-result clearing as the FIRST stage

Research grounding: Anthropic measured tool-result clearing alone at −84% tokens; it is the
"safest lightest touch form of compaction". Clearing must be BATCHED because it invalidates
cached prompt prefixes (their `clear_at_least` guidance) — one big clear, not per-turn drips.

Current state in `lib/alloy/context/compactor.ex`:
- Primary path `compact_messages_in_state/2` (lines ~119-142) goes straight to a paid LLM
  summarization call.
- Tool-result clearing logic already exists (`compact_message/1`, lines ~430-444: replaces
  `tool_result`/`server_tool_result` content with `"[compacted]"`) but only runs in the
  truncation fallback.

New behaviour when over the reserve budget:
1. **Stage 1 (new):** clear the content of `tool_result` and `server_tool_result` blocks in
   ONE batch, oldest-first, on messages OLDER than the keep-recent window, keeping the most
   recent `keep_recent_tool_results` tool results intact (default: 3 — mirrors Anthropic's
   server-side default). Replace content with a short placeholder that names what was cleared,
   e.g. `"[tool result cleared: N chars]"`. NEVER touch thinking blocks, text blocks, or
   anything between the last real user message and pending tool outputs. Re-estimate tokens.
   If now within budget → done, NO LLM call.
2. **Stage 2 (existing):** if still over budget, proceed to the existing summarization path.

Config (under the existing `compaction:` keyword):
- `clear_tool_results: true` (default) — set `false` to skip stage 1.
- `keep_recent_tool_results: 3` (default).
Validate in `lib/alloy/agent/config.ex` like the existing compaction keys.

Telemetry: emit `[:alloy, :compaction, :cleared]` with measurements
`%{results_cleared: n, chars_cleared: n}` and metadata `%{turn: turn}` — follow the pattern
of the existing `[:alloy, :compaction, :done]` event in `lib/alloy/events.ex` /
`lib/alloy/agent/turn.ex`.

Tests (write these FIRST for this WP; they must fail against current behaviour):
- Over-budget conversation with bulky old tool results: assert stage 1 alone brings it under
  budget and NO summarization call reaches the provider (`Alloy.Provider.Test` records calls).
- The most recent 3 tool results survive intact; older ones are placeholders.
- Telemetry `[:alloy, :compaction, :cleared]` fires with correct counts.
- A case where clearing is NOT enough falls through to summarization (provider gets the call).
- `clear_tool_results: false` skips stage 1 entirely.

## WP3 — Never truncate signed thinking blocks (latent 400)

`lib/alloy/context/compactor.ex:436-438` truncates thinking text to 200 chars while KEEPING
the `signature` field. Anthropic requires thinking blocks passed back "complete and
unmodified" (400 error otherwise); Gemini 3 hard-400s on modified thought blocks
(`thoughtSignature` must be resent exactly).

- In the fallback truncation path: if a thinking block carries a `:signature`, DROP the whole
  block; only truncate thinking blocks that have no signature.
- Confirm WP2's clearing stage never touches thinking blocks (add an explicit test).
- Test first: fallback compaction over messages containing signed thinking blocks asserts the
  signed blocks are gone entirely (not modified), unsigned ones may be truncated.

## WP4 — Compaction prompts become user-owned

`lib/alloy/context/compactor.ex:19-74` hardcodes `@summary_system_prompt` and
`@summary_prompt` with no override (12-Factor #2: "Own your prompts").

- Add `summary_system_prompt:` and `summary_prompt:` to the `compaction:` config, defaulting
  to the current module attributes. Wire through `Alloy.Agent.Config` validation (must be
  binaries when present) and use them in `summarize_compaction/2` / `build_summary_prompt/2`.
- Document both keys in the Compactor moduledoc and README compaction section.
- Test: a custom summary prompt shows up in the summarization request captured by
  `Alloy.Provider.Test`.

## WP5 — Model-legible tool errors (stacktraces out of the context window)

Anthropic tool-design guidance: error responses should "clearly communicate specific and
actionable improvements, rather than opaque error codes or tracebacks".

- `lib/alloy/tool/executor.ex:119-123`: the model currently receives
  `Exception.message + full Exception.format_stacktrace`. Change the tool_result content to a
  single actionable line: exception message + the top stack frame only (module.fun/arity +
  file:line), e.g. `Tool read crashed: %File.Error{...} (Alloy.Tool.Core.Read.execute/2 at
  read.ex:41). Check the input and try again.` The FULL stacktrace goes to `Logger.error`
  and stays in the telemetry `:error` metadata.
- `lib/alloy/tool/executor.ex:~174` (`{:exit, reason}` from async_stream): replace
  `"Tool execution crashed: #{inspect(reason)}"` with an actionable message; special-case
  `:timeout` → `"Tool <name> timed out after <N>ms. Try a smaller input or raise :tool_timeout."`
- Tests: assert the model-visible tool_result contains no multi-line stacktrace (no
  `"lib/alloy"` path lines beyond the single top frame); assert `Logger` receives the full
  trace (ExUnit `capture_log`); timeout path names the timeout.

## WP6 — Codex provider honours the loop deadline

HTTP providers get `:receive_timeout` injected from the turn deadline
(`lib/alloy/provider/retry.ex:246`); the Codex Port path ignores it —
`collect_port` blocks on its own `timeout_ms` default 120_000
(`lib/alloy/provider/codex.ex:282-295`).

- In the Codex provider, when config carries `:receive_timeout`, use
  `min(receive_timeout, timeout_ms)` as the effective port timeout (and kill the OS process
  on expiry as it already does on the timeout branch).
- Test: config with a small `:receive_timeout` and large `:timeout_ms` times out at the
  smaller value (there are existing codex provider tests that fake the binary — follow them).

## WP7 — OpenAI Responses API: reasoning-item persistence (biggest provider-fidelity gap)

OpenAI: "we highly recommend you pass back any reasoning items returned with the last
function call… all reasoning items, function call items, and function call output items,
since the last user message." Stateless mode (`store` not true) requires
`include: ["reasoning.encrypted_content"]` and echoing the encrypted reasoning items back.
Currently `lib/alloy/provider/openai.ex` has ZERO handling of reasoning items — they are
dropped, so GPT-5.x loses its reasoning between tool calls.

Design (echo-chamber principle — the harness must round-trip opaque provider state verbatim):
- Parse `reasoning` output items into an assistant-message block:
  `%{type: "reasoning", raw: <the full item map verbatim>}` (keep `id`, `summary`,
  `encrypted_content` — whatever the API returned). Position must be preserved relative to
  sibling items (reasoning items precede the function calls they belong to).
- When building the request `input` from messages, re-emit each `reasoning` block as the raw
  item, verbatim, in its original position. Do not synthesize or reorder.
- When `store` is not `true`, add `"include": ["reasoning.encrypted_content"]` to the request
  body (merge with any existing `:include` config — README shows `include:
  ["inline_citations"]` usage for xAI).
- When `store: true` / `previous_response_id` (provider_state) is used, server-side
  persistence covers it — do not double-send encrypted content if the API errors on it;
  gate the echo on the stateless path.
- Make sure `Alloy.Message.text/1` and downstream result extraction ignore `"reasoning"`
  blocks (they are opaque). Check `lib/alloy/message.ex` extractors.
- Compaction interaction: reasoning blocks live inside recent messages (protected by the
  keep-recent window); WP2 clearing must not touch them — they are not tool_result blocks,
  so this holds by construction. Add one test to prove it.
- Tests (request-shape, using existing openai provider test patterns):
  - A Responses payload with `reasoning` item + `function_call` item parses into blocks that
    survive the round trip: the NEXT request's `input` contains the reasoning item verbatim,
    before its function_call item.
  - Stateless config (no `store`) adds the `include` flag; `store: true` does not.
  - `result.text` unaffected by reasoning blocks.

## WP8 — Strict tool schemas (both labs now recommend as default)

OpenAI: "We recommend always enabling strict mode." Anthropic now has GA `strict: true` per
tool (grammar-constrained sampling). Both require `additionalProperties: false` and all
properties required.

- `Alloy.Tool` behaviour: new optional callback `strict?/0` (default `false`).
  `Alloy.Tool.Inline`: new field `strict:` (boolean, default `false`), validated.
- Anthropic adapter: when a tool is strict, emit `"strict": true` on its tool definition.
- OpenAI adapter (Responses function tools): emit `"strict": true` on the function tool.
- OpenAICompat: emit `"strict": true` inside the function definition object.
- Gemini: no equivalent — omit silently.
- Fail fast with a clear error at config validation (`Alloy.Agent.Config` or
  `Alloy.Tool.Registry.build/1`) if a strict tool's `input_schema` lacks
  `additionalProperties: false` — do NOT silently mutate the author's schema. Error message
  must say exactly what to add.
- Docs: README "Custom tools" section gets a short strict-mode paragraph recommending it.
- Tests: request-shape per provider (Anthropic, OpenAI, OpenAICompat); Gemini omits;
  validation error on non-compliant schema names the fix.

## WP9 — Anthropic conversation-tail cache breakpoint

`cache: true` currently sets breakpoints on system (`lib/alloy/provider/anthropic.ex:~311`)
and the last tool definition (`:~505`) — nothing on message history, so multi-turn agent
loops re-pay input price on the whole conversation every turn. Anthropic best practice:
final breakpoint on the conversation tail so each turn reuses the previous turn's prefix.

- When `cache: true`, also place `"cache_control": {"type": "ephemeral"}` on the LAST content
  block of the LAST message in the request. Total breakpoints stay ≤ 4 (we use 3).
- Handle both string-content messages (wrap to block form if needed — check how the adapter
  serializes string content) and block-list messages.
- Tests: request-shape — tail block carries cache_control; breakpoint count ≤ 4; works for
  both content shapes; no cache_control anywhere when `cache` is not set.

## WP10 — Anthropic advanced-tool-use passthrough

One beta header (`advanced-tool-use-2025-11-20`) unlocks: `input_examples` on tool defs
(measured 72%→90% parameter accuracy) and `defer_loading` (tool search). Alloy already ships
`allowed_callers:` on tools (programmatic tool calling), so this completes the set.

- `Alloy.Tool` behaviour: optional callback `input_examples/0` returning a list of maps.
  `Alloy.Tool.Inline`: `input_examples:` field (list of maps, validated).
- Optional `defer_loading:` on Inline + optional callback `defer_loading?/0`.
- Anthropic adapter: emit `"input_examples"` / `"defer_loading"` on tool defs when present,
  and add the `advanced-tool-use-2025-11-20` beta header when any tool uses either field
  (merge correctly with existing beta headers — memory already adds one; check how
  `context-management-2025-06-27` is merged and follow that pattern).
- Other providers: omit these fields silently.
- Tests: request-shape (fields emitted, header added only when used, header merges with
  memory's header); other providers unaffected.

## WP11 — Docs, changelog, version

- `mix.exs` `groups_for_modules`: move `Alloy.Events` INTO Core; REMOVE the deprecated
  `Alloy.Agent.Events` shim from Core (leave it ungrouped); add a `Memory` group with
  `Alloy.Memory` and `Alloy.Memory.Router`.
- README:
  - New `## Non-goals` section after "Design Boundary": multi-agent orchestration (the
    sub-agents recipe is the answer — "the agent spawns itself via function call"; link the
    recipe), sandboxing (point to `:bash_executor` + containers, as the Built-in Tools
    section already does), sessions/persistence/scheduling/UI (already listed — reference
    them). Keep it to ~8 lines, direct tone.
  - Update the "~7,500 lines" claim to "~9,000 lines" (both occurrences if repeated).
  - Compaction section: document `clear_tool_results`, `keep_recent_tool_results`,
    `summary_system_prompt`, `summary_prompt`, and add 2 sentences on the cache trade-off
    (clearing invalidates cached prefixes → batched clearing amortizes it).
  - Custom tools section: strict mode + `input_examples` short paragraphs.
  - Providers/OpenAI: one paragraph on reasoning-item persistence (automatic; `include` flag
    added when stateless).
- `docs/recipes/mcp-tools.md`: add a short "Remote MCP without a client" note — remote HTTP
  MCP servers can mount server-side via the Anthropic MCP connector (`mcp_servers` +
  beta header) passed through `extra_body`; the client-side recipe remains for local/stdio.
- `CHANGELOG.md`: add a `## 0.12.4` entry at the top covering every WP (follow the existing
  entry style; group as Fixed / Added / Changed / Docs).
- `mix.exs`: bump `@version` to `0.12.4`.

## Definition of done

1. `mix format --check-formatted` clean.
2. `mix credo --strict` clean.
3. `mix test` — all tests pass, including your new ones (expect ~660+ tests).
4. Every WP has tests proving its behaviour.
5. Print a final summary: per WP, what changed (files) and which tests cover it.
