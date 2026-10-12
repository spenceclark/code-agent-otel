# Findings: DeepSeek Harness (extra, not in the post)

Out-of-interest fourth agent, run through the same kit and prompt on 2026-10-12. One run per
mode, so read the numbers as anecdotes. Setup is in README "DeepSeek Harness (extra)".

- **Agent:** DeepSeek Harness (`dsh`) 0.1.2-rc.1, headless profile (`dsh --profile headless "<prompt>"`)
- **Exporters:** `@loongsuite/dsh-plugin` 0.1.3 (traces + metrics) and DSH's built-in
  `@deepseek-ai/dsh-session-telemetry-otel` (logs)
- **Model:** `x-ai/grok-4.7` via OpenRouter (this machine's DSH default; not tier-matched)
- **Runs:** `dsh-default-20261012-132501`, `dsh-full-content-20261012-132712`

Both runs finished the task (6 and 7 tests passing, per the agent's own `pytest` tool result),
exit 0. Headless has no approval answerer, so `ask` decisions fail closed, but the default
`workspace-write` mode let every tool this task needed run on Windows.

## Two exporters, two owners

| | `@loongsuite/dsh-plugin` | built-in `dsh-session-telemetry-otel` |
|---|---|---|
| Who ships it | Alibaba's LoongSuite, a separate install (`dsh plugin add`) | DeepSeek, mounted by `dsh-base` |
| Signals | traces + 2 metrics | logs |
| Default | on once installed, content off | `FEEDBACK_ONLY`: uploads only when you record `/feedback` |
| Default endpoint | OTel default (`localhost:4318`) | `https://harness-telemetry.deepseeksvc.com/v1/logs` (DeepSeek) |
| Endpoint var | `OTEL_EXPORTER_OTLP_ENDPOINT` (base, it appends `/v1/*`) | `DSH_TELEMETRY_OTLP_URL` (full path) |
| Content switch | `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=SPAN_ONLY` | `DSH_TELEMETRY_MODE=FULL` (all or nothing, unredacted) |
| `OTEL_RESOURCE_ATTRIBUTES` | honoured (`kit.run.id` present) | ignored |
| Resource | `service.name`, `host.name`, `service.instance.id` (`deepseek-harness@<host>:<pid>`), `gen_ai.agent.system`, `acs.arms.service.feature=genai_app` | `service.name`, `service.version`, anonymous `user.id` (UUID from `$DSH_HOME/.anonymous-user-id`) |

Both report `service.name=deepseek-harness`, so the collector's per-service files mix them
(traces/metrics from one, logs from the other). `acs.arms.service.feature` is an Alibaba Cloud
ARMS attribute and `langfuse.observation.completion_start_time` (on LLM spans) a Langfuse
one. Both are hard-coded in the plugin.

## Signals

| | default | full content |
|---|---|---|
| Spans / traces | 22 / 1 | 22 / 1 |
| Metric datapoints | 3 (`gen_ai.client.operation.duration` ×1, `gen_ai.client.token.usage` ×2) | 3 |
| Log records | 0 | 56 (19 `event.type`s) |

The smallest footprint of the four. Metrics are cumulative and arrive in the shutdown flush
(60 s interval, so a short run gets exactly one export).

## Trace shape

The cleanest semantic tree of the four: one trace per turn, nothing internal.

```
enter_ai_application_system  (51408 ms)        ENTRY  op=enter
  invoke_agent deepseek-harness  (51408 ms)    AGENT  op=invoke_agent, turn token totals
    react step  (4435 ms)                      STEP   op=react
      chat x-ai/grok-4.7  (4299 ms)            LLM    op=chat
      execute_tool glob  (88 ms)               TOOL   op=execute_tool
      execute_tool grep  (28 ms)
    react step  (1795 ms)
      chat x-ai/grok-4.7  (1770 ms)
      execute_tool read  (13 ms)   x4
    react step  (33393 ms)
      chat x-ai/grok-4.7  (33320 ms)           <- writes slugify + tests: 3,241 output tokens
      execute_tool edit  (29 ms)   x3
    react step  (8103 ms)
      chat x-ai/grok-4.7  (1668 ms)
      execute_tool pwsh  (6428 ms)             <- python -m pytest -q
    react step  (3544 ms)
      chat x-ai/grok-4.7  (3537 ms)
```

## Attribute mapping

Closest to the GenAI conventions, along with Qwen, and in some ways closer:

- `gen_ai.operation.name` on every span (`chat`, `execute_tool`, `invoke_agent`, plus
  non-standard `enter` and `react`). Span names follow `{op} {model|tool|agent}`.
- `gen_ai.provider.name=openrouter` (current name, not the deprecated `gen_ai.system`),
  `gen_ai.request.model` / `response.model`, `gen_ai.response.finish_reasons`,
  `gen_ai.conversation.id`, `gen_ai.tool.name` / `type` / `call.id`.
- Content attributes use the current semconv names: `gen_ai.input.messages`,
  `gen_ai.output.messages`, `gen_ai.system_instructions`, `gen_ai.tool.definitions`,
  `gen_ai.tool.call.arguments`, `gen_ai.tool.call.result`.
- The metrics use semconv names and units (`s`, `{token}`, `gen_ai.token.type`). semconv `main`
  has an unreleased change (`changelog.d/521`) that moves inference timing to
  `gen_ai.client.inference.duration` and says `gen_ai.client.operation.duration` isn't for
  inference, so `chat` timing will drift off-spec when that ships.
- Non-standard extras: `gen_ai.span.kind` (ENTRY/AGENT/STEP/LLM/TOOL, the LoongSuite/ARMS
  taxonomy), `gen_ai.session.id`, `gen_ai.turn.id`, `gen_ai.step.id`, `gen_ai.react.*`,
  `gen_ai.usage.total_tokens`, `gen_ai.response.time_to_first_token`, and `dsh.*`
  (`session.id`, `session.cwd`, `turn`, `step`, `llm.attempt`, `turn.end_reason`).
- **TTFT is off-spec in name and unit.** The registry attribute is
  `gen_ai.response.time_to_first_chunk`, a double in seconds (what Qwen sends). The plugin sends
  `gen_ai.response.time_to_first_token` as integer nanoseconds (`3805336800` = 3.8 s).
  `gen_ai.usage.total_tokens` isn't in the registry either (checked semantic-conventions-genai
  `main`, 2026-10-12).
- Span kinds: `chat` and `invoke_agent` are CLIENT, ENTRY is SERVER, tools and steps are
  INTERNAL. Every span had status OK.

## Numbers

| | default | full content |
|---|---|---|
| Root span | 51.4 s | 30.0 s |
| LLM calls (spans) | 5 | 5 |
| Tool calls | 10 (glob, grep, read ×4, edit ×3, pwsh) | 10 (same) |
| Input / cache read / output tokens | 58,658 / 32,512 / 3,727 | 56,355 / 44,160 / 2,491 |

- **Internally consistent.** The `invoke_agent` totals equal the sum of the 5 `chat` spans,
  and the metric sums (58,658 input, 3,727 output, 44.6 s across 5 operations) match the spans
  exactly. As the plugin docs warn, a backend that sums every span in the trace counts tokens
  twice; `summarise.sh` does too (6 values: 5 LLM + the AGENT aggregate).
- **`input_tokens` includes cache reads** on the plugin's spans (like Codex and Qwen, unlike
  Claude). DSH's own log records use the other meaning: `usage.inputTokens` excludes cache
  (8,632 + 1,152 cached = the plugin's 9,784). So one agent's two exporters disagree on
  what "input tokens" means.
- **A sixth, untraced model call.** DSH asks the model for a session title
  (`session/title-llm-request`, sent to `x-ai/grok-4.7` with the user's prompt). It shows up
  only in the built-in logs, with no span, and neither exporter records its tokens. Same
  pattern as Claude's span-only `agent_classifier`, but the other way round.
- No cost signal.

## Privacy

| | default | full content |
|---|---|---|
| Prompt canary | 0 | spans 7 (ENTRY, AGENT, 5× `chat`), logs 3 |
| File-content canary | 0 | spans 5 (3× `chat`, `read`, `edit`), logs 3 |
| Always present | `dsh.session.cwd` (full working-directory path) on every span; `host.name` + pid | + `session.cwd` on every log record, anonymous `user.id` |

- **Default is genuinely content-free** on both exporters: no prompt, no file contents, no
  email or account IDs. Together with Claude, the only agents here that redact by default.
  The path in `dsh.session.cwd` will carry the username for most real working directories.
- **The built-in exporter's FULL mode is the raw session log.** It includes the full system
  prompt and tool schemas (`request/header`), every message, tool call and result, the
  title-generation request, and sandbox/approval policy events. There is no redaction unless
  a deployment mounts its own rules.
- **Its default is FEEDBACK_ONLY, aimed at DeepSeek.** Nothing leaves in a headless run, but
  in an interactive session, `/feedback` uploads that raw session log to `harness-telemetry.deepseeksvc.com`.
  That's the documented design, not a leak, but it's worth knowing. `DSH_TELEMETRY_DISABLED`
  (any value) turns it off; `DSH_TELEMETRY_OTLP_URL` redirects it.

## In Logfire

Both runs replayed with `scripts/replay.sh <run> logfire` on 2026-10-12 around 14:38 UTC (EU
region, ~2 h after capture). `collector/replay.yaml` now also strips `service.instance.id`,
because the plugin's value is `<service>@<host>:<pid>`. Verified with the SQL query API:

- **Everything arrived:** 22 + 22 spans, 56 logs, 6 datapoints, and none of `host.name`,
  `service.instance.id` or `user.id`.
- **The Agents view picks DSH up and works well** (UI checked by the user, screenshots
  `logfire-09-dsh-agent-metrics.jpg`, `logfire-10-dsh-agent-run-trace.jpg`; Qwen got "No agents
  detected", FINDINGS §7). The agent page shows runs, tokens, latency, errors and a run list
  (conversation id, model, duration, tokens). A full-content run opens on Summary (input, final
  output), Tools (all 26 offered tools from `gen_ai.tool.definitions`, with call counts),
  Messages (rendered conversation) and Trace (per-step token roll-ups).
- **Why DSH and not Qwen:** both agents' spans carry `logfire.agent_run_candidate.v1=true`, so
  the flag isn't the gate. DSH's agent span differs in being named
  `invoke_agent deepseek-harness` (Qwen: `qwen-code.interaction`), not being the root (it sits
  under ENTRY), and also carrying `logfire.model_call_candidate.v1`. That points to the span name
  but doesn't isolate it.
- **The time-to-first-token chart says "No data"**: the plugin's
  `gen_ai.response.time_to_first_token` isn't the name Logfire reads.
- **Agent totals are right, one run total is doubled.** The agent page says 121.2k tokens over
  "10 of 10 model calls" (5 per run, matching the spans), and the collapsed run rows are right
  (56.4k / 2.5k and 58.7k / 3.7k). An expanded run's summary says 112.7k input / 5.0k output for
  the 56.4k / 2.5k run: it adds the `invoke_agent` aggregate, which Logfire also flags as a model
  call (`logfire.model_call_candidate.v1=true` on all 5 `chat` spans *and* `invoke_agent`). The
  plugin's double-count warning, in one place. (My SQL-only reading, "each turn shows 6 model
  calls", was wrong: the UI's model-call count is 5 per run.)
- **The run's "input" is DSH's skill catalog.** In the full-content run, Logfire shows the
  conversation's first message as the input: a synthetic `<system-reminder>` listing the skills
  DSH found in `~/.agents/skills` (`hf-cli`, `no-ai-slop`), injected before the prompt. It's on
  all 5 `chat` spans' `gen_ai.input.messages` and one `user/message` log record. Content mode
  only.
- **Cost shows "Unpriced"** for all 10 model calls: DSH sends no cost, and Logfire didn't
  estimate one for `x-ai/grok-4.7` via OpenRouter either (run rows show `—`).
- **The built-in logs arrive as 56 one-record traces with the message `log`.** They have no
  trace context (no `traceId`/`spanId`), so Logfire gives each one a synthetic trace. They have
  no event name either: the type is in the `event.type` attribute, and the structured body lands
  in the `log_body` column. The only join to the plugin's trace is the session id (`session.id`
  on logs = `gen_ai.session.id` / `dsh.session.id` on spans). Their resource has no
  `kit.run.id`, because the built-in exporter ignores `OTEL_RESOURCE_ATTRIBUTES`.

## Setup friction

- Two config surfaces for two exporters: 2 env vars in the kit (`OTEL_EXPORTER_OTLP_ENDPOINT`,
  `DSH_TELEMETRY_OTLP_URL`), plus the two content switches in full-content mode.
- `dsh plugin add` shells out to `pnpm`. This machine had a dead `pnpm` shim; a one-line
  `pnpm.cmd` calling `corepack pnpm@10.28.2` on `PATH` worked. It also created the
  `headless` profile on first use.
- The plugin supports dsh `<0.2.0`; npm `latest` is already 0.2.0-rc.2. Pin both.
- The plugin speaks OTLP/HTTP protobuf only (no gRPC), so it needs the collector's 4318.
- Headless takes no `--model`; the model comes from `~/.dsh/settings.yaml`.
- No gotchas of the "silently exports nothing" kind: both exporters worked on the first try.
