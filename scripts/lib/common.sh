#!/usr/bin/env bash
# Shared helpers for the run scripts. Source, don't execute.
# shellcheck shell=bash

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KIT_ROOT
KIT_WORK_DIR="${KIT_ROOT}/work/sample"
KIT_CAPTURES="${KIT_ROOT}/captures"
KIT_HEALTH_URL="${KIT_HEALTH_URL:-http://127.0.0.1:13133/}"
# Seconds to wait after the agent exits so batched telemetry reaches the collector.
KIT_FLUSH_WAIT="${KIT_FLUSH_WAIT:-15}"

log() { printf '\033[1;34m[kit]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[kit] error:\033[0m %s\n' "$*" >&2; exit 1; }

compose() { (cd "$KIT_ROOT" && docker compose "$@"); }

# Load KEY=value lines from an env file into the environment (exported).
load_env() {
  local file="$1"
  [[ -f "$file" ]] || die "env file not found: $file"
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
  log "loaded $(realpath --relative-to="$KIT_ROOT" "$file" 2>/dev/null || echo "$file")"
}

# Print the shared prompt from PROMPT.md (between the prompt markers).
shared_prompt() {
  local p
  p="$(sed -n '/<!-- prompt:start -->/,/<!-- prompt:end -->/{//!p;}' "$KIT_ROOT/PROMPT.md")"
  [[ -n "$p" ]] || die "could not read the prompt from PROMPT.md"
  printf '%s' "$p"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH${2:+ ($2)}"; }

require_collector() {
  curl -fsS -o /dev/null "$KIT_HEALTH_URL" 2>/dev/null \
    || die "collector not healthy at $KIT_HEALTH_URL - run scripts/up.sh first"
}

check_pytest() {
  python3 -c 'import pytest' 2>/dev/null \
    || log "warning: pytest isn't importable by python3; agents may try to install it (Codex's sandbox has no network)"
}

captures_nonempty() {
  find "$KIT_CAPTURES" -maxdepth 2 -name '*.jsonl' -size +0 2>/dev/null | grep -q .
}

# Common flag parsing. Sets MODE (default|full-content), ARCHIVE (1|0), KEEP_SAMPLE (1|0).
# Unknown flags are left in EXTRA_ARGS for the caller.
parse_common_flags() {
  MODE=default; ARCHIVE=1; KEEP_SAMPLE=0; EXTRA_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full-content) MODE=full-content ;;
      --no-archive)   ARCHIVE=0 ;;
      --keep-sample)  KEEP_SAMPLE=1 ;;
      -h|--help)      usage; exit 0 ;;
      *)              EXTRA_ARGS+=("$1") ;;
    esac
    shift
  done
}

new_run_id() { printf '%s-%s-%s' "$1" "$MODE" "$(date +%Y%m%d-%H%M%S)"; }

# Unset every OTEL_* variable (plus inbound W3C trace context) inherited from your
# shell, so each run only sees the kit's settings.
scrub_otel_env() {
  local v
  while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^OTEL_' || true)
  unset TRACEPARENT TRACESTATE
}

# Prepare the sample repo, refuse to mix runs in the live captures.
pre_run() {
  mkdir -p "$KIT_CAPTURES"
  require_collector
  check_pytest
  if captures_nonempty; then
    if [[ "$ARCHIVE" == 1 ]]; then
      log "captures/ already has data; archiving it as 'stray-$(date +%Y%m%d-%H%M%S)' first"
      "$KIT_ROOT/scripts/rotate-captures.sh" "stray-$(date +%Y%m%d-%H%M%S)"
    else
      log "warning: captures/ already has data and --no-archive is set; this run will be mixed in"
    fi
  fi
  if [[ "$KEEP_SAMPLE" == 0 ]]; then
    "$KIT_ROOT/scripts/reset-sample.sh"
  fi
}

# Wait for flush, then archive the live captures into captures/runs/<run id>/.
post_run() {
  local run_id="$1" agent_exit="$2"
  log "agent exited with status $agent_exit; waiting ${KIT_FLUSH_WAIT}s for telemetry to flush"
  sleep "$KIT_FLUSH_WAIT"
  if [[ "$ARCHIVE" == 1 ]]; then
    "$KIT_ROOT/scripts/rotate-captures.sh" "$run_id"
    local dest="$KIT_CAPTURES/runs/$run_id"
    if [[ -f "$KIT_CAPTURES/.last-agent-output" ]]; then mv "$KIT_CAPTURES/.last-agent-output" "$dest/agent-output.txt"; fi
    (cd "$KIT_WORK_DIR" && git status --short && git diff) > "$dest/sample-diff.txt" 2>/dev/null || true
    log "done. Summarise with: scripts/summarise.sh captures/runs/$run_id"
  else
    log "done. Summarise with: scripts/summarise.sh"
  fi
}
