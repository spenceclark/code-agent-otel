#!/usr/bin/env bash
# Run Claude Code headless (`claude -p`) on the sample repo with OTel export to the local collector.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<USAGE
Usage: scripts/run-claude.sh [--full-content [--raw-bodies]] [--no-archive] [--keep-sample] [-- extra claude args]

  (default)       Claude Code's default privacy: no prompts, responses, tool details or content.
  --full-content  Also load env/claude.full-content.env (prompts, responses, tool details + content).
  --raw-bodies    With --full-content, also set OTEL_LOG_RAW_API_BODIES=1 (full API request/response JSON).
  --no-archive    Leave captures in ./captures instead of moving them to captures/runs/<run id>/.
  --keep-sample   Don't reset work/sample before the run.
Extra args (e.g. --model claude-sonnet-5) are passed to claude.
USAGE
}

parse_common_flags "$@"
RAW_BODIES=0; AGENT_ARGS=()
for a in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do
  case "$a" in
    --raw-bodies) RAW_BODIES=1 ;;
    --) ;;
    *) AGENT_ARGS+=("$a") ;;
  esac
done

require_cmd claude "install Claude Code: https://code.claude.com/docs"
RUN_ID="$(new_run_id claude)"
pre_run

# Start from a clean slate: don't let telemetry vars from your shell leak into the comparison.
scrub_otel_env
# Started from inside a Claude Code session? Drop the parent's vars (effort, entrypoint, child-session flags).
if [[ "${CLAUDECODE:-}" == 1 ]]; then
  while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(CLAUDECODE$|CLAUDE_)' | grep -v '^CLAUDE_CONFIG_DIR$' || true)
  log "started inside a Claude Code session: unset its CLAUDECODE / CLAUDE_* vars"
fi
load_env "$KIT_ROOT/env/claude.env"
if [[ "$MODE" == full-content ]]; then
  load_env "$KIT_ROOT/env/claude.full-content.env"
  if [[ "$RAW_BODIES" == 1 ]]; then export OTEL_LOG_RAW_API_BODIES=1; log "OTEL_LOG_RAW_API_BODIES=1"; fi
fi
export OTEL_RESOURCE_ATTRIBUTES="kit.run.id=${RUN_ID},kit.mode=${MODE}"

PROMPT="$(shared_prompt)"
log "run $RUN_ID: claude -p (mode: $MODE) in work/sample"
set +e
(
  cd "$KIT_WORK_DIR"
  claude -p "$PROMPT" \
    --allowedTools "Read,Edit,Write,Glob,Grep,Bash" \
    --output-format json \
    "${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}"
) | tee "$KIT_CAPTURES/.last-agent-output"
status=${PIPESTATUS[0]}
set -e
post_run "$RUN_ID" "$status"
