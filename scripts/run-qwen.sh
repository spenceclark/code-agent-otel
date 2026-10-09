#!/usr/bin/env bash
# Run Qwen Code headless (`qwen -p`) on the sample repo with OTel export to the local collector.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<USAGE
Usage: scripts/run-qwen.sh [--full-content | --no-prompts] [--no-archive] [--keep-sample] [-- extra qwen args]

  (default)       Qwen Code's defaults: logPrompts=true (prompts + API text in logs), no sensitive span attrs.
  --full-content  Also includeSensitiveSpanAttributes=true (GenAI messages/tool args/results on spans).
  --no-prompts    logPrompts=false, i.e. the most redacted Qwen run (comparable to the others' defaults).
  --no-archive    Leave captures in ./captures instead of moving them to captures/runs/<run id>/.
  --keep-sample   Don't reset work/sample before the run.
Extra args (e.g. --model qwen3-coder-plus) are passed to qwen.

Tools are auto-approved with --approval-mode yolo, which does NOT sandbox; it runs
with your privileges inside work/sample.
USAGE
}

parse_common_flags "$@"
NO_PROMPTS=0; AGENT_ARGS=()
for a in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do
  case "$a" in
    --no-prompts) NO_PROMPTS=1 ;;
    --) ;;
    *) AGENT_ARGS+=("$a") ;;
  esac
done
if [[ "$NO_PROMPTS" == 1 && "$MODE" == full-content ]]; then die "--no-prompts and --full-content are mutually exclusive"; fi
if [[ "$NO_PROMPTS" == 1 ]]; then MODE=no-prompts; fi

require_cmd qwen "install Qwen Code: https://qwenlm.github.io/qwen-code-docs/"
RUN_ID="$(new_run_id qwen)"
pre_run

# Clean slate, then the kit's settings (env vars override .qwen/settings.json).
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^QWEN_TELEMETRY_' || true)
scrub_otel_env
load_env "$KIT_ROOT/env/qwen.env"
case "$MODE" in
  full-content) load_env "$KIT_ROOT/env/qwen.full-content.env" ;;
  no-prompts)   export QWEN_TELEMETRY_LOG_PROMPTS=false; log "QWEN_TELEMETRY_LOG_PROMPTS=false" ;;
esac
export OTEL_RESOURCE_ATTRIBUTES="kit.run.id=${RUN_ID},kit.mode=${MODE}"
export QWEN_CODE_SUPPRESS_YOLO_WARNING="${QWEN_CODE_SUPPRESS_YOLO_WARNING:-1}"

PROMPT="$(shared_prompt)"
log "run $RUN_ID: qwen -p (mode: $MODE) in work/sample"
set +e
(
  cd "$KIT_WORK_DIR"
  qwen -p "$PROMPT" \
    --approval-mode yolo \
    --output-format json \
    "${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}"
) | tee "$KIT_CAPTURES/.last-agent-output"
status=${PIPESTATUS[0]}
set -e
post_run "$RUN_ID" "$status"
