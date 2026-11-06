#!/bin/sh
# Headless lab run for freight-stations-rats-fork.
#
# Requires a one-time lab setup (scenario fs-test + fs-test driver mod):
#   make lab-setup LAB_DIR=../test-env
# The lab dir defaults to ../test-env and keeps its own copy of the mod in
# $LAB_DIR/mods/freight-stations - this script re-syncs it from the repo so
# the lab always tests the current tree, then runs the full suite and fails
# on any anomaly (script errors, stuck/spilled entities, a failed scenario).

set -eu

FACTORIO_BIN="${FACTORIO_BIN:-$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"
LAB_DIR="${LAB_DIR:-../test-env}"
LAB_PORT="${LAB_PORT:-34199}"
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
LAB_MOD="$LAB_DIR/mods/freight-stations-rats-fork"

if [ ! -d "$LAB_DIR/scenarios/fs-test" ]; then
	echo "ERROR: no lab at $LAB_DIR (missing $LAB_DIR/scenarios/fs-test)."
	echo "Set LAB_DIR to an existing lab dir, or create one with make lab-setup."
	exit 2
fi

echo "== syncing repo -> lab =="
rm -rf "$LAB_MOD"
# remove a stale copy under the pre-rename name, if the lab ever had one
rm -rf "$LAB_DIR/mods/freight-stations"
cp -R "$REPO_DIR" "$LAB_MOD"
rm -rf "$LAB_MOD/.git" "$LAB_MOD/releases" "$LAB_MOD/tests"

cd "$LAB_DIR"
echo "== running headless lab =="
rm -f "$LAB_DIR/factorio-current.log"
"$FACTORIO_BIN" \
	--start-server-load-scenario fs-test \
	--config "$LAB_DIR/lab-config.ini" \
	--server-settings "$LAB_DIR/lab-server-settings.json" \
	--port "$LAB_PORT" >/dev/null 2>&1 &
SERVER_PID=$!

# The suite is tick-based and finishes in a few seconds of game time; the
# server then idles forever, so watch the log and kill it when done. Bail
# early on startup failures instead of waiting out the whole window.
for _ in $(seq 1 120); do
	if [ -f "$LAB_DIR/factorio-current.log" ]; then
		if grep -q "ALL TESTS DONE" "$LAB_DIR/factorio-current.log" 2>/dev/null; then
			break
		fi
		if grep -qE "Failed to load mod|MultiplayerManager failed" "$LAB_DIR/factorio-current.log" 2>/dev/null; then
			break
		fi
	fi
	sleep 1
done
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

if ! grep -q "ALL TESTS DONE" "$LAB_DIR/factorio-current.log" 2>/dev/null; then
	echo "FAIL: lab did not reach 'ALL TESTS DONE' (see $LAB_DIR/factorio-current.log)"
	exit 1
fi

REPORT="$LAB_DIR/lab-report.txt"
grep -o '\[FSTEST\].*' "$LAB_DIR/factorio-current.log" | sed 's/\[FSTEST\] //' > "$REPORT"
echo "== report: $REPORT =="

ANOMALIES=$(grep -cE '!!|ERROR|SPILLED ITEM|revive STUCK' "$REPORT" || true)
if [ "$ANOMALIES" != "0" ]; then
	echo "FAIL: $ANOMALIES anomaly lines:"
	grep -E '!!|ERROR|SPILLED ITEM|revive STUCK' "$REPORT"
	exit 1
fi

OVERLAPS=$(grep -c 'no balancer/station overlaps' "$REPORT" || true)
echo "ok: suite complete, $ANOMALIES anomalies, $OVERLAPS overlap checks passed"
