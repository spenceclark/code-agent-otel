#!/usr/bin/env bash
# Replay an archived run through a one-shot collector, with identity attributes stripped.
#
#   scripts/replay.sh captures/runs/<run id>            # dry run: read, strip, count
#   scripts/replay.sh captures/runs/<run id> logfire    # + collector/replay-logfire.yaml and env/logfire.local.env
#   KIT_REPLAY_SKIP=logs scripts/replay.sh ...          # leave out whole signals (space-separated)
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker

run="${1:?usage: scripts/replay.sh <run dir> [vendor]}"; vendor="${2:-}"
[[ -d "$run" ]] || die "no such run: $run"
hostpath() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }   # docker on Git Bash wants Windows paths

args=(--config=/cfg/replay.yaml); docker_args=()
if [[ -n "$vendor" ]]; then
  [[ -f "$KIT_ROOT/collector/replay-$vendor.yaml" ]] || die "no collector/replay-$vendor.yaml"
  [[ -f "$KIT_ROOT/env/$vendor.local.env" ]] || die "create env/$vendor.local.env first (KEY=value lines, no quotes)"
  args+=("--config=/cfg/replay-$vendor.yaml")
  docker_args=(--env-file "$(hostpath "$KIT_ROOT/env")/$vendor.local.env")
fi

# e.g. KIT_REPLAY_SKIP=logs: an empty tmpfs hides that signal's folder from the receiver.
for s in ${KIT_REPLAY_SKIP:-}; do docker_args+=(--tmpfs "/replay/$s"); done

name="kit-replay-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
MSYS_NO_PATHCONV=1 docker run -d --name "$name" -e REPLAY_DEBUG_VERBOSITY "${docker_args[@]+"${docker_args[@]}"}" \
  -v "$(hostpath "$KIT_ROOT/collector"):/cfg:ro" -v "$(hostpath "$run"):/replay:ro" \
  otel/opentelemetry-collector-contrib:0.162.0 "${args[@]}" >/dev/null
# otlpjsonfile tails files forever; give it time to read them and export, then stop.
sleep "${KIT_REPLAY_WAIT:-15}"
out="$(docker logs "$name" 2>&1)"
printf '%s\n' "$out" | grep -E '\b(error|warn)\b|Error|[Pp]artial' | grep -v 'error_mode' | head -20 >&2 || true
printf '%s\n' "$out" | grep -oE '"(spans|log records|data points)": [0-9]+' \
  | awk -F'": ' '{gsub(/"/, "", $1); t[$1] += $2} END {for (k in t) printf "  %s: %d\n", k, t[k]}'
log "replayed ${run#"$KIT_ROOT"/}${vendor:+ to $vendor}"
