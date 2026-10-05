#!/bin/bash
set -euo pipefail

BACKGROUND_TEST_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BACKGROUND_TEST_TMP="$(mktemp -d)"
BACKGROUND_FIXTURE_PID=""
cleanup() {
  if [[ -n "$BACKGROUND_FIXTURE_PID" ]]; then
    kill "$BACKGROUND_FIXTURE_PID" 2>/dev/null || true
    wait "$BACKGROUND_FIXTURE_PID" 2>/dev/null || true
  fi
  rm -rf "$BACKGROUND_TEST_TMP"
}
trap cleanup EXIT
cd "$BACKGROUND_TEST_ROOT"

BACKGROUND_APP="ios/BikeSpot London/BikeSpot London"
swiftc "$BACKGROUND_APP/Models/LondonBackgroundRotation.swift" \
  "$BACKGROUND_APP/Models/LondonBackgroundCatalog.swift" \
  ios/BackgroundTests/BackgroundRotationChecks.swift -o "$BACKGROUND_TEST_TMP/rotation"
"$BACKGROUND_TEST_TMP/rotation"
swiftc "$BACKGROUND_APP/Models/LondonBackgroundCatalog.swift" \
  "$BACKGROUND_APP/Services/LondonBackgroundCache.swift" \
  ios/BackgroundTests/BackgroundCacheChecks.swift -o "$BACKGROUND_TEST_TMP/cache"
swiftc -D DEBUG "$BACKGROUND_APP/Models/LondonBackgroundRotation.swift" \
  "$BACKGROUND_APP/Models/LondonBackgroundCatalog.swift" \
  "$BACKGROUND_APP/Services/LondonBackgroundCache.swift" \
  "$BACKGROUND_APP/Services/LondonBackgroundService.swift" \
  ios/BackgroundTests/BackgroundDebugChecks.swift -o "$BACKGROUND_TEST_TMP/debug"

node ios/BackgroundTests/fixture-server.cjs > "$BACKGROUND_TEST_TMP/server-url" &
BACKGROUND_FIXTURE_PID=$!
for ((attempt = 0; attempt < 50; attempt++)); do
  [[ -s "$BACKGROUND_TEST_TMP/server-url" ]] && break
  kill -0 "$BACKGROUND_FIXTURE_PID"
  sleep 0.1
done
[[ -s "$BACKGROUND_TEST_TMP/server-url" ]]
"$BACKGROUND_TEST_TMP/cache" "$(head -n 1 "$BACKGROUND_TEST_TMP/server-url")"
"$BACKGROUND_TEST_TMP/debug" "$(head -n 1 "$BACKGROUND_TEST_TMP/server-url")"
