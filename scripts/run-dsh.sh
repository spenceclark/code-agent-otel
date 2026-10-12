#!/usr/bin/env bash
# Run DeepSeek Harness headless (`dsh --profile headless`) on the sample repo with OTel export to the local collector.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<USAGE
Usage: scripts/run-dsh.sh [--full-content] [--no-archive] [--keep-sample]

  (default)       Plugin traces + metrics without content; built-in log exporter in its FEEDBACK_ONLY default.
  --full-content  Plugin content capture (SPAN_ONLY) + built-in exporter in FULL mode (raw session log as OTel logs).
  --no-archive    Leave captures in ./captures instead of moving them to captures/runs/<run id>/.
  --keep-sample   Don't reset work/sample before the run.

Needs @loongsuite/dsh-plugin in the headless profile (README: "DeepSeek Harness (extra)").
The model is whatever your DSH settings select (agent-default-model in ~/.dsh/settings.yaml).
USAGE
}

parse_common_flags "$@"
[[ ${#EXTRA_ARGS[@]} -eq 0 ]] || die "unknown args: ${EXTRA_ARGS[*]} (dsh headless takes only the task)"

require_cmd dsh "npm i -g @deepseek-ai/dsh"
RUN_ID="$(new_run_id dsh)"
pre_run

# Clean slate, then the kit's settings. Any value of DSH_TELEMETRY_DISABLED (even 0) disables the built-in exporter.
unset DSH_TELEMETRY_MODE DSH_TELEMETRY_OTLP_URL DSH_TELEMETRY_DISABLED DSH_TOOLS_MODE
scrub_otel_env
load_env "$KIT_ROOT/env/dsh.env"
if [[ "$MODE" == full-content ]]; then load_env "$KIT_ROOT/env/dsh.full-content.env"; fi
export OTEL_RESOURCE_ATTRIBUTES="kit.run.id=${RUN_ID},kit.mode=${MODE}"

PROMPT="$(shared_prompt)"
log "run $RUN_ID: dsh --profile headless (mode: $MODE) in work/sample"
set +e
# stderr too: headless prints the model's reasoning there and only the final answer on stdout.
(
  cd "$KIT_WORK_DIR"
  dsh --profile headless "$PROMPT"
) 2>&1 | tee "$KIT_CAPTURES/.last-agent-output"
status=${PIPESTATUS[0]}
set -e
post_run "$RUN_ID" "$status"
