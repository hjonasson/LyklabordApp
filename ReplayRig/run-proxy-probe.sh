#!/usr/bin/env bash
#
# run-proxy-probe.sh — run ProxyStalenessProbeTests against the REAL Lyklaborð
# extension in a simulator: does the keyboard's view of the text
# (`documentContextBeforeInput`) match what the host field really contains?
#
# Builds Release, reinstalls clean (iOS caches keyboard appexes), enables the
# keyboard through the Settings UI test, then runs the probes. A skipped test
# means Lyklaborð was not the keyboard on screen — that is not a pass.
#
# Usage: ReplayRig/run-proxy-probe.sh [test-name]     (default: all probes)
#   SIM_DEVICE="iPhone 16 Pro Max"   simulator to use (iOS 18.4 verified)
#   OUT=<dir>                        logs + result bundle (default: a temp dir)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DD="$ROOT/ReplayRig/.derived"
SIM_DEVICE="${SIM_DEVICE:-iPhone 16 Pro Max}"
OUT="${OUT:-$(mktemp -d /tmp/lyklabord-proxy-probe.XXXXXX)}"
ONLY="ReplayRigUITests/ProxyStalenessProbeTests${1:+/$1}"

UDID="$(xcrun simctl list devices available | awk -v d="$SIM_DEVICE" -F '[()]' '$0 ~ d" \\(" {print $2; exit}')"
[ -n "$UDID" ] || { echo "no available sim named $SIM_DEVICE"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "== build =="
xcodegen generate >/dev/null
xcodebuild build -scheme Lyklabord -project Lyklabord.xcodeproj -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$DD" -quiet >"$OUT/build-app.log" 2>&1
xcodebuild build-for-testing -scheme ReplayRig -project Lyklabord.xcodeproj \
  -destination "id=$UDID" -derivedDataPath "$DD" -quiet >"$OUT/build-rig.log" 2>&1

echo "== install + enable keyboard =="
xcrun simctl uninstall "$UDID" is.solberg.lyklabord 2>/dev/null || true
xcrun simctl install "$UDID" "$DD/Build/Products/Release-iphonesimulator/Lyklabord.app"
xcrun simctl install "$UDID" "$(find "$DD/Build/Products" -maxdepth 2 -name 'ReplayHost.app' | head -1)"
xcodebuild test-without-building -scheme ReplayRig -project Lyklabord.xcodeproj \
  -destination "id=$UDID" -derivedDataPath "$DD" \
  -only-testing:"ReplayRigUITests/ScreenshotUITests/testEnableKeyboardInSettings" \
  >"$OUT/enable.log" 2>&1 || true

echo "== probes ($ONLY) =="
set +e
xcodebuild test-without-building -scheme ReplayRig -project Lyklabord.xcodeproj \
  -destination "id=$UDID" -derivedDataPath "$DD" -only-testing:"$ONLY" \
  -resultBundlePath "$OUT/probe.xcresult" >"$OUT/probe.log" 2>&1
STATUS=$?
set -e
grep -E "Test Case.*(passed|failed|skipped)|field has" "$OUT/probe.log" | sed -E 's/^.*(Test Case|: )/\1/'
git checkout -- App/BuildInfo.swift KeyboardExt/BuildInfo.swift 2>/dev/null || true
if grep -q "Test Case.*skipped" "$OUT/probe.log"; then
  echo "SKIPPED tests: Lyklaborð was not the active keyboard — not a pass"; STATUS=1
fi
echo "== logs and result bundle: $OUT =="
exit $STATUS
