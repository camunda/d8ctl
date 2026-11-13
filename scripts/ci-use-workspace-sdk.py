#!/usr/bin/env python3
"""CI only: point every camunda-orchestration-sdk[:sub] dependency at the
in-workspace SDK checkout (actions/checkout cannot write to ../)."""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "orchestration-cluster-api-dlang"
d = json.load(open("dub.json"))
deps = d.get("dependencies", {})
hit = [k for k in deps if k.split(":")[0] == "camunda-orchestration-sdk"]
if not hit:
    sys.exit("no camunda-orchestration-sdk dependency in dub.json")
for k in hit:
    deps[k] = {"path": path}
open("dub.json", "w").write(json.dumps(d, indent=2) + "\n")
print("dub.json:", ", ".join(f"{k} -> {path}" for k in hit))
