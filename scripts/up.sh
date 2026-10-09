#!/usr/bin/env bash
# Start the local collector + Jaeger + Prometheus and wait for the collector to be healthy.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_cmd docker
mkdir -p "$KIT_CAPTURES"
KIT_UID="$(id -u)"; KIT_GID="$(id -g)"
export KIT_UID KIT_GID
compose up -d

log "waiting for collector health at $KIT_HEALTH_URL"
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "$KIT_HEALTH_URL" 2>/dev/null; then
    log "collector is up"
    cat >&2 <<MSG
  OTLP gRPC   127.0.0.1:4317   (Claude Code, Qwen Code)
  OTLP HTTP   127.0.0.1:4318   (Codex CLI)
  Jaeger UI   http://127.0.0.1:16686
  Prometheus  http://127.0.0.1:9090
  Raw OTLP    ./captures/{traces,metrics,logs}/<service.name>.jsonl
  Debug log   docker compose logs -f otel-collector
MSG
    exit 0
  fi
  sleep 1
done
compose logs --tail=50 otel-collector >&2 || true
die "collector did not become healthy within 30s"
