#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
build="$root/build"
bundle_id="dev.quackduck.jvm-spike"

device="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
for runtime_name, runtime in reversed(list(data.items())):
    if "iOS" not in runtime_name:
        continue
    for device in runtime:
        if device.get("isAvailable"):
            print(device["udid"])
            raise SystemExit
')"

xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$build/QuackDuckJVM.app"

data="$(xcrun simctl get_app_container "$device" "$bundle_id" data)"
xcrun simctl spawn "$device" log stream --style compact --level debug \
  --predicate "process == 'QuackDuckJVM'" > "$build/app.log" 2>&1 &
logger_pid=$!
trap 'kill "$logger_pid" 2>/dev/null || true; xcrun simctl shutdown "$device" 2>/dev/null || true' EXIT

xcrun simctl launch "$device" "$bundle_id"

for _ in {1..45}; do
  if [[ -f "$data/Documents/java-ok.txt" ]]; then
    cp "$data/Documents/java-ok.txt" "$build/java-ok.txt"
    cat "$build/java-ok.txt"
    xcrun simctl io "$device" screenshot "$build/screenshot.png"
    exit 0
  fi
  sleep 1
done

xcrun simctl io "$device" screenshot "$build/screenshot.png" || true
cat "$build/app.log" || true
echo 'Java did not create its sentinel file within 45 seconds.' >&2
exit 1
