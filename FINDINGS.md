# Findings: same prompt, three agents

Raw notes for the blog post, from real runs of this kit. Structure follows the README's
"What to compare" list.

- **Date:** 2026-10-10
- **OS:** Windows 11 (10.0.26300), scripts run from Git Bash, Docker Desktop
- **Agents:** Claude Code 2.1.296, codex-cli 0.162.1, Qwen Code 0.25.0
- **Stack:** otelcol-contrib 0.162.0, Jaeger 2.22.0, Prometheus v3.15.0
- **Run ids** (all under `captures/runs/`, which is gitignored):
  - **Matched tier, default privacy, 3 runs each** (used for every number below):
    - Claude Code + `claude-haiku-5-5`: `claude-default-20261010-183402`, `-183721`, `-183903`
    - Codex + `gpt-6-luna`: `codex-default-20261010-183503`, `-183807`, `-183949`
    - Qwen Code + `qwen/qwen3.8-max-0902` (via OpenRouter): `qwen-default-20261010-184327`, `-184954`, `-185353`
  - Round 1, default privacy, each agent's own default model (`claude-opus-5-5`,
    `gpt-6-astra`, `qwen/qwen3.8-flash`): `claude-default-20261010-151945`,
    `codex-default-20261010-152221`, `qwen-default-20261010-152329`
  - Round 2, full content, same models: `claude-full-content-20261010-152705`,
    `codex-full-content-20261010-152753`, `qwen-full-content-20261010-152902`
  - Failed: `codex-default-20261010-152049-sandbox-failed` and
    `qwen-default-20261010-183559-wrong-endpoint` (see Setup friction)

Every run finished the task: `slugify` added, `truncate` fixed, suite green. For the 9
matched-tier runs I checked this myself by applying each run's `sample-diff.txt` to a fresh
copy of `sample-repo/` and running pytest. All passed (Claude 9/9/8 tests, Codex 5/7/6,
Qwen 11/10/11).

## Caveats (read before quoting any number)

- **Tiers are matched, the models aren't the same.** The matched-tier models (Haiku 5.5,
  GPT-6 Luna, Qwen3.8 Max) score 41, 41 and 43 on the Artificial Analysis coding-agent chart used to pick them.
  Those scores were measured at different effort settings and harnesses than these runs,
  which used each CLI's default effort. Tokenizers differ too, so token counts are
  compared within an agent, never across agents.
- **3 runs per agent for numbers, 1 for privacy.** The matched-tier figures are medians of
  3. The privacy findings come from rounds 1 and 2 (one run each), but they're structural:
  which fields are redacted doesn't change between runs.
- **"Default" means default for this machine.** The user-level config leaked into every
  run:
  - Claude loaded 6 plugins, 10 MCP server connections and the user's hooks (its
    SessionStart and UserPromptSubmit hooks ran inside `claude -p`).
  - Codex loaded the user's MCP servers. Two of them were unreachable and logged errors on
    every turn.
  - Qwen ran its auto-memory extractor as a subagent.

  All of this shows up in the telemetry as `plugin_loaded`, `mcp_server_connection`,
  `hook_*`, `codex.mcp.*` and `qwen-code.memory.*`. This is a finding in its own right: what
  you collect from developers depends on what each of them has installed. I haven't checked
  whether a clean-profile run is possible without losing the login.
- **Round 1 and 2 Claude runs are contaminated.** They were started from inside a Claude
  Code session and inherited its env (`CLAUDE_EFFORT=xhigh`, `CLAUDE_PREVIEW_CLASSIFIER_FLOOR=1`,
  `CLAUDE_CODE_CHILD_SESSION=1`, ...). They ran at `effort=xhigh` and made an extra,
  span-only Haiku `agent_classifier` call. `run-claude.sh` now strips these vars, and the
  matched-tier runs show `effort=medium` and no classifier call. Structural findings from
  those runs still hold (same span names and keys, see below); their numbers don't.
- **`sample-repo/README.md` tells agents the `truncate` failure is deliberate.** Qwen
  quoted it. That makes the "likely retry" step easier than intended.

## 0. The telemetry belongs to the agent, not the model

Across both models for each agent (Opus vs Haiku, Astra vs Luna, Flash vs Max) and every
run, the span vocabulary stayed the same:

| | Span names | Span attribute keys |
|---|---|---|
| Claude (4 default runs, 2 models) | 5 every run | 46 every run |
| Codex (4 default runs, 2 models) | 157 every run | 102 every run |
| Qwen (4 default runs, 2 models) | 6 every run | 65-67 (see below) |

I diffed the actual sorted sets, not just the counts. Claude's and Codex's are identical
across all runs. Qwen's Max runs add `gen_ai.request.temperature` and `error_status_code`,
and `subagent_name` / `is_interrupt` appear only in some runs: optional keys, same
vocabulary.

So everything in sections 2, 3 and 5 is about the agent, whatever model you run it on.
Only volumes and timings move with the model.

## 1. Signals

Matched tier, median of 3 (range in brackets):

| | Claude | Codex | Qwen |
|---|---|---|---|
| Spans | 30 (27-37) | 4,777 (4,710-5,589) | 119 (95-160) |
| Traces | 1 | 266 (250-267) | 8 (2-25) |
| Log records | 49 (46-54) | 55 (48-59) | 82 (63-102) |
| Metric datapoints | 40 (40-46) | 222 (219-225) | 1,460 (776-1,657) |
| Metric names (round 1) | 6 | 64 | 19 |
| `service.name` | `claude-code` | `codex_exec` | `qwen-code` |

- **Claude** is the most compact. Its 6 metrics are all product metrics: tokens, cost,
  lines of code, active time, sessions and edit decisions.
- **Codex** isn't "log-event-first", whatever the docs suggest. Its traces are Rust
  `tracing` instrumentation exported as OTel spans, with attributes like `code.file.path`,
  `code.line.number`, `busy_ns`, `idle_ns` and `thread.name`. Its metrics are mostly
  internals too: sqlite init, skills shadow selection, websocket events, startup phases.
- **Qwen** sits in the middle on spans but sends the most metric datapoints. It
  auto-instruments outbound HTTP (`POST` client spans, `http.client.request.duration`) and
  reports process CPU and memory, so datapoints grow with wall-clock time.
- **`service.name` style differs:** a hyphen for Claude and Qwen, an underscore for Codex.
  I've only seen `codex_exec` (from `codex exec`), not what interactive `codex` reports.

## 2. Trace shape

