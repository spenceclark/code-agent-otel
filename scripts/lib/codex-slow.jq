# Timeline of a Codex run from collector/codex-slow-run.yaml's output: model calls with
# duration, TTFT and tokens, plus tool calls. A call's duration is the gap between its
# codex.websocket_request and the next response.completed (Codex doesn't record it).
#   jq -rs -f scripts/lib/codex-slow.jq codex-slow-run.jsonl
[ .[] | .resourceLogs[]? | .scopeLogs[]? | .logRecords[]?
  | ((.attributes // []) | map({key, value: (.value | to_entries[0].value)}) | from_entries)
    + {t: ((.timeUnixNano // .observedTimeUnixNano) | tonumber / 1e6)} ]
| sort_by(.t) | .[0].t as $t0
| reduce .[] as $r ({out: [], start: null};
    if $r."event.name" == "codex.websocket_request" then .start = $r.t
    elif $r."event.name" == "codex.sse_event" then
      .out += ["\(($r.t - $t0) / 1000 | floor)s  model call  \(if .start then "\(($r.t - .start) / 1000 * 10 | round / 10)s" else "?" end)  ttft \($r.ttft_ms // "-")ms  in \($r.input_token_count) (cached \($r.cached_token_count))  out \($r.output_token_count) (reasoning \($r.reasoning_token_count))"] | .start = null
    elif $r."event.name" == "codex.tool_result" then
      .out += ["\(($r.t - $t0) / 1000 | floor)s  tool \($r.tool_name)  \($r.duration_ms)ms  success=\($r.success)"]
    elif $r."event.name" == "codex.turn_ttft" then
      .out += ["\(($r.t - $t0) / 1000 | floor)s  turn ttft \($r.duration_ms)ms"]
    else . end)
| .out[]
