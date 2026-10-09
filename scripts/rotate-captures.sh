#!/usr/bin/env bash
# Move the live captures into captures/runs/<label>/ so each run gets its own folder.
# Stops the collector first so the file exporters flush and close their files.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

label="${1:-manual-$(date +%Y%m%d-%H%M%S)}"
dest="$KIT_CAPTURES/runs/$label"
if [[ -e "$dest" ]]; then die "already exists: $dest"; fi

require_cmd docker
KIT_UID="$(id -u)"; KIT_GID="$(id -g)"
export KIT_UID KIT_GID
compose stop otel-collector >/dev/null
mkdir -p "$dest"
for d in traces metrics logs all; do
  if [[ -d "$KIT_CAPTURES/$d" ]]; then mv "$KIT_CAPTURES/$d" "$dest/$d"; fi
done
compose start otel-collector >/dev/null
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null "$KIT_HEALTH_URL" 2>/dev/null && break
  sleep 1
done
log "captures archived to ${dest#"$KIT_ROOT"/}"