Render a tree with `jq -nr -f scripts/lib/tree.jq <run>/traces/<service>.jsonl`.
The examples below are from round 1; the shape is the same in the matched-tier runs.

**Claude** gives one clean tree per prompt:

```
claude_code.interaction  (21446 ms)
  claude_code.llm_request  (1996 ms)
  claude_code.tool  (1201 ms)
    claude_code.tool.blocked_on_user  (19 ms)
    claude_code.tool.execution  (1181 ms)
  claude_code.llm_request  (1554 ms)
  ...
  claude_code.llm_request  (2527 ms)
```

**Qwen** uses almost the same shape. Each tool is wrapped in `qwen-code.hook` pre/post
spans, and each LLM call gets an HTTP `POST` child span. The background memory extractor
starts after the interaction ends, and each of its LLM and tool calls is a separate
single-span trace, with no parent linking them. That's why Qwen's trace count swings from 2
to 25: it depends on how much the extractor does.

```
qwen-code.interaction  (68416 ms)
  qwen-code.llm_request  (11317 ms)
    POST  (11146 ms)
  qwen-code.tool  (28 ms)
    qwen-code.hook  (1 ms)
    qwen-code.tool.execution  (6 ms)
    qwen-code.hook  (0 ms)
  ...
qwen-code.llm_request  (42698 ms)     <- memory extractor, own trace
  POST  (42651 ms)
```

**Codex** puts the real work in one huge trace, rooted at a `turn/start` JSON-RPC span:
3,562-4,398 spans and 16 levels deep in the matched-tier runs. The other ~250 traces per
run are small side traces (`persist_rollout_items`, `realtime_conversation.running_state`,
`auth`, ...). Inside the turn trace:

- **Model calls** are timed by `run_sampling_request` / `codex.sampling` (5 per run, up to
  14.7 s each).
- **Tokens** are recorded somewhere else: on a `handle_responses` span that lasts 20-50 ms.
  There are about 1,000 `handle_responses` spans per turn, and only the 5-7 that close a
  response carry `gen_ai.usage.*`.
- **Tool calls** are `dispatch_tool_call_with_state` / `codex.tool_blocking`, under deep
  internal nesting (`run_turn > step_context.capture > built_tools > build_tool_router > ...`).

Most of the trace is internals: filesystem metadata reads, config and skills loading,
and a span per streamed response event. It reads like a profiler dump, not a semantic trace.

## 3. Attribute mapping vs the GenAI semantic conventions

| Concept (semconv) | Claude | Codex | Qwen |
|---|---|---|---|
| Agent span, `gen_ai.operation.name=invoke_agent` | `claude_code.interaction`, no op name | `session_task.turn`, no op name | `qwen-code.interaction`, `invoke_agent` |
| Model call, `chat` | `claude_code.llm_request`, no op name | `run_sampling_request` (timing) + `handle_responses` (tokens), no op name | `qwen-code.llm_request`, `chat` |
| Tool call, `execute_tool` | `claude_code.tool`, no op name | `dispatch_tool_call_with_state`, no op name | `qwen-code.tool`, `execute_tool` |
| Provider | `gen_ai.system` (deprecated name) | none | `gen_ai.provider.name` |
| Model | `gen_ai.request.model` + `model` | `model` (logs only) | `gen_ai.request.model`, `gen_ai.response.model` |
| Tokens | `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens` | `gen_ai.usage.input_tokens` / `output_tokens` / `cache_read.input_tokens` / `cache_write.input_tokens`, plus `codex.usage.*` | `gen_ai.usage.input_tokens` / `output_tokens` / `cache_read.input_tokens` |
| Tool identity | `gen_ai.tool.call.id` + `tool_name` | `tool_name` (logs) | `gen_ai.tool.name` / `type` / `description` / `call.id` |
| Conversation | `session.id` | `conversation.id` | `gen_ai.conversation.id` |
| Response | `gen_ai.response.id`, `gen_ai.response.finish_reasons` | none | same + `gen_ai.response.time_to_first_chunk` |

- **Qwen** is the only one that sets `gen_ai.operation.name`, and the only one you could
  feed to a GenAI-aware backend without remapping.
- **Codex** uses current `gen_ai.usage.*` names for tokens, but puts them on a short
  response-handler span instead of the span that times the model call, with no operation,
  provider or model attributes.
- **Claude** uses its own names for nearly everything. The `gen_ai.*` keys it does use are
  the response/model ones plus the deprecated `gen_ai.system`.
- **`input_tokens` means different things** (matched-tier medians):
  - Claude's `input_tokens` excludes cache reads: 12 input vs 195,633 cache read.
  - Codex's `input_tokens` (88,269) includes its 79,616 cached tokens.
  - Qwen's (383,534) includes its 339,328 cached tokens.

  So summing "input tokens" across agents compares different quantities. Check the
  semconv definition of `gen_ai.usage.input_tokens` before saying which one is "right".

## 4. Numbers

Matched tier, median of 3 (range in brackets). Read each column against itself; see
Caveats for why agents can't be compared directly.

| | Claude + Haiku 5.5 | Codex + GPT-6 Luna | Qwen Code + Qwen3.8 Max |
|---|---|---|---|
| Root span duration | 24.5 s (23.8-27.6) | 35.0 s (27.4-37.3) | 216 s (180-233), + background extraction |
| LLM requests | 6 (5-8) | 5 (5-7) (usage-carrying `handle_responses`) | 14 (12-14) main + 3 (1-9) memory extractor |
| Tool calls | 7 (7-10) | 6 (4-7) `codex.tool_decision` | 16 (15-17) main + 4 (0-15) extractor |
| Output tokens | 3,508 (3,274-4,594) | 1,348 (1,280-1,465) | 12,969 (7,233-14,357), incl. extractor |
| Cost in telemetry | $0.0080 ($0.0073-$0.0088) | none | none |
| Tests at end (re-run by me) | 9 / 9 / 8 | 5 / 7 / 6 | 11 / 10 / 11 |

How well each agent's own signals agree:

- **Claude:** they agree once the inherited env is stripped. In all 3 matched-tier runs,
  the `llm_request` span count equals the `api_request` log count, and the summed log
  `cost_usd` equals the CLI's own `total_cost_usd` exactly. In round 1, an extra span-only
  `agent_classifier` call broke this (see Caveats).
