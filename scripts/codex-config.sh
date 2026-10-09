#!/usr/bin/env bash
# Optional: install/remove the kit's [otel] block in your Codex USER config, with a backup.
# Only needed for interactive `codex` sessions or `run-codex.sh --user-config`;
# run-codex.sh normally passes the same settings as -c overrides instead.
#
#   scripts/codex-config.sh install [--full-content]
#   scripts/codex-config.sh uninstall
#   scripts/codex-config.sh show
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CFG="$CODEX_DIR/config.toml"
BEGIN="# >>> coding-agent-otel kit >>>"
END="# <<< coding-agent-otel kit <<<"

cmd="${1:-}"; shift || true
case "$cmd" in
  install)
    snippet="$KIT_ROOT/env/codex-config.toml"
    if [[ "${1:-}" == --full-content ]]; then snippet="$KIT_ROOT/env/codex-config.full-content.toml"; fi
    mkdir -p "$CODEX_DIR"; touch "$CFG"
    if grep -qF "$BEGIN" "$CFG"; then die "kit block already installed in $CFG (run uninstall first)"; fi
    if grep -Eq '^[[:space:]]*\[otel(\.|\])' "$CFG" || grep -Eq '^[[:space:]]*otel[[:space:]]*[.=]' "$CFG"; then
      die "$CFG already has its own otel settings; merge env/codex-config.toml by hand"
    fi
    backup="$CFG.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$CFG" "$backup"
    # Append at the end: [otel] is a table, so it must come after any top-level keys.
    { printf '\n%s\n' "$BEGIN"; grep -v '^#' "$snippet" | sed '/^$/d'; printf '%s\n' "$END"; } >> "$CFG"
    log "installed $(basename "$snippet") into $CFG (backup: $backup)"
    ;;
  uninstall)
    [[ -f "$CFG" ]] || die "no $CFG"
    grep -qF "$BEGIN" "$CFG" || die "kit block not found in $CFG"
    backup="$CFG.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$CFG" "$backup"
    awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$backup" > "$CFG"
    log "removed kit block from $CFG (backup: $backup)"
    ;;
  show)
    if [[ -f "$CFG" ]]; then sed -n "/$BEGIN/,/$END/p" "$CFG"; fi
    ;;
  *) usage; exit 1 ;;
esac
