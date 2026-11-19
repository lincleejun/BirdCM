#!/usr/bin/env python3
"""Summarise an .xcresult: pass/fail counts, failures with messages, slowest tests and seconds per test class.

usage: xcresult_summary.py RESULT.xcresult [N slowest]
"""
import json, subprocess, sys
from collections import defaultdict


def tool(kind, path):
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", path], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def cases(node, cls=None):
    if node.get("nodeType") == "Test Suite":
        cls = node["name"]
    if node.get("nodeType") == "Test Case":
        yield cls, node
        return
    for c in node.get("children", []):
        yield from cases(c, cls)


path, n = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 0
s = tool("summary", path)
print(f"  {s['passedTests']} passed, {s['failedTests']} failed, {s['skippedTests']} skipped; {s['finishTime'] - s['startTime']:.0f} s")
per_class, rows = defaultdict(float), []
for root in tool("tests", path)["testNodes"]:
    for cls, c in cases(root):
        t = c.get("durationInSeconds", 0)
        per_class[cls] += t
        rows.append((t, f"{cls}.{c['name']}", c.get("result")))
        if c.get("result") == "Failed":
            print(f"  FAILED {cls}.{c['name']}")
            for m in c.get("children", []):
                if m.get("nodeType") == "Failure Message":
                    print(f"    {m['name'][:300]}")
if n:
    for t, name, result in sorted(rows, reverse=True)[:n]:
        print(f"  {t:7.1f} {name} {result}")
    print("  per class (s): " + ", ".join(f"{k} {v:.0f}" for k, v in sorted(per_class.items(), key=lambda kv: -kv[1]) if v >= 1))