- **Codex** (round 1): the CLI prints `tokens used 10,433` (on stderr, which the kit
  doesn't save). That's non-cached input (9,326) plus output (1,107). The telemetry total
  (`codex.turn.token_usage.total_tokens`) is 88,257, because it includes 77,824 cached
  tokens. The per-call `handle_responses` spans add up to the turn total. No cost signal.
- **Qwen:** its totals agree between spans, logs and the CLI's JSON stats, but they include
  the memory extractor. In round 1 that was 3 of 9 requests and 32,796 of 147,096 prompt
  tokens. The CLI JSON splits this out (`bySource`); in the telemetry you have to separate
  it by trace (the extractor's spans sit outside the interaction trace). No cost signal.
- **Qwen3.8 Max is slow here:** about 3.6 minutes per interaction against 25-35 s for the
  other two. See 4a.

### 4a. Why is Qwen slow? (diagnosed from its spans alone)

Qwen's `llm_request` spans carry `gen_ai.response.time_to_first_chunk`,
`output_tokens_per_second` and `thoughts_token_count`, so the wall-clock time splits
cleanly. Main interaction only; extractor excluded.

| Per run | Qwen Code + Qwen3.8 Max (3 runs) | Claude Code + Haiku 5.5 (3 runs) |
|---|---|---|
| Interaction | 180-233 s | 24-28 s |
| Time decoding (output tokens / tokens per second) | **147-190 s** | ~13-17 s |
| Decode speed | **~41 tok/s** (`output_tokens_per_second`) | ~255 tok/s (rough: `output_tokens` / (span duration - `ttft_ms`)) |
| Output tokens | 6,273-7,947, **51-60% thinking** | 3,274-4,594 |
| LLM requests | 12-14 | 5-8 |
| Summed time to first token | 28-35 s (~2.4 s each) | 3-5 s |
| Tool time | 4-7 s | n/a |

Median run (`qwen-default-20261010-184954`, 216 s): 31 s waiting for first tokens, 178 s
decoding, 6 s in tools.

1. **Slow decoding is about 80% of it.** At ~41 tok/s, one reply with 1,500 thinking
   tokens takes 40-60 s. The slowest single request took 46 s for 1,671 output tokens,
   1,541 of them thinking.
2. **More round trips.** 12-14 requests against 5-8, from more reading (5-7 `read_file`
   against Claude's 0-2 `Read`) and more edits (4-6). Each request pays ~2.4 s before the
   first token.
3. **Not the harness.** Every request is `attempt=1` with `retry_total_delay_ms=0`, tools
   take seconds, and the same harness on `qwen3.8-flash` in round 1 took 68 s (6 requests,
   66 tok/s, 18 s of time to first token).

What I can't tell: whether ~41 tok/s is normal for this model. OpenRouter's only providers
for `qwen/qwen3.8-max-0902` are Alibaba's own two endpoints, and their published
throughput and latency stats were empty when I checked.

Side note: each Max run starts with a background request outside the interaction trace
that fails with HTTP 400 in under 0.5 s. That's where the extra `error_status_code` key in
section 0 comes from. It costs no meaningful time.

Claude's `llm_request` spans (`ttft_ms`, `output_tokens`, `duration_ms`) support the same
kind of breakdown. For Codex you'd have to join `run_sampling_request` durations with
the token counts on the matching `handle_responses` spans, or use the
`codex.turn.ttft.duration_ms` / `ttfm` metrics.

### 4b. Viewing it in Jaeger

Jaeger 2.22 has GenAI support: a GenAI tab in each span's detail panel, plus icons in the
span list (LLM, tool, HTTP). It works only as well as the agent's `gen_ai.*` attributes:

| | Claude | Codex | Qwen |
|---|---|---|---|
| GenAI tab on the LLM span | provider (`anthropic`, from the deprecated `gen_ai.system`) + model. **No tokens**, no operation | **tokens only** (input, output, cache read/write), on the 40 ms handler span. No model, provider or operation | operation `chat`, provider, model, tokens incl. cached |
| Tool spans recognised | no | no | yes ("Tool Call: read_file", wrench icon) |
| Waterfall | clean: one trace, ~30 spans, LLM and tool bars on similar scales (1-5 s) | 3.5k-span, 16-deep trace, mostly internals | proper tree, but every hook span is red and tool bars are slivers next to 10-60 s LLM bars |
| Search list | one row per prompt | the turn trace + ~250 side traces | interaction traces buried among the extractor's 1-4-span fragments |

So following the conventions pays off visibly: on the same backend, Qwen gets token
counts per call and Claude doesn't, purely because of attribute names.

Two Qwen quirks make its traces look worse than they are:

- **Every hook span is marked ERROR.** Each tool call is wrapped in PreToolUse/PostToolUse
  `qwen-code.hook` spans with status ERROR ("hook runner returned no output without error
  detail", `should_proceed=true`), even though `~/.qwen/settings.json` has no hooks. That's
  42 red spans in a 17-tool-call run, and Jaeger counts them as 30-38 errors per trace.
- **Memory extractor spans have no parent**, so each becomes its own trace. With Jaeger's
  default 20-result limit, a Qwen search can return nothing but these fragments. Filter on
  Span Name = `qwen-code.interaction` to find the real traces.

## 5. Privacy

From rounds 1 and 2. The canaries count records containing the string (see PROMPT.md).

| | Claude | Codex | Qwen |
|---|---|---|---|
| Prompt text, default | no (`prompt=<REDACTED>`, `prompt_length` kept) | no (`codex.user_prompt` redacted) | **yes**: 13 log records (`user_prompt`, `api_request` ×9, `tool_call`, `subagent_execution`, `api_response`) |
| File content, default | no | **yes**: `codex.tool_result` `output` and `arguments` (2 records) | **yes**: `api_request` ×8, `tool_call` ×2 |
| Prompt text, full content | `user_prompt` log + `user_prompt` attribute on the interaction span | + `codex.user_prompt` | + `gen_ai.*` messages on every `llm_request` span (15) |
| File content, full content | `tool.output` span event on `claude_code.tool` (logs carry `tool_input`/`tool_parameters`, not output) | unchanged | + `llm_request` ×15, `tool` ×2 spans |
| Identity fields | `user.email`, `user.id`, `user.account_id`, `user.account_uuid`, `organization.id` on every span, log record and metric datapoint | `user.email`, `user.account_id` on log events; `host.name` | none seen (with this auth path) |

- **Codex's `log_user_prompt=false` covers the prompt only.** Tool arguments and tool
  output, which include file contents, are exported by default.
- **Qwen exports the prompt and file contents to logs out of the box** (`logPrompts`
  defaults to true).
- **That includes Qwen's memory.** Its background memory extractor reads and writes
  `~/.qwen/memories/`. With `logPrompts=true`, those file paths (with the Windows username)
  and the memory notes themselves land in `api_request` and `tool_call` log records
  (17 records in `qwen-default-20261010-184954`). So the default telemetry carries what
  Qwen has remembered about the user from other sessions, not just this task.
- **Stripping `user.*` isn't enough.** After every identity key is removed, the Codex run
  still names the user's MCP servers and an internal API hostname (on spans and logs), and
  the Qwen run still has the home-directory username in paths. Scrubbing those takes
  pattern-based redaction of values, not key deletion.
- **Claude is the only one that redacts content by default**, but it puts the user's
  email on every record, including metric datapoints. That matters for metric cardinality
  as well as privacy.
- Qwen showing no identity fields may just reflect its auth path here (OpenRouter). Don't
  generalise it.

## 6. Setup friction

| | Claude | Codex | Qwen |
|---|---|---|---|
| Config surface | 13 env vars (7 needed to export all three signals) | 5 `[otel]` keys, user config or `-c` only | 6 env vars |
| Silent failure modes | no default OTLP protocol, so nothing is exported; traces need the beta flag | `metrics_exporter` defaults to OpenAI (statsig); endpoints need full `/v1/*` paths | `otlpProtocol` uses non-standard values (`grpc`/`http`) |

Problems hit during these runs:

- **CRLF (Windows).** With `core.autocrlf=true`, the scripts and env files checked out as
  CRLF, so bash failed, and sourced env values would have ended in `\r`. `.gitattributes`
  now forces LF.
- **The `bash` WSL trap (Windows).** In PowerShell, `bash` is WSL, which can't see the
  Windows `docker`, `claude` or `codex`. Use Git Bash.
- **Codex's elevated Windows sandbox failed** (`setup refresh had errors`). Every tool call
  was rejected, Codex replied asking to restart the session, and it **exited 0**, while
  still exporting 2,490 spans. Workaround: `-c 'windows.sandbox="unelevated"'`.
  The unelevated sandbox still ran `python -m pytest` fine.
- **Collector uid clash.** A plain `docker compose up` (uid 10001) followed by `scripts/up.sh`
  (uid 197609) caused `permission denied` on `captures/`.
- **Qwen `--model` silently switched endpoint.** `--model qwen/qwen3.8-max-0902`, which
  isn't in the user's `modelProviders`, sent the request to `dashscope.aliyuncs.com`
  (Alibaba) instead of the configured OpenRouter `baseUrl`, with whatever key the `openai`
  auth type resolved to (probably `OPENAI_API_KEY`), and got a 401. Qwen's own HTTP client spans recorded the URL, which is how I spotted it. Fix: pass
  `--auth-type openai --openai-base-url https://openrouter.ai/api/v1` with
  `OPENAI_API_KEY` set from the OpenRouter key for that process.
- **Nested Claude sessions leak env** into `claude -p` (see Caveats). When `CLAUDECODE=1`,
  `run-claude.sh` now strips `CLAUDECODE` and `CLAUDE_*`.

Kit bug found while running: `docker compose` exports its own traces whenever
`OTEL_EXPORTER_OTLP_ENDPOINT` is set, so the stop/start between runs sent `compose` spans
into the next run's capture. `compose()` now scrubs `OTEL_*`. Only
`codex-full-content-20261010-152753/all/traces.jsonl` is affected (4 stray spans); the
per-service files are clean.

## 7. Hosted backends: LangSmith, Langfuse, Braintrust, Logfire

Researched 2026-10-10 from each vendor's own docs. Where the Langfuse docs were silent I
read their source code, and those facts are marked (code). Sources are listed at the end
of the section.

### How they all work

All four accept OTLP over HTTP; none documents gRPC except Logfire. Sending to any of them
is a Collector `otlphttp` exporter with three settings:

1. **An endpoint**, often per region.
2. **An auth header**, plus a routing header on some (project or workspace).
3. **The signals you wire up.** This is where they differ most.

On the server, a mapping layer looks for conventions it knows: its own namespace
(`langsmith.*`, `langfuse.*`, `braintrust.*`), `gen_ai.*`, OpenInference
(`openinference.span.kind`, `llm.*`) and OpenLLMetry (`traceloop.*`). Matching spans
become LLM-aware objects (a "generation", an LLM "run", an `llm`/`tool` span) with model,
tokens, cost and messages. Anything that doesn't match becomes a plain span, with its
attributes kept as metadata.

### Comparison

| | LangSmith | Langfuse | Braintrust | Logfire |
|---|---|---|---|---|
| Base endpoint | `api.smith.langchain.com/otel` (+ `eu.`, `apac.`, `aws.`) | `cloud.langfuse.com/api/public/otel` (+ `us.`, `jp.`, `hipaa.`) | `api.braintrust.dev/otel` (+ `api-eu.`) | `logfire-us.pydantic.dev` / `logfire-eu.pydantic.dev` |
| Auth | `x-api-key`, optional `Langsmith-Project`, `x-Tenant-Id` for org-scoped keys | `Authorization: Basic base64(pk:sk)` + `x-langfuse-ingestion-version: 4` | `Authorization: Bearer <key>` + `x-bt-parent: project_name:<name>` | `Authorization: <write token>` (Collector examples add `Bearer`; the docs disagree) |
| **Traces** | yes | yes | yes | yes |
| **Logs** | not documented | **no** (`/v1/logs` returns 404) | yes (each record becomes a row) | yes |
| **Metrics** | not documented | accepted and **dropped** (code) | not documented | yes (dashboards want delta) |
| gRPC | not documented | no | not documented | yes |
| `gen_ai.operation.name` mapping | `chat` → llm (`execute_tool`/`invoke_agent` not in the table) | `chat` → generation, `execute_tool` → tool, `invoke_agent` → agent (code) | `chat` → llm, `execute_tool` → tool | `invoke_agent` → Agents view; LLMs view keys on `gen_ai.system`/`provider.name` + model + `gen_ai.usage.*` |
| Other conventions | OpenInference, Traceloop, `langsmith.*` | OpenInference, Traceloop, `langfuse.*`, plain `model`/`input_tokens` (code) | OpenInference, `braintrust.*`, **Claude Code span names** | OpenInference / Traceloop for agents; vendor attributes only in Live/Explore |
| Cost | from provider + model via a pricing map | inferred from model for generations | from model via its catalog | `operation.cost` if sent, else estimated from tokens (UI only) |
| Limits that matter here | 25,000 runs per trace | 5 MB per request (cloud) | 10 MB per trace POST | **records older than 24 h are dropped**; 100 MB per request |
| Coding-agent guides | Claude Code, Codex via **hooks** (transcripts); only Copilot via native OTel | Claude Code, Codex via **hooks**; only Copilot via native OTLP | Claude Code via hooks **or native OTel**; Codex via hooks | Codex via native OTel or a hooks plugin; Claude Code via a transcript-reading hooks plugin on Pydantic's GitHub (traces only, not in the docs); no Qwen page, **but the UI has a Claude Code session panel** (observed) |
| Self-host | Enterprise | **MIT open source** | Enterprise | Enterprise |
| Free tier | 5k traces/month | 50k units/month (each span counts) | 1 GB/month, 14-day retention | 10M records/month |

Two patterns stand out:

- **Two of the four are traces-only, and none documents metrics ingestion except
  Logfire.** Most of what these agents put in logs and metrics never arrives there.
- **For Claude Code and Codex, the vendors' recommended integrations bypass the agents'
  OTel entirely.** They use hooks that read the session transcript after each turn.
  Transcripts carry the full conversation, which the OTel defaults redact, and they
  don't depend on how each vendor named its spans.

### What each backend can show from these runs

Inferred from the docs and mappings above. Only Logfire has been tested; see the worked
example below.

| Data | Signal | LangSmith | Langfuse | Braintrust | Logfire |
|---|---|---|---|---|---|
| Claude span tree | traces | yes | yes | yes, with `llm_request` → LLM span (named mapping) | yes |
| Claude tokens per call (`input_tokens`, ...) | traces + logs | not in the mapping | likely (code normalises `input_tokens`) | yes (named mapping) | **yes, in its Claude Code Session panel, read from the logs** (observed) |
| Claude cost (`claude_code.cost.usage`) | metrics | no | no | no | yes, as a metric |
| Codex span tree (~4,700 spans) | traces | fits (under 25k) | each span is a billed unit | yes | yes |
| Codex tokens (`gen_ai.usage.*` on `handle_responses`) | traces | yes, but no model on the span | yes, but no model, so no generation or cost | yes, no model | tokens yes, LLMs view needs model and provider |
| Codex tool output with file contents (`codex.tool_result`) | logs | no | no | yes | yes |
| Qwen chat / tool / agent spans | traces | partly (`chat` only) | yes, all three types | `chat` and `execute_tool` | yes |
| Qwen prompt text (default `logPrompts=true`) | logs | no | no | yes | yes |

So the privacy picture from section 5 depends on the backend. With a traces-only
backend, Qwen's default prompt logging and Codex's default tool-output logging never leave
the Collector. Send logs to Braintrust or Logfire and both arrive.

### Worked example: replaying a run to Logfire

There's no need to re-run the agents. The archived runs are already OTLP, so a one-shot
Collector can read them back and send them anywhere:

```
captures/runs/<run>/{traces,logs,metrics}/*.jsonl
  -> otlp_json_file receivers
  -> transform/strip_identity   (user.*, organization.id, host.name on resources, spans, span events, logs, datapoints)
  -> resource/replay            (adds kit.replay=true)
  -> debug  (+ otlphttp/logfire with the overlay)
```

Files: [collector/replay.yaml](collector/replay.yaml) (the base config, a dry run on its
own), [collector/replay-logfire.yaml](collector/replay-logfire.yaml) (the Logfire overlay)
and [scripts/replay.sh](scripts/replay.sh).

1. **Dry run.** Reads the files, strips identity attributes, and prints counts:

   ```bash
   scripts/replay.sh captures/runs/qwen-default-20261010-184954
   ```

   Checked against `summarise.sh` for one run per agent, the counts match exactly (Claude
   30 spans / 49 logs / 40 datapoints; Codex 4,710 / 48 / 222; Qwen 95 / 63 / 776). With
   `REPLAY_DEBUG_VERBOSITY=detailed`, none of the 119 `user.email` (etc.) keys in the Claude
   run survive.
2. **Token.** In Logfire: Project → Settings → Write tokens → New write token. Put it in
   `env/logfire.local.env`, which is gitignored:

   ```
   LOGFIRE_TOKEN=<write token>
   LOGFIRE_ENDPOINT=https://logfire-us.pydantic.dev
   ```

3. **Send.** Within 24 h of the capture. For this post: Claude and Codex with all
   signals, Qwen without logs (they carry the user's memory notes, see section 5):

   ```bash
   scripts/replay.sh captures/runs/claude-default-20261010-183721 logfire
   scripts/replay.sh captures/runs/codex-default-20261010-183807 logfire
   KIT_REPLAY_SKIP=logs scripts/replay.sh captures/runs/qwen-default-20261010-184954 logfire
   ```

4. **Look.** Use Live, then the LLMs and Agents views, filtering on `kit.replay`.
   Optionally verify with SQL through the query API (`POST /v2/query` with a read token).

**Sent** 2026-10-10 around 19:25 UTC, to the EU region (`logfire-eu.pydantic.dev`), about
1.5-2 h after capture. No export errors or partial-success warnings:

| Run | Spans | Log records | Datapoints |
|---|---|---|---|
| `claude-default-20261010-183721` | 30 | 49 | 40 |
| `codex-default-20261010-183807` | 4,710 | 48 | 222 |
| `qwen-default-20261010-184954` (`KIT_REPLAY_SKIP=logs`) | 95 | (not sent) | 776 |

The raw write token worked as the `Authorization` value, with no `Bearer` prefix.

**Verified with the SQL query API** (`POST https://logfire-eu.pydantic.dev/v2/query`,
`Authorization: Bearer <read token>`, body `{"sql": ..., "min_timestamp": ...}`):

- **Everything arrived:**
  - Claude: 30 spans, 49 logs, 40 datapoints.
  - Codex: 4,710 spans, 48 logs, 222 datapoints.
  - Qwen: 95 spans, 776 datapoints.

  Logfire also stores span events as separate `span_event` records (Claude 8, Codex 73).
  There were no `logfire ingest error` records and no `user.email` / `host.name` anywhere,
  and every record carries `kit.replay=true`.
- **Claude's cost metric made it through.** `claude_code.cost.usage` reads $0.00799,
  exactly the CLI's own `total_cost_usd` for that run. Logfire is the only one of the four
  backends that can hold it.
- **What the LLM views can use.** Spans with the fields Logfire's docs say the LLMs view
  reads (`gen_ai.system`/`provider.name`, `gen_ai.request.model`,
  `gen_ai.usage.input_tokens`), and the Agents view's `invoke_agent`:

  | | provider | model | `gen_ai.usage.*` | all three | `invoke_agent` | `execute_tool` |
  |---|---|---|---|---|---|---|
  | Claude | 8 | 8 | **0** | **0** | 0 | 0 |
  | Codex | **0** | **0** | 5 | **0** | 0 | 0 |
  | Qwen | 15 | 15 | 14 | **14** | 1 | 16 |

  These counts only cover the `gen_ai.*` fields on spans. The UI turned out to show more
  than they suggest; see below.

**What the Logfire UI showed** (Chrome, 2026-10-10; screenshots in `screenshots/logfire-*.jpg`):

- **Claude gets a Claude Code-specific "Session" panel.** Open a `claude_code.llm_request`
  span and the first tab is **Session**: a timeline built from Claude's *log* events. It
  shows:
  - the user prompt, as `<REDACTED>` with its length (369 chars);
  - each API request with duration and tokens (e.g. 1.63 s, ↑2 ↓252);
  - each tool decision ("accept", via config) and tool result (success, duration, bytes);
  - a summary ("Edit ×4, Bash ×3, 7/7 tools succeeded").

  Claude's log records carry trace context, so Live also nests `api_request`,
  `tool_decision`, `tool_result` and `assistant_response` under the spans they belong to.
  So **in Logfire Claude's per-call tokens are visible after all**, read from its logs
  rather than `gen_ai.usage.*` on spans. That's a vendor-specific integration: none of
  Logfire's docs pages mentions it. It also means a traces-only backend loses exactly the
  part Logfire uses.
- **Qwen gets the generic GenAI treatment.** Its `llm_request` rows carry token badges
  (e.g. "25.38K × 260"), and the interaction row rolls up the whole trace ("↑348.3K
  ↓7,233"). Spans open on **Model Run** / **Agent Run** tabs. Logfire stamps them at ingest
  with `logfire.model_call_candidate.v1` / `logfire.agent_run_candidate.v1 = true`. In
  default-privacy mode those tabs show the `gen_ai.*` attributes, but no conversation,
  because there are no messages to render.

  Qwen also reports a per-call **context-window breakdown** (`qwen-code.context.usage`:
  system prompt 4,775 tokens, built-in tools 8,342, memory files 4,260, messages 7,419, ...),
  which none of the other agents emits.
- **The Agents view stayed empty.** It said "No agents detected" over both 6 h and 24 h,
  even though Qwen's span has `gen_ai.operation.name=invoke_agent`, `gen_ai.agent.name`,
  `gen_ai.conversation.id` and Logfire's own `agent_run_candidate` flag. The docs don't
  explain why. One guess is that the semconv span name should be `invoke_agent {name}`,
  not `qwen-code.interaction`, but that's untested.
- **Codex gets nothing LLM-specific.**
  - Live is dominated by its `persist_rollout_items` / `realtime_conversation.running_state`
    spans.
  - Its log records are labelled by Rust source location (`event otel\src\tool_result.rs:54`,
    `event otel\src\events\session_telemetry.rs:1132`). Codex puts the source location in
    the OTLP `eventName` field, and its documented `codex.*` name in an `event.name`
    attribute (11 of 48 records, from auth storage, have no `codex.*` name at all).
    Logfire displays `eventName`.
  - The per-call LLM data is in those logs: the `response.completed` events carry `model`,
    input/cached/output token counts and `ttft_ms`. They open only on the generic
    Details tab.

The query used for the table:

```sql
SELECT service_name,
  count(*) FILTER (WHERE attributes->>'gen_ai.system' IS NOT NULL
                      OR attributes->>'gen_ai.provider.name' IS NOT NULL) AS has_provider,
  count(*) FILTER (WHERE attributes->>'gen_ai.request.model' IS NOT NULL) AS has_model,
  count(*) FILTER (WHERE attributes->>'gen_ai.usage.input_tokens' IS NOT NULL) AS has_usage,
  count(*) FILTER (WHERE attributes->>'gen_ai.operation.name' = 'invoke_agent') AS agent_spans
FROM records WHERE kind = 'span' GROUP BY 1
```

Screenshots (`screenshots/`, 1446×840, taken in Chrome). They show the Logfire org and
project name, so check them before publishing.

| File | Shows |
|---|---|
| `logfire-01-live-codex-noise` | Live view flooded by Codex's internal spans |
| `logfire-02-agents-none-detected` | Agents view empty despite Qwen's `invoke_agent` span |
| `logfire-03-qwen-llm-request-model-run` | Qwen LLM span: token badges, `gen_ai.*`, context breakdown |
| `logfire-04-qwen-agent-run-tab` | Qwen's `invoke_agent` attributes on the Agent Run tab |
| `logfire-05-claude-trace-with-nested-logs` | Claude's logs nested inside its trace; no token badges |
| `logfire-06-claude-session-panel` | Claude Code Session panel: prompt, API requests with tokens, tool decisions/results |
| `logfire-07-codex-logs-as-source-paths` | Codex log records labelled by Rust source path |
| `logfire-08-codex-response-completed-event` | Codex per-call model/tokens/ttft, only in a generic log record |
| `jaeger-01-qwen-waterfall-red-hooks` | Qwen waterfall: every hook span flagged as an error |
| `jaeger-02-qwen-genai-tab` | Jaeger GenAI tab: operation, provider, model, tokens |
| `jaeger-03-claude-waterfall` | Claude's clean waterfall |
| `jaeger-04-claude-genai-tab-no-tokens` | Jaeger GenAI tab for Claude: provider and model only |
| `jaeger-05-codex-turn-start-trace` | Codex `turn/start` trace: 3,575 spans, 16 levels deep |
| `jaeger-06-codex-tokens-on-handle-responses` | Codex tokens on one 39 ms `handle_responses` among dozens of 4 µs ones |

Gotchas found while building this:

- **The collector's own log sampling hides data.** Counting the debug exporter's log lines
  showed only 10 of 11 batches, because the collector samples repeated log messages (the
  first 10, then 1 in 100). `replay.yaml` turns sampling off. The same applies to anyone
  "verifying" a pipeline by reading the debug exporter.
- **`otlpjsonfile` is deprecated** in 0.162; the new name is `otlp_json_file`.
- **The receiver tails files forever**, so the script stops it after `KIT_REPLAY_WAIT`
  seconds (default 15).

### Sources

- LangSmith: docs.langchain.com/langsmith/ `trace-with-opentelemetry`, `cloud`,
  `usage-and-billing`, `trace-claude-code`, `trace-with-codex`, `trace-with-vscode-copilot`,
  `self-hosted`; langchain.com/pricing.
- Langfuse: langfuse.com/integrations/native/opentelemetry, /faq/all/api-limits,
  /integrations/developer-tools/claude-code, /integrations/developer-tools/codex,
  /pricing, /self-hosting.
  Code: github.com/langfuse/langfuse `web/src/pages/api/public/otel/v1/{traces,metrics}`,
  `packages/shared/src/server/otel/{OtelIngestionProcessor,ObservationTypeMapper}.ts`.
- Braintrust: braintrust.dev/docs `integrations/sdk-integrations/opentelemetry/send-traces-and-logs`,
  `.../opentelemetry/attributes`, `integrations/developer-tools/{claude-code,codex}`,
  `kb/otlp-traces-endpoint-payload-limits`, `plans-and-limits`, `admin/self-hosting`.
- Logfire: pydantic.dev/docs/logfire/ `guides/alternative-clients`, `migrate/overview`,
  `reference/limits`, `observe/llms`, `observe/agents`, `observe/llm-panels`,
  `manage/query-api`, `integrations/codex`, `manage/logfire-costs`, `get-started/faq`.

## 8. The wider landscape (checked 2026-10-10)

A table of CLI coding agents' OTel support was checked against official docs, repos,
issues and changelogs. For Claude Code, Codex and Qwen Code it was also checked against
our captures and the installed code. Corrections to the original table are in **bold**.

| Agent | Traces | Metrics | Logs | Protocol | Enable | Naming | Content by default |
|---|---|---|---|---|---|---|---|
| Claude Code | yes (beta) | yes | yes | gRPC, HTTP (protocol must be set); metrics also Prometheus/console | `CLAUDE_CODE_ENABLE_TELEMETRY=1` (+ `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` and `OTEL_TRACES_EXPORTER` for traces) | own `claude_code.*` + a few `gen_ai.*` | off (prompt `<REDACTED>`); **`user.email` on every record** (observed) |
| Copilot CLI | yes | yes | **span events only, no log signal** | **HTTP only (http/json default, http/protobuf), plus file** | `COPILOT_OTEL_ENABLED=true`, `OTEL_EXPORTER_OTLP_ENDPOINT` or `COPILOT_OTEL_FILE_EXPORTER_PATH` | GenAI conventions (`invoke_agent` → `chat` / `execute_tool`) + `github.copilot.*` | off (`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT`); pseudonymous `enduser.pseudo.id` |
| Gemini CLI | yes | yes | yes | gRPC (default), HTTP, file; also direct to GCP | `GEMINI_TELEMETRY_ENABLED` (**`..._TRACES_ENABLED` adds full prompts/tool output to spans, it doesn't switch traces on**) | **mostly `gemini_cli.*`; `gen_ai.*` on spans and a few items** | **prompts on** (`logPrompts`); **`user.email` when signed in**. Consumer users moved to Antigravity CLI in June 2026 |
| Qwen Code | yes | yes | yes | gRPC (default, confirmed in code), HTTP | `QWEN_TELEMETRY_ENABLED` | GenAI conventions + `qwen-code.*` | **prompts on in logs** (`logPrompts ?? true` in code), off on spans. Based on Gemini CLI v0.8.2; telemetry module derived from it |
| Codex CLI | yes, **opt-in via `trace_exporter`; undocumented span names, thousands of internal spans observed** | yes (**default exporter is OpenAI's Statsig**) | yes | gRPC, HTTP (both exporters in the binary) | `[otel]` in `~/.codex/config.toml` or `-c otel.*` | `codex.*` events, internal Rust span names, `gen_ai.usage.*` tokens | prompt off; **tool arguments and output (file contents) on**, observed, not "may be" |
| OpenCode | experimental: AI SDK LLM spans need **both** `experimental.openTelemetry: true` **and** an endpoint; open bugs | no | **yes** (whenever the endpoint is set) | **HTTP/JSON only** (`_PROTOCOL` and `OTEL_SERVICE_NAME` ignored) | `OTEL_EXPORTER_OTLP_ENDPOINT` (+ the flag for LLM spans); undocumented | Vercel AI SDK (`ai.*` + `gen_ai.*`) | **prompts on once LLM spans are on** (AI SDK `recordInputs` default), undocumented |
| Cursor (incl. CLI) | no ("Cursor doesn't send traces") | server-side, Enterprise | server-side, Enterprise | OTLP/HTTP protobuf, pushed from Cursor's servers | admin: Team Settings → OpenTelemetry Export | `cursor.*` | **CLI usage is exported** (`cursor.surface=cli`); CLI prompt/response text is not |
| Factory Droid | partial (only with `OTEL_LOG_MESSAGE_CONTENT=true`) | yes | not mentioned | HTTP | `OTEL_TELEMETRY_ENDPOINT`; **`OTEL_TELEMETRY_FORMAT=genai` only switches naming** (default `droid.*`) | GenAI in `genai` mode | off; no token or cost metrics |
| Goose | yes | yes | yes | **http/protobuf only** (gRPC skipped) | `OTEL_EXPORTER_OTLP_ENDPOINT` | **GenAI conventions** | **off** (`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT`). Repo now `aaif-goose/goose` |
| Kilo CLI | HTTP request spans only (AI SDK telemetry explicitly disabled) | no | yes | HTTP | on by default when an endpoint is set | `opencode.*` (built on OpenCode) | no prompt-bearing spans; logs unconfirmed |
| OpenHands | yes via Laminar (**SDK confirmed, CLI unconfirmed**) | no | no | gRPC, HTTP | `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | custom (`conversation`, `agent.step`, `llm.completion`, `tool.execute`) | tool input/output captured |
| Cline | no per docs (undocumented `CLINE_OTEL_TRACES_EXPORTER` in source) | yes | yes | gRPC, HTTP | `CLINE_OTEL_TELEMETRY_ENABLED` | custom (`task.*`, `hooks.*`) | metadata only (e.g. `prompt_length`); docs target the VS Code extension, CLI unconfirmed |
| Continue CLI | no | yes | no (literal `TODO`) | OTLP/HTTP, console | **an OTLP endpoint or `OTEL_METRICS_EXPORTER`** (`CONTINUE_METRICS_ENABLED=0` disables; `=1` alone does nothing) | custom `continue_cli_*` (incl. tokens and cost) | none |
| Kiro CLI | no | daily aggregates, Enterprise, admin-configured | no | **OTLP/gRPC (default) or HTTP** | admin console | **`kiro.daily.*`** | none |

No native OTel: **Crush** (issue moved to a discussion, PR closed unmerged), **Amp** (third-party
`trace-amp` wrapper only), **Aider** (feature request open; the LiteLLM-proxy route is
unconfirmed), **Amazon Q CLI** (feature request open), **Auggie**, **Plandex**, and
**Warp** (only its self-hosted agent worker exports metrics).

**Popularity, for context.**

- **Surveys:**
  - Stack Overflow 2026 (n=12,255, used in the past year): Claude Code 65.5%, Copilot
    58.7%, Codex 29.5%, Cursor 25.5%, OpenCode 13.6%.
  - JetBrains 2026 (n>15,000, use at work): Claude Code 39%, Copilot 21%, Codex 16%,
    Cursor 12%, OpenCode 7%.
  - Qwen Code and Gemini CLI weren't answer options in either survey.
- **Alibaba has published no usage numbers for Qwen Code.**
- **npm downloads, week of 2–8 Oct:** Codex 21.4M, Claude Code 12.2M (it also has a native
  installer), OpenCode 3.0M, Copilot CLI 1.5M, Gemini CLI 385k, Qwen Code 80k.
- **GitHub stars:** OpenCode 213k, Claude Code 150k, Codex 129k, Gemini CLI 107k,
  Qwen Code 28k.

Sources:

- Copilot CLI: docs.github.com `copilot/reference/copilot-cli-reference/cli-command-reference#opentelemetry-monitoring`.
- Gemini CLI: github.com/google-gemini/gemini-cli `docs/cli/telemetry.md`; developers.googleblog.com "transitioning Gemini CLI to Antigravity CLI".
- Qwen Code: github.com/QwenLM/qwen-code README and `packages/core/src/telemetry/`.
- OpenCode: github.com/anomalyco/opencode v1.18.35 `packages/core/src/observability/otlp.ts`, issues #33101, #25839, #47195; ai-sdk.dev v6 telemetry.
- Cursor: cursor.com/docs/enterprise/opentelemetry-export (+ `/wire`).
- Factory: docs.factory.com/enterprise/telemetry-export.
- Goose: github.com/aaif-goose/goose `crates/goose/src/otel/otlp.rs`.
- Kilo: github.com/Kilo-Org/kilocode.
- OpenHands: docs.openhands.dev/sdk/guides/observability.
- Cline: docs.cline.bot/enterprise-solutions/monitoring/opentelemetry.
- Continue: github.com/continuedev/continue `extensions/cli/src/telemetry/telemetryService.ts`.
- Kiro: kiro.dev/docs/enterprise/monitor-and-track/user-activity/opentelemetry.
- Surveys: survey.stackoverflow.co/2026/ai; blog.jetbrains.com/research/2026/08/ai-coding-agent-adoption-2026.

## 9. Status of the GenAI semantic conventions (checked 2026-10-10)

- **Official, but experimental.**
  - The conventions are part of OpenTelemetry, owned by the "Semantic Conventions and
    Instrumentation: GenAI" SIG.
  - In 2026 they moved out of the core semconv repo into
    `open-telemetry/semantic-conventions-genai`; core v1.42.0 deprecated the `gen_ai.*`
    definitions it used to hold.
  - The new repo has no releases yet, and **every part is still "Development"**: spans
    (inference, `execute_tool`, `invoke_agent`), metrics, events, and the
    provider-specific pages (OpenAI, Anthropic, Bedrock, Azure).
- **Still changing.**
  - v1.37.0 (Aug 2025): `gen_ai.system` became `gen_ai.provider.name`, and per-message
    events gave way to `gen_ai.input.messages` / `gen_ai.output.messages` attributes.
  - v1.41.0 (Apr 2026): `invoke_agent` was split into client and internal spans.
  - Unreleased on `main`: `gen_ai.client.token.usage` is being replaced by per-direction
    usage metrics, and `cache_creation` is being renamed `cache_write`. Codex's
    `gen_ai.usage.cache_write.input_tokens` already uses the new name.
  - The `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` switch is fading:
    OTel's Python genai util now defaults to the latest names.
- **Who sits at the table.**
  - Maintainers come from Google and Microsoft.
  - Approvers (per the repo's CONTRIBUTING.md) come from Google, Microsoft, Splunk,
    Honeycomb, Alibaba and Pydantic.
  - Anthropic and OpenAI aren't listed (the CODEOWNERS team isn't publicly listable).
- **Producers that emit it natively (per their docs):** Microsoft Agent Framework,
  Semantic Kernel, Google ADK, Pydantic AI, AWS Strands and Vercel AI SDK v7. OTel's own
  instrumentations cover OpenAI, Anthropic, Bedrock, Google GenAI, LangChain and others.
  The OpenAI Agents SDK uses its own tracing model.
- **Backends that document support:** Datadog, Grafana Cloud, Honeycomb, New Relic,
  Dynatrace, Elastic, Splunk, Azure Monitor, Google Cloud Trace, AWS CloudWatch/AgentCore,
  Logfire, Langfuse, LangSmith and Braintrust. Arize Phoenix converts it into its own
  OpenInference format at ingest.
- **Competing dialects.**
  - OpenInference (Arize) stays separate.
  - OpenLLMetry (Traceloop) says its conventions "are now part of OpenTelemetry".
  - Vercel's `ai.*` is now labelled legacy.
  - OTel's collector has an alpha `genainormalizerprocessor` that translates OpenInference
    and OpenLLMetry into GenAI semconv.
- **Jaeger: docs and observation disagree.** The research found Jaeger's GenAI UI pull
  requests (#4362, #4179) still open. But the `jaegertracing/jaeger:2.22.0` image used
  here *does* ship a GenAI view and GenAI tab (`screenshots/jaeger-02`, `jaeger-04`,
  `jaeger-06`). Trust the screenshots; those PRs may be follow-ups.

Sources:

- github.com/open-telemetry/semantic-conventions-genai (`model/manifest.yaml`, `CONTRIBUTING.md`, `changelog.d/`).
- github.com/open-telemetry/semantic-conventions releases v1.37.0, v1.41.0 and v1.42.0.
- github.com/open-telemetry/community `workstreams.yml`.
- github.com/open-telemetry/opentelemetry-python-genai.
- opentelemetry.io/blog/2026/genai-observability.
- Each vendor's own observability docs.

## Open questions

- Clean-profile runs (no user plugins, MCP servers, hooks or memory) without losing the login.
- Whether Codex has a documented way to filter its internal spans (I haven't checked).
- A `qwen --no-prompts` round, for a like-for-like comparison against the others' defaults.
- A clean re-run of Claude's full-content round. Round 2 was contaminated like round 1,
  though the privacy fields it shows are structural.
