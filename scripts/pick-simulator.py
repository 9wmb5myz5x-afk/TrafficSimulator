#!/usr/bin/env python3
"""Print the UDID of the first available iOS simulator whose name starts with
one of the given prefixes (tried in order), preferring the newest runtime.

Usage: pick-simulator.py "iPhone 16 Pro" "iPhone 15 Pro"
"""
import json, subprocess, sys

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
runtimes = sorted((r for r in data["devices"] if "iOS" in r), reverse=True,
                  key=lambda r: [int(x) if x.isdigit() else 0 for x in r.split("iOS-")[-1].split("-")])
for prefix in sys.argv[1:]:
    for rt in runtimes:
        for d in data["devices"][rt]:
            if d["name"] == prefix or d["name"].startswith(prefix):
                print(d["udid"]); sys.exit(0)
sys.stderr.write("no simulator matching %s\n" % sys.argv[1:])
sys.exit(1)
