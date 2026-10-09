#!/usr/bin/env bash
# Stop the stack. Captures on disk are kept; Jaeger/Prometheus data (in-container) is not.
# Pass --volumes to also remove anonymous volumes.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker
compose down "$@"
log "stack stopped; captures kept in ./captures"
