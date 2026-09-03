#!/usr/bin/env bash
# Re-vendor the upstream CloudNativePG Grafana dashboard.
#
# Upstream ships Grafana's "export for sharing" format, which the sidecar cannot
# resolve: __inputs are only filled in by the interactive import dialog, so
# file-provisioned panels would reference an undefined ${DS_PROMETHEUS}.
# Output is minified - it rides in a ConfigMap whose client-side-apply
# annotation is capped at 262144 bytes, and the pretty form is ~252KB.
set -euo pipefail

REF="${1:-7dd1bc255b52}"   # upstream commit; pass another to bump
SRC="https://raw.githubusercontent.com/cloudnative-pg/grafana-dashboards/${REF}/charts/cluster/grafana-dashboard.json"
OUT="$(dirname "$0")/cloudnative-pg.json"

curl -sSL --max-time 60 "$SRC" -o "$OUT.raw"
python3 - "$OUT.raw" "$OUT" "$REF" <<'PY'
import json, sys
raw, out, ref = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(raw))
d.pop("__inputs", None)
d.pop("__requires", None)
# The DS_PROMETHEUS templating variable survives and resolves ${DS_PROMETHEUS};
# point it at this cluster's Prometheus-typed VictoriaMetrics datasource.
for t in d.get("templating", {}).get("list", []):
    if t.get("type") == "datasource" and t.get("name") == "DS_PROMETHEUS":
        t["current"] = {"selected": True, "text": "VictoriaMetrics", "value": "VictoriaMetrics"}
# DS_EXPRESSION had no templating variable - inline Grafana's built-in expression datasource.
s = json.dumps(d, separators=(",", ":")).replace("${DS_EXPRESSION}", "__expr__")
assert "${DS_EXPRESSION}" not in s and "__inputs" not in s
d = json.loads(s)
d["__vendored_from"] = f"cloudnative-pg/grafana-dashboards@{ref} charts/cluster/grafana-dashboard.json"
open(out, "w").write(json.dumps(d, separators=(",", ":")))
n = len(open(out, "rb").read())
assert n < 200000, f"{n} bytes - too close to the 262144 annotation cap"
print(f"wrote {out} ({n} bytes)")
PY
rm -f "$OUT.raw"
