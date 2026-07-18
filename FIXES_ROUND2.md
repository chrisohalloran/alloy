# Review findings — round 2 fixes

Your implementation passed the gates but review found defects. Fix ALL items below.
Same ground rules as RELEASE_SPEC.md: no commits, no new deps, run
`mix format --check-formatted && mix credo --strict && mix test` before finishing.

## F1 (CRITICAL) — Tool-result clearing never fires in the canonical agent shape

`lib/alloy/context/compactor.ex`: `clear_tool_results/2` gates eligibility on
`message_index < protected_from_index` where `protected_from_index = last_real_user_index(messages)`.

In the PRIMARY Alloy use case — ONE user prompt followed by a long tool loop
(`[user, assistant(tool_use), user(tool_result), assistant(tool_use), user(tool_result), ...]`)
— the last REAL user message (tool_result messages don't count, `real_user_message?/1`
excludes them) is index 0, so `message_index < 0` is never true and stage 1 silently
no-ops. Your tests only pass because every clearing test appends a trailing
`Message.user("latest")`.

Fix: REMOVE the `protected_from_index` gate entirely. Eligibility is already correctly
bounded by `old_indexes` (messages outside the keep-recent token window, never the first
message, never the previous summary) minus the global keep-last-N tool-result positions.
Delete `last_real_user_index/1` if unused after this.

Add the canonical regression test (this must FAIL before your fix): messages =
`[Message.user("task")]` followed by 6 alternating `assistant(tool_use)` /
`user(tool_result with ~400 chars)` messages, NO trailing real user message. Assert:
clearing fires, brings the conversation under budget, the provider is NOT called, and
the newest 3 tool results survive verbatim.

## F2 (CRITICAL) — Tail cache breakpoint can land on a thinking block → Anthropic 400

`lib/alloy/provider/anthropic.ex`: `add_cache_to_message_tail/1` puts `cache_control`
on the LAST content block unconditionally. Anthropic rejects `cache_control` on
`thinking` / `redacted_thinking` blocks. Alloy's own loop always ends requests with a
user message, but `Alloy.run/2` accepts arbitrary `messages:` — an assistant-prefill
continuation ending in a thinking block would 400.

Fix: walk the last message's blocks from the end; attach `cache_control` to the last
block whose `"type"` is NOT `"thinking"`/`"redacted_thinking"`. If no block qualifies,
return the message unchanged.

Tests: (a) last message ends `[text, thinking]` → breakpoint on the text block, none on
thinking; (b) last message has only thinking blocks → no cache_control anywhere in that
message; existing tail tests keep passing.

## F3 — Reasoning include flag sent when server-side state is in use

`lib/alloy/provider/openai.ex`: `maybe_put_reasoning_include/2` adds
`include: ["reasoning.encrypted_content"]` whenever `store != true`, even when
`previous_response_id` / `provider_state.response_id` is present (server-side
persistence makes encrypted content unnecessary). Gate the include on the SAME
`stateless_reasoning_echo?/1` predicate used for echoing.

Test: config with `previous_response_id` (and no store) → request has no
`reasoning.encrypted_content` in `include`; config with neither → it does.

## F4 — CHANGELOG: fold the unreleased thinking entry into 0.12.4

`CHANGELOG.md` still has the pre-existing entry above `## [0.12.4]` describing
"surface assistant thinking on run result" / `Alloy.Message.thinking/1` (it was an
unreleased entry when its commit was written). That feature SHIPS IN 0.12.4 — move the
bullet(s) into the 0.12.4 `### Added` section and remove the now-empty section header
above it. Read the file first to see the exact current structure.

## F5 — Telemetry turn consistency between :cleared and :done

`[:alloy, :compaction, :done]` (lib/alloy/agent/turn.ex:103) reports `%{turn: turn_number}`
from the turn loop. Your `[:alloy, :compaction, :cleared]` computes `%{turn: turn + 1}`
inside the compactor. Make :cleared report the SAME turn value :done reports for the same
compaction pass (thread the value or derive it identically), and add a test attaching to
both events in one compaction asserting the turn values are equal.

## F6 — Placeholder/measurement should be bytes, not String.length

`content_chars/1` uses `String.length` (grapheme walk, O(n) on 100KB+ tool results) and
labels the placeholder "chars". Switch to `byte_size/1` for binaries (keep the
`inspect |> byte_size` path for non-binary content), rename the telemetry measurement
`chars_cleared` → `bytes_cleared` (the event is new in this release, renaming is free),
and make the placeholder `"[tool result cleared: N bytes]"`. Update README telemetry
table, CHANGELOG wording, and tests.

## F7 — Strict validation message: mention the required-properties rule

`lib/alloy/tool/registry.ex` `validate_strict_schema!/2`: extend the raise message to
also note that OpenAI strict mode additionally requires every property to be listed in
`required`. One sentence appended to the existing message (we only VALIDATE
additionalProperties; the message just forewarns). Mirror the sentence in the README
strict paragraph.

## Done means

All seven fixes in place, the F1 canonical regression test exists and passes,
`mix format --check-formatted && mix credo --strict && mix test` all green.
Print a summary of files changed per fix.
