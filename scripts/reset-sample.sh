#!/usr/bin/env bash
# Recreate work/sample from the pristine sample-repo/ template, as a fresh git repo.
# (Codex refuses to run outside a git repo; a fresh repo also makes `git diff` show
# exactly what each agent changed.)
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

rm -rf "$KIT_WORK_DIR"
mkdir -p "$(dirname "$KIT_WORK_DIR")"
cp -R "$KIT_ROOT/sample-repo" "$KIT_WORK_DIR"
(
  cd "$KIT_WORK_DIR"
  git init -q -b main
  git add -A
  git -c user.name="coding-agent-otel kit" -c user.email="kit@localhost" \
      commit -q -m "pristine sample"
)
log "sample reset at ${KIT_WORK_DIR#"$KIT_ROOT"/}"
