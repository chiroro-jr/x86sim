#!/bin/bash
# x86Sim sdkcov: build the SDK coverage app for a running device's platform (iOS, tvOS, watchOS or visionOS, from
# <device>/runtime), install it, launch it and keep it going until it reports "done": a crash or the app's hang
# watchdog ends the process, and the next launch resumes after the check that died (Harness.swift). Then the results,
# the coverage JSON and a Markdown report (report.py) go to OUT, with a screenshot.
# Usage: tests/apps/sdkcov/run.sh <device> [--no-build] [--fresh] [--only ID[,ID...]]
#   --fresh   start over (delete the previous run's results in the app's container)
#   --only    run only the checks whose id contains one of these (e.g. func:Metal,load:UIKit); for debugging: the
#             results file is left alone, results go to the app's stderr (OUT/sdkcov-1.err)
# One run per device: a second run.sh / inputs.sh on it stops with "is busy" (devlock.sh).
# Env: SECS (overall limit, default 3600), STALL (relaunch when no new result for this long, default 300),
#      RELAUNCH (max relaunches, default 40), OUT (default $X86SIM_SCRATCH/apps/sdkcov-<platform>-<time>).
set -u
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/cli/lib/config.sh"
. "$X86SIM_ROOT/cli/lib/pickdevice.sh"
X=$X86SIM_ROOT; S=$X/tests/apps/sdkcov
dev=${1:?usage: tests/apps/sdkcov/run.sh <device> [--no-build] [--fresh]}; shift
pick_device "$dev" || { echo "sdkcov: no device $dev" >&2; exit 2; }
export X86SIM_DEVICE
. "$S/devlock.sh"; devlock "$BASH" "$0" "$dev" "$@"   # one run per device (devlock.sh): exits here unless this is the locked run
build=1 fresh=0
ONLY=
while [ $# -gt 0 ]; do case $1 in --no-build) build=0 ;; --fresh) fresh=1 ;; --only) ONLY="--only $2"; shift ;;
	*) echo "sdkcov: unknown option $1" >&2; exit 2 ;; esac; shift; done
