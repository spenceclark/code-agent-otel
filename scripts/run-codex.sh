#!/usr/bin/env bash
# Run Codex CLI headless (`codex exec`) on the sample repo with OTel export to the local collector.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<USAGE
Usage: scripts/run-codex.sh [--full-content] [--user-config] [--no-archive] [--keep-sample] [-- extra codex args]

  (default)       Codex's default privacy: otel.log_user_prompt = false.
  --full-content  otel.log_user_prompt = true.
  --user-config   Don't pass -c overrides; rely on the [otel] block you installed with
                  scripts/codex-config.sh install (in \$CODEX_HOME/config.toml).
  --no-archive    Leave captures in ./captures instead of moving them to captures/runs/<run id>/.
  --keep-sample   Don't reset work/sample before the run.
Extra args (e.g. --model gpt-6.1-sol) are passed to codex exec.

By default the [otel] settings are passed as one-off '-c' overrides, so your
~/.codex/config.toml is never touched. Codex ignores [otel] in project-level
.codex/config.toml, which is why there is no per-repo option.
USAGE
}

parse_common_flags "$@"
USER_CONFIG=0; AGENT_ARGS=()
for a in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do
  case "$a" in
    --user-config) USER_CONFIG=1 ;;
    --) ;;
    *) AGENT_ARGS+=("$a") ;;
  esac
done

require_cmd codex "install Codex CLI: https://developers.openai.com/codex"
RUN_ID="$(new_run_id codex)"
pre_run

HTTP="${KIT_OTLP_HTTP:-http://127.0.0.1:4318}"
log_prompt=false
if [[ "$MODE" == full-content ]]; then log_prompt=true; fi
OTEL_ARGS=()
if [[ "$USER_CONFIG" == 0 ]]; then
  # Same keys as env/codex-config.toml, as TOML values for `-c key=value`.
  OTEL_ARGS=(
    -c "otel.environment=\"${MODE}\""
    -c "otel.log_user_prompt=${log_prompt}"
    -c "otel.exporter={ otlp-http = { endpoint = \"${HTTP}/v1/logs\", protocol = \"binary\" } }"
    -c "otel.trace_exporter={ otlp-http = { endpoint = \"${HTTP}/v1/traces\", protocol = \"binary\" } }"
    -c "otel.metrics_exporter={ otlp-http = { endpoint = \"${HTTP}/v1/metrics\", protocol = \"binary\" } }"
  )
else
  log "--user-config: using the [otel] block from \${CODEX_HOME:-~/.codex}/config.toml as-is (mode flag ignored)"
fi
scrub_otel_env

PROMPT="$(shared_prompt)"
log "run $RUN_ID: codex exec (mode: $MODE) in work/sample"
set +e
(
  cd "$KIT_WORK_DIR"
  codex exec \
    --sandbox workspace-write \
    "${OTEL_ARGS[@]+"${OTEL_ARGS[@]}"}" \
    "${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}" \
    "$PROMPT"
) | tee "$KIT_CAPTURES/.last-agent-output"
status=${PIPESTATUS[0]}
set -e
post_run "$RUN_ID" "$status"
