# coding-agent-otel

A local kit for one blog post: **"Same prompt, three agents: what Claude Code, Codex
and Qwen Code actually send over OTel"**.

It runs one OpenTelemetry Collector on your machine, points Claude Code, Codex CLI and
Qwen Code at it, gives all three the same small coding task, and keeps every raw OTLP
record so you can compare what each agent emits: signals, trace shape, attribute
names compared with the `gen_ai.*` conventions, numbers, and privacy defaults.

**Local only.** Every port is bound to `127.0.0.1`. The collector exports only to
files in `./captures`, a local Jaeger and a local Prometheus. Nothing is sent to a
SaaS. (The agents still talk to their own model APIs, of course.)

## What's in here

```
docker-compose.yml          collector (contrib 0.162.0) + Jaeger 2.22.0 + Prometheus v3.15.0
collector/config.yaml       OTLP in (4317 gRPC, 4318 HTTP) -> debug, per-agent JSONL files, Jaeger, Prometheus
collector/codex-slow-run.yaml  standalone: shareable Codex "why was this run slow?" export (4 events, allowlisted)
prometheus/prometheus.yml   scrapes the collector's :8889
env/
  claude.env                Claude Code, default privacy
  claude.full-content.env   + prompts, responses, tool details, tool content
  codex-config.toml         Codex [otel] block, default privacy (reference / optional install)
  codex-config.full-content.toml
  qwen.env                  Qwen Code, its defaults (prompts ARE logged)
  qwen.full-content.env     + sensitive GenAI span attributes
  qwen-settings.example.json equivalent .qwen/settings.json block
  dsh.env / dsh.full-content.env  DeepSeek Harness (extra, see below)
scripts/
  up.sh / down.sh           start / stop the stack
  run-claude.sh             claude -p      [--full-content [--raw-bodies]]
  run-codex.sh              codex exec     [--full-content] [--user-config]
  run-qwen.sh               qwen -p        [--full-content | --no-prompts]
  run-dsh.sh                dsh --profile headless  [--full-content]   (extra, see below)
  reset-sample.sh           recreate work/sample from sample-repo/ (fresh git repo)
  rotate-captures.sh        move live captures into captures/runs/<label>/
  summarise.sh              per-agent counts, names, attribute keys, token sums, canary hits
  lib/tree.jq               span tree as indented text, with durations
  lib/codex-slow.jq         timeline (model calls, TTFT, tokens, tools) from codex-slow-run.yaml output
  replay.sh                 replay an archived run through a one-shot collector, identity stripped
                            (dry run, or to a vendor via collector/replay-<vendor>.yaml)
  codex-config.sh           optional: install/uninstall the [otel] block in ~/.codex/config.toml (with backup)
sample-repo/                tiny Python project (one deliberately failing test)
PROMPT.md                   the exact shared prompt (scripts read it from here)
```

## Prerequisites

- Docker with the Compose plugin (`docker compose`)
- `bash`, `curl`, `jq`, `git`
- `python` with `pytest` importable (`python -m pip install pytest`); the prompt runs `python -m pytest`. Codex's
  `workspace-write` sandbox has no network, so it can't install pytest itself.
- The three CLIs, installed and logged in:
  - Claude Code (`claude`)
  - Codex CLI (`codex`)
  - Qwen Code (`qwen`)

**Windows:** run the scripts from a Git Bash terminal (the shell Claude Code already
uses). Don't type `bash scripts/...` in PowerShell: there `bash` is WSL, which can't see
your Windows `docker`, `claude` or `codex`. The repo's `.gitattributes` keeps the scripts
LF; with CRLF, bash fails and the env files load values with a trailing `\r`. If the
collector logs `permission denied` on `/captures`, an earlier plain `docker compose up`
created those folders as a different uid: delete `captures/{all,traces,metrics,logs}`
(not `captures/runs/`, which holds your archived runs) and run `scripts/up.sh` again.

## Quick start

```bash
scripts/up.sh                       # collector, Jaeger (http://127.0.0.1:16686), Prometheus (http://127.0.0.1:9090)

# Round 1: each agent's default privacy settings
scripts/run-claude.sh
scripts/run-codex.sh
scripts/run-qwen.sh

# Round 2: everything switched on
scripts/run-claude.sh --full-content          # add --raw-bodies for full API JSON
scripts/run-codex.sh  --full-content
scripts/run-qwen.sh   --full-content

# Optional: Qwen fully redacted, to compare like with like against the others' defaults
scripts/run-qwen.sh --no-prompts

ls captures/runs/
scripts/summarise.sh captures/runs/<run id>
scripts/summarise.sh captures/runs/<run id> --keys-only   # attribute inventory only

scripts/down.sh
```

