# jq helpers for OTLP/JSON as written by the collector's file exporter
# (one Export*ServiceRequest JSON object per line).

# AnyValue -> plain JSON value. OTLP/JSON encodes int64 as strings.
def anyval:
  if . == null then null
  elif has("stringValue") then .stringValue
  elif has("intValue") then (.intValue | tonumber)
  elif has("doubleValue") then .doubleValue
  elif has("boolValue") then .boolValue
  elif has("arrayValue") then [ (.arrayValue.values // [])[] | anyval ]
  elif has("kvlistValue") then ((.kvlistValue.values // []) | map({(.key): (.value | anyval)}) | add // {})
  elif has("bytesValue") then "<bytes>"
  else null end;

# [{key, value:{...}}] -> {key: plain}
def attrmap: (. // []) | map({(.key): (.value | anyval)}) | add // {};

def spans:    .resourceSpans[]?   | .scopeSpans[]?   | .spans[]?;
def logrecs:  .resourceLogs[]?    | .scopeLogs[]?    | .logRecords[]?;
def metrics:  .resourceMetrics[]? | .scopeMetrics[]? | .metrics[]?;
def resources: (.resourceSpans[]?, .resourceLogs[]?, .resourceMetrics[]?) | .resource;

# Best-effort event name for a log record.
def eventname:
  .eventName
  // ((.attributes | attrmap)["event.name"])
  // (if (.body.stringValue? // null) != null then (.body.stringValue | .[0:60]) else null end)
  // "(unnamed)";

def datapoints: (.sum // .gauge // .histogram // .exponentialHistogram // .summary // {}) | (.dataPoints // []);
def metrictype: if .sum then "sum" elif .gauge then "gauge" elif .histogram then "histogram"
  elif .exponentialHistogram then "exp_histogram" elif .summary then "summary" else "?" end;

# {name: count}, sorted by count desc, as "  count  name" lines.
def countlines: group_by(.) | map({k: .[0], n: length}) | sort_by(-.n, .k) | .[] | "  \(.n|tostring|(" " * (6 - length)) + .)  \(.k)";

# Sum numeric values of keys containing "token" across a list of attr maps.
def tokensums: map(to_entries[] | select((.key | test("token"; "i")) and (.value | type) == "number"))
  | group_by(.key) | map({key: .[0].key, sum: (map(.value) | add), n: length})
  | .[] | "  \(.sum)\t(\(.n) values)\t\(.key)";
