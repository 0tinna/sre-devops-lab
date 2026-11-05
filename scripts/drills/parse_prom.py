import sys
import json

try:
    payload = json.load(sys.stdin)
    results = payload["data"]["result"]
except Exception:
    print("  (查询失败)")
    raise SystemExit(0)

if not results:
    print("  (无数据)")
    raise SystemExit(0)

for item in results:
    metric = item.get("metric", {})
    labels = {k: v for k, v in metric.items() if k != "__name__"}
    value = item.get("value", [None, None])[1]
    if labels:
        printable = ", ".join("%s=%s" % (k, v) for k, v in sorted(labels.items()))
        print("  {%s} = %s" % (printable, value))
    else:
        print("  %s = %s" % (metric.get("__name__", "scalar"), value))