Each run script:
1. checks the collector is healthy;
2. archives any stray data in `captures/` so runs never mix;
3. resets `work/sample` from `sample-repo/` as a fresh git repo;
4. loads only the kit's telemetry settings (it unsets any `OTEL_*` / `QWEN_TELEMETRY_*`
   variables inherited from your shell);
5. runs the agent headless with the prompt from `PROMPT.md`;
6. waits `KIT_FLUSH_WAIT` seconds (default 15) for batched exports to arrive, then moves
   the captures to `captures/runs/<agent>-<mode>-<timestamp>/`, along with the agent's
   stdout (`agent-output.txt`) and what it changed (`sample-diff.txt`).

Extra args after the flags go straight to the agent, e.g.
`scripts/run-claude.sh -- --model claude-sonnet-5`. Use the same model tier for all three
if you can.

Headless permissions used:
- Claude: `--allowedTools "Read,Edit,Write,Glob,Grep,Bash"`
- Codex: `--sandbox workspace-write`
- Qwen: `--approval-mode yolo`. This auto-approves everything with **no sandbox**, so it
  runs with your privileges inside `work/sample`.

## Where captures land

```
captures/
  traces/<service.name>.jsonl     live, one file per agent (collector file exporter, group_by service.name)
  metrics/<service.name>.jsonl
  logs/<service.name>.jsonl
  all/{traces,metrics,logs}.jsonl everything, ungrouped (safety net)
  runs/<run id>/...               archived copy of the above for each run + agent-output.txt + sample-diff.txt
```

Each line is one OTLP/JSON export request, exactly as the agent sent it after collector
batching. The file names are whatever `service.name` each agent reports. That's a
finding in itself, so the kit deliberately doesn't override it with `OTEL_SERVICE_NAME`.

Claude and Qwen runs also carry `kit.run.id` and `kit.mode` resource attributes (via
`OTEL_RESOURCE_ATTRIBUTES`). Codex reports the mode as the resource attribute `env` (from `otel.environment`) instead.
Jaeger keeps everything in memory across runs, so filter by those tags.

Also useful: `docker compose logs -f otel-collector` (debug exporter, `verbosity: detailed`).

## What to compare

1. **Signals.** Which of traces, metrics and logs each agent sends for one task, and how
   many of each. Codex's docs list only log events and metrics, but it also exports
   thousands of internal spans. Claude and Qwen nest spans under an interaction root.
2. **Trace shape.** The span tree in Jaeger, e.g. Claude
   `claude_code.interaction -> llm_request / tool -> tool.blocked_on_user / tool.execution`,
   Qwen `qwen-code.interaction -> llm_request / tool -> ...`. Screenshot side by side, or
   print one as text with `jq -nr -f scripts/lib/tree.jq <run>/traces/<service>.jsonl`.
3. **Attribute mapping.** `summarise.sh --keys-only` against the GenAI semantic
   conventions (`gen_ai.operation.name`, `gen_ai.usage.*`, `gen_ai.tool.*`, `invoke_agent`,
   `execute_tool`). Qwen is closest to the conventions. Claude uses its own names plus a
   few `gen_ai.*` (including the older `gen_ai.system`, not `gen_ai.provider.name`). Codex
   uses `codex.*` events.
4. **Numbers.** Tokens (input, output, cache), cost (Claude only), time to first token,
   retries/attempts, tool calls, wall-clock time. Check whether each agent's own figures
   agree across its spans, logs and metrics.
5. **Privacy.** What lands in your collector by default. `summarise.sh` reports, per
   signal, how many records contain:
   - `KIT-PROMPT-CANARY-7f3a` (only in the prompt): the agent exported your prompt text;
   - `FILE-CONTENT-CANARY-91c2` (only in `sample-repo/text_utils.py`): the agent exported
     file contents.

   Also look at resource attributes such as `user.email` and account IDs.
6. **Setup friction.** Count the env vars and config needed for each agent, and note the
   gotchas below.

## Gotchas

- **Claude Code has no default OTLP protocol.** `OTEL_EXPORTER_OTLP_PROTOCOL` must be set
  explicitly, or nothing is exported.
- **Claude traces are beta.** They need `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` *and*
  `OTEL_TRACES_EXPORTER`.
