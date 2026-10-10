# Print span trees from a traces JSONL file, one line per span, indented by depth.
#   jq -nr -f scripts/lib/tree.jq captures/runs/<run id>/traces/<service>.jsonl
[inputs | .resourceSpans[]?.scopeSpans[]?.spans[]?] as $s
| ($s | map({key: .spanId, value: .}) | from_entries) as $by
| ($s | group_by(.parentSpanId // "") | map({key: (.[0].parentSpanId // ""), value: (sort_by(.startTimeUnixNano) | map(.spanId))}) | from_entries) as $kids
| def walk($id; $d):
    $by[$id] as $sp
    | ("  " * $d) + $sp.name + "  (" + (((($sp.endTimeUnixNano|tonumber) - ($sp.startTimeUnixNano|tonumber)) / 1e6 | floor | tostring)) + " ms)",
      ($kids[$id] // [] | .[] | walk(.; $d + 1));
  $s | map(select((.parentSpanId // "") == "" or ($by[.parentSpanId] == null))) | sort_by(.startTimeUnixNano) | .[] | walk(.spanId; 0)