rt=$(cat "$X86SIM_DEVICE/runtime" 2>/dev/null); plat=${rt%%-*}
case $plat in ios|tvos|watchos|xros) ;; *) echo "sdkcov: $X86SIM_DEVICE: unsupported runtime '$rt'" >&2; exit 2 ;; esac
SECS=${SECS:-3600}; STALL=${STALL:-300}; RELAUNCH=${RELAUNCH:-40}
OUT=${OUT:-$X86SIM_SCRATCH/apps/sdkcov-$plat-$(date +%Y%m%d-%H%M%S)}; mkdir -p "$OUT"
BID=com.x86sim.test.sdkcov; APP=${SDKCOV_APPS:-$X86SIM_SCRATCH/apps}/sdkcov-$plat.app
xs() { "$X/cli/x86sim" "$@"; }
[ "$build" = 1 ] && { nice "$S/build.sh" "$plat" || exit 1; }
xs install "$X86SIM_DEVICE" "$APP" >"$OUT/install.log" 2>&1 || { echo "install FAILED: $(tail -1 "$OUT/install.log")"; exit 1; }
# the App Clip (iOS: AppClips/sdkcovClip.app) goes in after the app, as Xcode installs one (installing the full app
# removes an installed clip of it): func:AppClip.clip-installed-with-parent
for c in "$APP"/AppClips/*.app; do [ -d "$c" ] && { xs install "$X86SIM_DEVICE" "$c" >>"$OUT/install.log" 2>&1 || echo "  note: App Clip $(basename "$c") not installed: $(tail -1 "$OUT/install.log")"; }; done
DATA=$(xs get_app_container "$BID" data 2>/dev/null)
[ -d "$DATA" ] || { echo "sdkcov: no data container for $BID" >&2; exit 1; }
RES=$DATA/Documents/x86test-results.txt
rm -f "$X86SIM_DEVICE"/data/tmp/sdkcov-*.out "$X86SIM_DEVICE"/data/tmp/sdkcov-*.err
# func:HomeKit.manager's Home access prompt would cover the app for the rest of the run (tvOS / watchOS / visionOS: the
# focus, window and snapshot checks then fail "not foreground-active"; P5_Home.swift's home manager checks need it on
# iOS too): granted up front, as ref-mac.sh does on Apple's
case $plat in ios|tvos|watchos|xros) sqlite3 "$X86SIM_DEVICE/data/Library/TCC/TCC.db" "insert or replace into access
	(service, client, client_type, auth_value, auth_reason, auth_version, flags) values
	('kTCCServiceWillow', '$BID', 0, 2, 4, 1, 0)" 2>/dev/null || echo "  note: HomeKit not pre-granted (no TCC.db yet?)" ;; esac
# Photos read-write access (P1_Library.swift's library checks write and fetch assets; no prompt), the row simctl
# privacy grant photos writes (auth_version 2: with 1 Photos reports notDetermined): as ref-mac.sh does
case $plat in ios|tvos|xros) sqlite3 "$X86SIM_DEVICE/data/Library/TCC/TCC.db" "insert or replace into access
	(service, client, client_type, auth_value, auth_reason, auth_version, flags) values
	('kTCCServicePhotos', '$BID', 0, 2, 4, 2, 0)" 2>/dev/null || echo "  note: Photos not pre-granted (no TCC.db yet?)" ;; esac
# Contacts, Calendars (full access) and Reminders (P4_People.swift's store checks; no prompt): as ref-mac.sh does
for svc in AddressBook Calendar Reminders; do sqlite3 "$X86SIM_DEVICE/data/Library/TCC/TCC.db" "insert or replace into access
	(service, client, client_type, auth_value, auth_reason, auth_version, flags) values
	('kTCCService$svc', '$BID', 0, 2, 4, 1, 0)" 2>/dev/null || echo "  note: $svc not pre-granted (no TCC.db yet?)"; done
# Location when in use + a simulated location (Apple Park) for P5_Location.swift's CoreLocation checks (no prompt): as
# ref-mac.sh does with simctl privacy / simctl location
xs privacy grant location "$BID" >/dev/null 2>&1 || echo "  note: location not pre-granted (x86sim privacy)"
xs location set 37.3349,-122.0090 >/dev/null 2>&1 || echo "  note: no simulated location (x86sim location)"
[ "$fresh" = 1 ] && rm -f "$RES" "$DATA/Documents/sdkcov-progress" "$DATA/Documents/sdkcov-coverage.json"
# a finished previous run starts over by itself (Harness.prepare); an unfinished one resumes
echo "sdkcov $plat on $(basename "$X86SIM_DEVICE"): results $RES"
# WidgetKit needs chronod, which is the device's "widgets" feature (off by default: ~350-750 MB): on for sdkcov devices
grep -qs '"widgets": *true' "$X86SIM_DEVICE/features.json" ||
	echo "  note: feature \"widgets\" is off on this device: WidgetKit fails (x86sim-aot features, or features.json)"
# is the app running? Not running only after 3 misses in a row, 1 s apart: a single empty `x86sim pidof` (a failed
# request, the app between execs) ended --only runs with "no result" while the app went on (and cost full runs a
# relaunch). pidof's complaints go to OUT/pidof.log.
alive() { local i; for i in 1 2 3; do [ -n "$(xs pidof "$BID" 2>>"$OUT/pidof.log")" ] && return 0; [ $i = 3 ] || sleep 1; done; return 1; }
lines() { [ -f "$RES" ] && wc -l < "$RES" || echo 0; }
done_() { [ -f "$RES" ] && grep -q "^X86TEST sdkcov done " "$RES"; }
t0=$(date +%s); launches=0; last=$(lines); lastt=$t0
launch() {
	launches=$((launches + 1))
	xs terminate "$BID" >/dev/null 2>&1
	# the app's stdout / stderr per launch (abort messages, Swift runtime errors) in the device's tmp, copied to OUT
	xs launch --stdout=tmp/sdkcov-$launches.out --stderr=tmp/sdkcov-$launches.err "$BID" $ONLY >>"$OUT/launch.log" 2>&1 ||
		echo "  launch $launches failed: $(tail -1 "$OUT/launch.log")"
	sleep 5
}
# a first launch of a finished run starts over: the app resets when it sees "done"
launch
if [ -n "$ONLY" ]; then   # one launch; its stderr is the result
	t1=$(date +%s)
	until grep -q "X86TEST sdkcov done " "$X86SIM_DEVICE/data/tmp/sdkcov-1.err" 2>/dev/null; do
		[ $(($(date +%s) - t1)) -lt "$SECS" ] && alive || break; sleep 2; done
	cp "$X86SIM_DEVICE"/data/tmp/sdkcov-1.* "$OUT/" 2>/dev/null
	grep "X86TEST" "$OUT/sdkcov-1.err" | grep -v -e " only " -e " done "
	grep -q "X86TEST sdkcov done " "$OUT/sdkcov-1.err" 2>/dev/null || alive || { echo "app exited; stderr tail:"; grep -v X86TEST "$OUT/sdkcov-1.err" | tail -15; }
	exit 0
fi
while ! done_; do
	sleep 5
	now=$(date +%s); n=$(lines)
	[ "$n" != "$last" ] && { last=$n; lastt=$now; printf '\r  %s results, %s launches, %s s ' "$n" "$launches" $((now - t0)); }
	[ $((now - t0)) -gt "$SECS" ] && { echo; echo "  gave up after $SECS s"; break; }
	up=1; alive || up=
	if [ -z "$up" ] || [ $((now - lastt)) -gt "$STALL" ]; then
		[ "$launches" -ge "$RELAUNCH" ] && { echo; echo "  gave up after $launches launches"; break; }
		echo; echo "  $([ -z "$up" ] && echo "app not running (crash / watchdog)" || echo "no progress in $STALL s"): relaunch; last: $(tail -1 "$RES" 2>/dev/null | cut -c1-160)"
		launch; lastt=$(date +%s)
	fi
done
echo
cp "$RES" "$OUT/results.txt" 2>/dev/null
for f in "$X86SIM_DEVICE"/data/tmp/sdkcov-*.out "$X86SIM_DEVICE"/data/tmp/sdkcov-*.err; do [ -s "$f" ] && cp "$f" "$OUT/"; done
cp "$DATA/Documents/sdkcov-coverage.json" "$OUT/coverage.json" 2>/dev/null
find "$DATA/Library/Logs/DiagnosticReports" "$X86SIM_DEVICE/data/Library/Logs/DiagnosticReports" -name 'sdkcov*' -newer "$OUT/install.log" -exec cp {} "$OUT/" \; 2>/dev/null
xs screenshot "$OUT/screen.png" 2 >/dev/null 2>&1
python3 "$S/report.py" "$OUT" > "$OUT/report.md"
sed -n '1,/^## Failures/p' "$OUT/report.md" | grep -v '^## Failures'
grep -c ' FAIL ' "$OUT/results.txt" 2>/dev/null | sed 's/^/FAIL lines: /'
echo "report: $OUT/report.md"
done_ && ! grep -q ' FAIL ' "$OUT/results.txt" && { echo PASS; exit 0; }
echo FAIL; exit 1