- **Claude ignores OTel exporter vars in a repo's `.claude/settings.json`**, so a repo
  can't turn telemetry on. Use the shell, `~/.claude/settings.json` or managed settings.
  Managed settings on your machine can also override or remove some developer-set
  variables.
- **Claude doesn't pass `OTEL_*` to the Bash tool's subprocesses.** With tracing on, it
  does set `TRACEPARENT` for them.
- **Claude only sends `traceparent` to Anthropic's API.** Behind a custom
  `ANTHROPIC_BASE_URL` proxy it doesn't, unless `CLAUDE_CODE_PROPAGATE_TRACEPARENT=1`.
  This matters for any wire-level proxy, e.g. Vessel.
- **Claude metrics are delta by default.** The kit sets cumulative for Prometheus.
- **Launching `claude -p` from inside a Claude Code session leaks the parent's env**
  (`CLAUDE_EFFORT`, `CLAUDE_CODE_*`, preview flags). Here that raised effort to `xhigh` and
  added a span-only Haiku `agent_classifier` call. When `CLAUDECODE=1`, `run-claude.sh` unsets
  `CLAUDECODE` and `CLAUDE_*` (except `CLAUDE_CONFIG_DIR`). The desktop app also sets `ANTHROPIC_BASE_URL`;
  unset it yourself if you don't use a gateway.
- **Codex `[otel]` only works in user config.** `otel` is ignored, with a warning, in
  project `.codex/config.toml`. The kit avoids touching `~/.codex/config.toml` by
  passing `-c otel.*=...` overrides per run. `scripts/codex-config.sh install` is there
  if you want it permanent; it backs up first and refuses to clobber an existing `[otel]`.
  `CODEX_HOME` also relocates the whole config dir, but then Codex won't find your
  existing login.
- **Codex `metrics_exporter` defaults to `statsig`, i.e. OpenAI, not your collector.** The
  kit sets it to `otlp-http`. Codex's separate anonymous analytics (`[analytics]`) is
  independent of OTel.
- **Codex otlp-http endpoints need the full signal path** (`/v1/logs`, `/v1/traces`,
  `/v1/metrics`).
- **Codex needs a git repo** (hence `reset-sample.sh` runs `git init`).
- **Codex on Windows: the `elevated` sandbox can fail** with `setup refresh had errors`, so
  every tool call is rejected and the run does nothing. The exit status is still 0, and it
  still exports thousands of spans. Check with
  `codex sandbox -- cmd //c echo ok`. Workaround without editing your config:
  `scripts/run-codex.sh -- -c 'windows.sandbox="unelevated"'`.
- **Qwen logs prompts by default** (`logPrompts` defaults to `true`): prompt text and API
  request/response text go into OTel *logs*. The kit's "default" Qwen run keeps that on
  purpose. `--no-prompts` turns it off.
- **Qwen's `includeSensitiveSpanAttributes`** (full-content mode) puts full conversation
  history, file contents and shell output on spans, up to 1 MiB per attribute.
- **Qwen doesn't send `traceparent` upstream** unless `outboundCorrelation.propagateTraceContext`
  is `true`. That's a settings.json key with no documented env var.
- **Qwen's `otlpProtocol` is `grpc` or `http`**, not the standard `http/protobuf` values.
- **`qwen --model <id>` for a model that isn't in your `modelProviders` silently changes
  endpoint.** It went to Qwen's default (`dashscope.aliyuncs.com`), with whatever key the
  `openai` auth type resolved to (probably `OPENAI_API_KEY`), not to the `baseUrl` in your settings, and failed with a 401. To use an OpenRouter model
  for one run:
  `OPENAI_API_KEY="$OPENROUTER_API_KEY" scripts/run-qwen.sh -- --auth-type openai --openai-base-url https://openrouter.ai/api/v1 --model <id>`.
  The HTTP client spans record the URL, so check `captures/runs/<run>/all/traces.jsonl`.
- **Docker Compose exports its own traces whenever `OTEL_EXPORTER_OTLP_ENDPOINT` is set.**
  A `docker compose` command run from a shell configured for an agent ends up in your
  captures as a `compose` service. The kit's `compose()` helper unsets `OTEL_*` first.
- **The collector's file `group_by` drops resources without a string `service.name`.**
  The `all/` files still have them.
- **Time zones.** OTLP timestamps are UTC nanoseconds.

## DeepSeek Harness (extra)

Not part of the three-agent post; notes in `FINDINGS-dsh.md`. Tested with dsh 0.1.2-rc.1 and
`@loongsuite/dsh-plugin` 0.1.3 (plugin supports dsh `>=0.1.0-rc.6 <0.2.0`, so not dsh 0.2.x).

