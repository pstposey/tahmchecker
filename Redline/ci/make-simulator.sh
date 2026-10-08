#!/bin/bash
# CI: creates a fresh iPhone simulator on the newest iOS runtime matching the
# selected Xcode's major version (falling back to the newest older one) and
# prints its UDID. A fresh device means a first launch with no saved
# settings, like a new install on a phone.
set -euo pipefail
major="$1"
python3 - "$major" <<'PY'
import json, subprocess, sys
major = int(sys.argv[1])
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "available", "-j"]))["runtimes"]
ios = [r for r in runtimes if r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")]
def version(r):
    return tuple(int(x) for x in r["version"].split("."))
ios.sort(key=version)
print("iOS runtimes: " + ", ".join(r["name"] for r in ios), file=sys.stderr)
candidates = [r for r in ios if version(r)[0] == major] or [r for r in ios if version(r)[0] <= major]
if not candidates:
    sys.exit("No usable iOS simulator runtime")
runtime = candidates[-1]
phones = [t for t in runtime.get("supportedDeviceTypes", []) if t.get("productFamily") == "iPhone"]
if not phones:
    sys.exit("No iPhone device type for " + runtime["name"])
phone = phones[-1]
udid = subprocess.check_output(["xcrun", "simctl", "create", "Redline first launch", phone["identifier"], runtime["identifier"]]).decode().strip()
print(f"Simulator: {phone['name']} on {runtime['name']} ({udid})", file=sys.stderr)
print(udid)
PY
