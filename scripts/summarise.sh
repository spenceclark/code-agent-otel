#!/usr/bin/env bash
# Summarise OTLP captures per agent (service.name): signal counts, span/event/metric
# names, attribute keys, token totals, and privacy canary hits.
#
#   scripts/summarise.sh                          # live ./captures
#   scripts/summarise.sh captures/runs/<run id>   # one archived run
#   scripts/summarise.sh <dir> --keys-only        # just the attribute-key inventory
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd jq

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

DIR="$KIT_CAPTURES"; KEYS_ONLY=0
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --keys-only) KEYS_ONLY=1 ;;
    *) DIR="$a" ;;
  esac
done
[[ -d "$DIR" ]] || die "no such directory: $DIR"

JQ=(jq -nr -L "$KIT_ROOT/scripts/lib")
PROMPT_CANARY="KIT-PROMPT-CANARY-7f3a"
FILE_CANARY="FILE-CONTENT-CANARY-91c2"

hr() { printf '%s\n' "------------------------------------------------------------------------"; }

shopt -s nullglob
services=()
for f in "$DIR"/traces/*.jsonl "$DIR"/metrics/*.jsonl "$DIR"/logs/*.jsonl; do
  services+=("$(basename "$f" .jsonl)")
done
if [[ ${#services[@]} -eq 0 ]]; then
  log "no per-agent files under $DIR/{traces,metrics,logs}/ yet"
  exit 0
fi
uniq_services=()
while IFS= read -r s; do uniq_services+=("$s"); done < <(printf '%s\n' "${services[@]}" | sort -u)
services=("${uniq_services[@]}")

printf 'Captures: %s\n' "$DIR"
printf '%-28s %8s %10s %10s %10s\n' "service.name" "spans" "metrics" "datapts" "logrecs"
for s in "${services[@]}"; do
  t="$DIR/traces/$s.jsonl"; m="$DIR/metrics/$s.jsonl"; l="$DIR/logs/$s.jsonl"
  ns=0; nm=0; nd=0; nl=0
  if [[ -s "$t" ]]; then ns=$("${JQ[@]}" 'include "otlp"; [inputs | spans] | length' "$t"); fi
  if [[ -s "$m" ]]; then
    nm=$("${JQ[@]}" 'include "otlp"; [inputs | metrics | .name] | unique | length' "$m")
    nd=$("${JQ[@]}" 'include "otlp"; [inputs | metrics | datapoints[]] | length' "$m")
  fi
  if [[ -s "$l" ]]; then nl=$("${JQ[@]}" 'include "otlp"; [inputs | logrecs] | length' "$l"); fi
  printf '%-28s %8s %10s %10s %10s\n' "$s" "$ns" "$nm" "$nd" "$nl"
done

for s in "${services[@]}"; do
  t="$DIR/traces/$s.jsonl"; m="$DIR/metrics/$s.jsonl"; l="$DIR/logs/$s.jsonl"
  echo; hr; printf '%s\n' "$s"; hr

  # Resource attributes (first seen), useful for the privacy section (user.email etc.)
  for f in "$t" "$m" "$l"; do
    if [[ -s "$f" ]]; then
      echo "Resource attributes:"
      "${JQ[@]}" 'include "otlp"; [inputs | resources | .attributes | attrmap] | add // {} | to_entries[] | "  \(.key) = \(.value|tostring|.[0:100])"' "$f"
      break
    fi
  done

  if [[ -s "$t" ]]; then
    if [[ "$KEYS_ONLY" == 0 ]]; then
      echo "Span names:"
      "${JQ[@]}" 'include "otlp"; [inputs | spans | .name] | countlines' "$t"
      echo "Span events:"
      "${JQ[@]}" 'include "otlp"; [inputs | spans | .events[]? | .name] | if length == 0 then "  (none)" else countlines end' "$t"
      echo "Traces: $("${JQ[@]}" 'include "otlp"; [inputs | spans | .traceId] | unique | length' "$t")"
    fi
    echo "Span attribute keys (by span name):"
    "${JQ[@]}" 'include "otlp"; [inputs | spans | {name, keys: (.attributes | attrmap | keys)}]
      | group_by(.name) | .[] | "  \(.[0].name): \([.[].keys[]] | unique | join(", "))"' "$t"
    if [[ "$KEYS_ONLY" == 0 ]]; then
      echo "Token-ish numeric span attributes (summed):"
      "${JQ[@]}" 'include "otlp"; [inputs | spans | .attributes | attrmap] | tokensums' "$t"
    fi
  fi

  if [[ -s "$m" ]]; then
    echo "Metrics (type, datapoints):"
    "${JQ[@]}" 'include "otlp"; [inputs | metrics | {name, t: metrictype, n: (datapoints | length), unit: (.unit // "")}]
      | group_by(.name) | .[] | "  \(.[0].name) [\(.[0].t)\(if .[0].unit != "" then ", " + .[0].unit else "" end)] x\(map(.n) | add)"' "$m"
    echo "Metric datapoint attribute keys:"
    "${JQ[@]}" 'include "otlp"; [inputs | metrics | datapoints[] | .attributes | attrmap | keys[]] | unique | "  " + join(", ")' "$m"
  fi

  if [[ -s "$l" ]]; then
    if [[ "$KEYS_ONLY" == 0 ]]; then
      echo "Log events:"
      "${JQ[@]}" 'include "otlp"; [inputs | logrecs | eventname] | countlines' "$l"
    fi
    echo "Log attribute keys (by event):"
    "${JQ[@]}" 'include "otlp"; [inputs | logrecs | {e: eventname, keys: (.attributes | attrmap | keys)}]
      | group_by(.e) | .[] | "  \(.[0].e): \([.[].keys[]] | unique | join(", "))"' "$l"
    if [[ "$KEYS_ONLY" == 0 ]]; then
      echo "Token-ish numeric log attributes (summed):"
      "${JQ[@]}" 'include "otlp"; [inputs | logrecs | .attributes | attrmap] | tokensums' "$l"
    fi
  fi

  if [[ "$KEYS_ONLY" == 0 ]]; then
    echo "gen_ai.* keys seen anywhere:"
    genai=""
    for f in "$t" "$m" "$l"; do
      if [[ -s "$f" ]]; then genai+="$(grep -o '"key":"gen_ai\.[^"]*"' "$f" | sed 's/"key":"//; s/"$//' || true)"$'\n'; fi
    done
    genai="$(printf '%s' "$genai" | sed '/^$/d' | sort -u)"
    if [[ -n "$genai" ]]; then printf '%s\n' "$genai" | sed 's/^/  /'; else echo "  (none)"; fi
    echo "Privacy canaries (records containing the string):"
    # shellcheck disable=SC2016  # $c is a jq variable
    for pair in "prompt:$PROMPT_CANARY" "file-content:$FILE_CANARY"; do
      label="${pair%%:*}"; canary="${pair#*:}"
      cs=0; cl=0
      if [[ -s "$t" ]]; then cs=$("${JQ[@]}" --arg c "$canary" 'include "otlp"; [inputs | spans | select(tojson | contains($c))] | length' "$t"); fi
      if [[ -s "$l" ]]; then cl=$("${JQ[@]}" --arg c "$canary" 'include "otlp"; [inputs | logrecs | select(tojson | contains($c))] | length' "$l"); fi
      printf '  %-13s spans=%s logs=%s\n' "$label" "$cs" "$cl"
    done
  fi
done

echo
echo "Notes:"
echo "  - Token sums add every numeric attribute whose key contains 'token', per signal."
echo "    Agents report the same usage in several places (span attrs AND log events), so"
echo "    compare within a signal, not across. Metric totals are not summed (temporality)."
echo "  - Files are grouped by resource service.name; anything without one is only in all/."