One-time setup: add the plugin to a `headless` profile (this creates `~/.dsh/profiles/headless`;
other profiles are untouched). `dsh plugin` shells out to `pnpm`. Without one, on Windows, put a
`pnpm.cmd` containing `@corepack pnpm@10.28.2 %*` first on `PATH` and set
`COREPACK_ENABLE_DOWNLOAD_PROMPT=0` for that command.

```bash
dsh plugin --profile headless add @loongsuite/dsh-plugin@0.1.3
```

```bash
scripts/run-dsh.sh                  # plugin traces + metrics, no content
scripts/run-dsh.sh --full-content   # + span content, + DSH's built-in exporter in FULL mode (logs)
```

- **DSH has two OTel exporters.** The plugin (traces + metrics, OTLP/HTTP protobuf only, base URL
  in `OTEL_EXPORTER_OTLP_ENDPOINT`) and the built-in `dsh-session-telemetry-otel` in `dsh-base`
  (logs only, full URL in `DSH_TELEMETRY_OTLP_URL`). The built-in one is mounted by default in
  `FEEDBACK_ONLY` mode, aimed at `https://harness-telemetry.deepseeksvc.com/v1/logs`, and uploads
  when you record `/feedback`. The kit points it at the local collector in both modes.
- **Any value of `DSH_TELEMETRY_DISABLED`, even `0`, disables the built-in exporter.** The run
  script unsets it.
- **The model comes from your DSH settings** (`agent-default-model` in `~/.dsh/settings.yaml`);
  headless has no `--model` flag. It's in the LLM span name (`chat <model>`).
- **Headless approvals fail closed** (no answerer), but the default `workspace-write` mode let
  every tool this task needs run on Windows (`read`, `edit`, `glob`, `grep`, `pwsh`).

## Verification status

Checked on 2026-10-09 against the docs below, then run for real on 2026-10-10. The collector config was validated with
`otelcol-contrib validate` (0.162.0) and smoke-tested with synthetic OTLP, which produced
per-service files, the Prometheus endpoint and `summarise.sh` output. Both rounds (default
and full content) were then run on Windows 11 with Claude Code 2.1.296, codex-cli 0.162.1 and Qwen Code 0.25.0.

| Item | Status |
|---|---|
| Claude env var names and values | Verified (monitoring docs) |
| Codex `[otel]` keys: `environment`, `exporter`, `trace_exporter`, `metrics_exporter`, `log_user_prompt`, otlp-http `endpoint`/`protocol` | Verified (config reference) |
| Codex `metrics_exporter = { otlp-http = {...} }` shape | Verified from Codex's own test suite, not shown in user docs |
| Codex `-c otel.*` overrides take effect for `codex exec` | Verified on a real run (codex-cli 0.162.1): logs, traces and metrics all arrive |
| Codex span names / trace content | Observed, not documented: thousands of internal spans per run (`fs.get_metadata`, `handle_responses`, ...) across hundreds of traces |
| Codex per-run tag via `OTEL_RESOURCE_ATTRIBUTES` | Not documented, so not relied on (uses `otel.environment`) |
| Qwen env var names, defaults, `-p` / `--approval-mode yolo` / `--output-format json` | Verified (telemetry, settings and headless docs) |
| `claude -p`, `--allowedTools`, `--output-format json`; `codex exec --sandbox workspace-write` | Verified (headless / non-interactive docs) |
| Each agent's actual `service.name` | **TODO: observe.** It's in the capture file names |
| Image tags `otel/opentelemetry-collector-contrib:0.162.0`, `jaegertracing/jaeger:2.22.0`, `prom/prometheus:v3.15.0` | Exist on Docker Hub; `docker compose up` not run (no Docker on the build box) |

## Docs

- Claude Code monitoring: https://code.claude.com/docs/en/monitoring-usage
- Claude Code headless: https://code.claude.com/docs/en/headless
- Codex advanced config (OTel): https://developers.openai.com/codex/config-advanced
- Codex config reference: https://developers.openai.com/codex/config-reference
- Codex non-interactive: https://developers.openai.com/codex/noninteractive
- Qwen Code telemetry: https://qwenlm.github.io/qwen-code-docs/en/developers/development/telemetry/
- Qwen Code headless: https://qwenlm.github.io/qwen-code-docs/en/users/features/headless/
- Collector file exporter: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/fileexporter
- OTel GenAI semantic conventions: https://github.com/open-telemetry/semantic-conventions-genai
