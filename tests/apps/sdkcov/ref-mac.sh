#!/bin/bash
# x86Sim sdkcov: the reference run on Apple's own simulator, on the Mac ($X86SIM_MAC, over ssh). Same app, same
# runtime build where the Mac has it: what fails there too is Apple's behavior, not an x86Sim bug.
# A temporary simulator device (sdkcov-ref-<platform>) is created, used and deleted; other devices are not touched.
# Usage: tests/apps/sdkcov/ref-mac.sh [ios|ipad|tvos|watchos|xros] [--no-build] [--only ID[,ID...]]   (default ios)
#   ipad     the iOS app on an iPad (iPad Air 11-inch (M3), as x86Sim's cov-ipad) instead of an iPhone 17 Pro
# Env TRACKING=1 (with --only func:AppTrackingTransparency.input-tracking-granted): the app's tracking answered Allow
#   ahead (its kTCCServiceUserTracking row) and SDKCOV_INPUT_WAIT=40 in its launch environment, as inputs.sh tracking
# Env INPUT='CMD[;CMD...]' (with --only): host touches / keys sent every few seconds while the app runs, as inputs.sh
#   does on x86Sim, through mac/indigo.m (SimulatorKit's Indigo HID, built on the Mac): e.g. INPUT='drag 0.5 0.5 0.5 0.5
#   1500 32' (a long press), with SDKCOV_INPUT_WAIT=$WAIT (default 40) in the app's launch environment
# Env SHOTS='S1 S2 ...' (with --only): screenshots S seconds after the launch, OUT/shot-S.png
# Env LOGPRED='PREDICATE' (with --only): the simulator's unified log of the run (log show --info --debug, that
#   predicate, from the device's boot) comes back as OUT/log.txt
# Env CLIP=1 (with --only func:AppClip.input-clip-launch): the App Clip launched 10 s in with _XCAppClipURL, as inputs.sh clip
#   --only   one launch running just the checks whose id contains one of these (as run.sh --only); their results
#            are printed (the app's stderr is OUT/sdkcov-1.err), no report
# Env: RUNTIME (simctl runtime id, default the Mac's newest of the platform), DEVTYPE (simctl device type id, default
#      per platform above), SECS (default 900),
#      OUT (default $X86SIM_SCRATCH/apps/sdkcov-<platform>-ref-<time>). Then report.py's report.md is in OUT.
set -u
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/cli/lib/config.sh"
S=$X86SIM_ROOT/tests/apps/sdkcov
plat=${1:-ios}; [ "${1:-}" ] && shift
name=$plat   # the temp device's and OUT's name: ipad runs the ios app
build=1 only=
while [ $# -gt 0 ]; do case $1 in --no-build) build=0 ;; --only) only=$2; shift ;;
	*) echo "ref-mac: unknown option $1" >&2; exit 2 ;; esac; shift; done
MAC=${X86SIM_MAC:?set X86SIM_MAC (ssh host of a Mac with Xcode) in x86sim.env}
case $plat in
	ios) rtname=iOS; dtype=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro ;;
	ipad) plat=ios; rtname=iOS; dtype=com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M3 ;;
	tvos) rtname=tvOS; dtype=com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p ;;
	watchos) rtname=watchOS; dtype=com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm ;;
	xros) rtname=visionOS,xrOS;   # simctl's platform name, by Xcode version
		dtype=com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K ;;
	*) echo "ref-mac: unknown platform $plat" >&2; exit 2 ;;
esac
dtype=${DEVTYPE:-$dtype}
OUT=${OUT:-$X86SIM_SCRATCH/apps/sdkcov-$name-ref-$(date +%Y%m%d-%H%M%S)}; mkdir -p "$OUT"
[ "$build" = 1 ] && { "$S/build.sh" "$plat" >/dev/null 2>&1 || { echo "ref-mac: build failed" >&2; exit 1; }; }
APP=${SDKCOV_APPS:-$X86SIM_SCRATCH/apps}/sdkcov-$plat.app
# the whole run happens on the Mac in one ssh session: the app goes over as a tar on stdin, the results come back
# (the remote script is an argument: stdin carries the app)
read -r -d '' REMOTE <<'MAC'
plat=$1 rtname=$2 dtype=$3 rt=$4 secs=$5 only=$6 name=$7 tracking=${8:-} clip=${9:-} input=${10:-} shots=${11:-} iwait=${12:-40} logpred=${13:-}
set -u
W=$(mktemp -d /tmp/sdkcov-ref.XXXXXX); cd "$W"; tar xf - -C "$W"
exec 3>&1 1>&2
[ -n "$rt" ] || rt=$(xcrun simctl list runtimes -j | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin)['runtimes'] if x['platform'] in '$rtname'.split(',') and x['isAvailable']]; print(sorted(r, key=lambda x: [int(p) for p in x['version'].split('.')])[-1]['identifier'])")
dev=$(xcrun simctl create "sdkcov-ref-$name" "$dtype" "$rt") || exit 1
cleanup() { xcrun simctl shutdown "$dev" >/dev/null 2>&1; xcrun simctl delete "$dev" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
echo "ref-mac: $rt on $dev"
tb=$(date +%s); xcrun simctl boot "$dev" && xcrun simctl bootstatus "$dev" -b >/dev/null
xcrun simctl install "$dev" "$W/sdkcov-$plat.app" || exit 1
[ -d "$W/sdkcovDoc-$plat.app" ] && { xcrun simctl install "$dev" "$W/sdkcovDoc-$plat.app" || echo "ref-mac: sdkcovDoc not installed"; }
# the App Clip after the app, as run.sh (installing the full app removes an installed clip of it)
for c in "$W/sdkcov-$plat.app"/AppClips/*.app; do [ -d "$c" ] && { xcrun simctl install "$dev" "$c" || echo "ref-mac: App Clip $c not installed"; }; done
# tvOS / watchOS / visionOS: func:HomeKit.manager's HMHomeManager asks for Home access; the prompt would take focus from the app
# for the rest of the run (More_tvOS.swift's focus, window and snapshot checks need the app active; on the watch the
# app stayed inactive behind it, applicationState 1): grant it up front
# (simctl privacy over ssh fails here: "Failed to create TCC authorization record: Operation not permitted"; the
# device's TCC.db takes the row directly, as simctl would write it)
case $plat in ios|tvos|watchos|xros) xcrun simctl privacy "$dev" grant homekit com.x86sim.test.sdkcov >/dev/null 2>&1 ||
	sqlite3 "$HOME/Library/Developer/CoreSimulator/Devices/$dev/data/Library/TCC/TCC.db" "insert or replace into access
		(service, client, client_type, auth_value, auth_reason, auth_version, flags) values
		('kTCCServiceWillow', 'com.x86sim.test.sdkcov', 0, 2, 4, 1, 0)" || echo "ref-mac: HomeKit not pre-granted" ;; esac
# Photos read-write access for the library checks (P1_Library.swift), as run.sh grants it on x86Sim
case $plat in ios|tvos|xros) xcrun simctl privacy "$dev" grant photos com.x86sim.test.sdkcov >/dev/null 2>&1 ||
	sqlite3 "$HOME/Library/Developer/CoreSimulator/Devices/$dev/data/Library/TCC/TCC.db" "insert or replace into access
		(service, client, client_type, auth_value, auth_reason, auth_version, flags) values
		('kTCCServicePhotos', 'com.x86sim.test.sdkcov', 0, 2, 4, 2, 0)" || echo "ref-mac: Photos not pre-granted" ;; esac
# Location when in use + a simulated location (Apple Park) for P5_Location.swift's CoreLocation checks, as run.sh does
# on x86Sim (x86sim privacy / x86sim location)
xcrun simctl privacy "$dev" grant location com.x86sim.test.sdkcov >/dev/null 2>&1 || echo "ref-mac: location not pre-granted"
xcrun simctl location "$dev" set 37.3349,-122.0090 >/dev/null 2>&1 || echo "ref-mac: no simulated location"
# Contacts, Calendars (full access), Reminders (P4_People.swift's store checks) and the microphone (P12_Gaps.swift), as run.sh grants them on x86Sim
for svc in AddressBook Calendar Reminders Microphone; do sqlite3 "$HOME/Library/Developer/CoreSimulator/Devices/$dev/data/Library/TCC/TCC.db" "insert or replace into access
	(service, client, client_type, auth_value, auth_reason, auth_version, flags) values
	('kTCCService$svc', 'com.x86sim.test.sdkcov', 0, 2, 4, 1, 0)" || echo "ref-mac: $svc not pre-granted"; done
# the app's FileProvider extension enabled as on a device whose fileproviderd first starts with the app installed:
# fileproviderd's one-time LegacyEnabledStateHasBeenMigrated migration enables the extensions present then; one it meets
# later stays disabled ("Sync is not enabled", -2011) until the user enables it in Files
# (func:FileProvider.replicated-extension-domain). As run.sh does on x86Sim
fp="$HOME/Library/Developer/CoreSimulator/Devices/$dev/data/Library/Application Support/FileProvider"
case $plat in ios|xros) if [ -e "$fp/LegacyEnabledStateHasBeenMigrated" ] &&
		[ "$(plutil -extract NSFileProviderDomainDefaultIdentifier.Enabled raw "$fp/com.x86sim.test.sdkcov.fileprovider/Domains.plist" 2>/dev/null)" != true ]; then
	rm -rf "$fp/LegacyEnabledStateHasBeenMigrated" "$fp/com.x86sim.test.sdkcov.fileprovider"
	xcrun simctl spawn "$dev" launchctl kill SIGKILL user/foreground/com.apple.FileProvider >/dev/null 2>&1
	echo "ref-mac: FileProvider extension state reset (enable migration rerun)"
fi ;; esac
# TRACKING=1: App Tracking Transparency allowed ahead (inputs.sh tracking on x86Sim) and the input check told to wait for it
[ -n "$tracking" ] && { sqlite3 "$HOME/Library/Developer/CoreSimulator/Devices/$dev/data/Library/TCC/TCC.db" "insert or replace into access
	(service, client, client_type, auth_value, auth_reason, auth_version, flags) values
	('kTCCServiceUserTracking', 'com.x86sim.test.sdkcov', 0, 2, 2, 1, 0)" || echo "ref-mac: tracking not granted"; export SIMCTL_CHILD_SDKCOV_INPUT_WAIT=40; }
[ -n "$clip" ] && export SIMCTL_CHILD_SDKCOV_INPUT_WAIT=40
if [ -n "$input" ]; then export SIMCTL_CHILD_SDKCOV_INPUT_WAIT=$iwait
	clang -fobjc-arc -o "$W/indigo" "$W/indigo.m" -framework Foundation -framework AppKit -framework IOKit || { echo "ref-mac: indigo build failed"; input=; }; fi
data=$(xcrun simctl get_app_container "$dev" com.x86sim.test.sdkcov data)
res=$data/Documents/x86test-results.txt
t0=$(date +%s); n=0 miss=0
if [ -n "$only" ]; then   # one launch; its stderr is the result
	# --console-pty: the app's stdout / stderr come back through simctl (a --stderr file stays empty here)
	xcrun simctl launch --console-pty "$dev" com.x86sim.test.sdkcov --only "$only" >"$W/sdkcov-1.err" 2>&1 &
	sleep 5
	[ -n "$clip" ] && { sleep 5; SIMCTL_CHILD__XCAppClipURL=https://example.com/sdkcov xcrun simctl launch "$dev" com.x86sim.test.sdkcov.Clip >/dev/null; }
	while [ $(( $(date +%s) - t0 )) -lt "$secs" ] && ! grep -q "X86TEST sdkcov done " "$W/sdkcov-1.err" 2>/dev/null; do
		for s in $shots; do [ $(( $(date +%s) - t0 )) -ge "$s" ] && [ ! -e "$W/shot-$s.png" ] && xcrun simctl io "$dev" screenshot "$W/shot-$s.png" >/dev/null 2>&1; done
		[ -n "$input" ] && [ $(( $(date +%s) - t0 )) -ge 8 ] && { IFS=';' read -ra cmds <<< "$input"
			for c in "${cmds[@]}"; do "$W/indigo" "$dev" $c >/dev/null; done; }
		# gone only after 3 misses in a row (as run.sh: one empty answer ended a run with the app still going)
		if xcrun simctl spawn "$dev" launchctl list 2>/dev/null | grep -q "com.x86sim.test.sdkcov"; then miss=0
		else miss=$((miss + 1)); [ $miss -ge 3 ] && break; fi
		sleep 2
	done
	xcrun simctl terminate "$dev" com.x86sim.test.sdkcov >/dev/null 2>&1; sleep 1; kill %1 2>/dev/null
	[ -n "$logpred" ] && xcrun simctl spawn "$dev" log show --info --debug --start "$(date -r "$tb" '+%Y-%m-%d %H:%M:%S')" --predicate "$logpred" > "$W/log.txt" 2>&1
	cd "$W" && tar cf - sdkcov-*.err shot-*.png log.txt 2>/dev/null >&3
	exit 0
fi
while [ $(( $(date +%s) - t0 )) -lt "$secs" ]; do
	grep -q "^X86TEST sdkcov done " "$res" 2>/dev/null && break
	if ! xcrun simctl spawn "$dev" launchctl list 2>/dev/null | grep -q "UIKitApplication:com.x86sim.test.sdkcov"; then
		n=$((n + 1)); [ $n -gt 40 ] && break
		xcrun simctl launch --stderr="$W/sdkcov-$n.err" "$dev" com.x86sim.test.sdkcov >/dev/null
	fi
	sleep 3
done
cp "$res" "$W/results.txt" 2>/dev/null; cp "$data/Documents/sdkcov-coverage.json" "$W/coverage.json" 2>/dev/null
xcrun simctl io "$dev" screenshot "$W/screen.png" >/dev/null 2>&1
cd "$W" && tar cf - results.txt coverage.json screen.png sdkcov-*.err 2>/dev/null >&3
MAC
DOC=sdkcovDoc-$plat.app; [ -d "$(dirname "$APP")/$DOC" ] || DOC=
tar cf - -C "$(dirname "$APP")" "$(basename "$APP")" $DOC -C "$S/mac" indigo.m |
	ssh -o BatchMode=yes "$MAC" "bash -c $(printf '%q' "$REMOTE") ref $plat $rtname $dtype '${RUNTIME:-}' ${SECS:-900} '$only' $name '${TRACKING:-}' '${CLIP:-}' '${INPUT:-}' '${SHOTS:-}' '${WAIT:-40}' $(printf '%q' "${LOGPRED:-}")" > "$OUT/ref.tar"
(cd "$OUT" && tar xf ref.tar && rm ref.tar)
if [ -n "$only" ]; then
	tr -d '\r' < "$OUT/sdkcov-1.err" | grep "^X86TEST" | grep -v -e " only " -e " done " | cut -d' ' -f3-
	grep -q "X86TEST sdkcov done " "$OUT/sdkcov-1.err" 2>/dev/null ||
		{ echo "ref-mac: the app did not finish; stderr tail:"; grep -v X86TEST "$OUT/sdkcov-1.err" 2>/dev/null | tail -15; }
	echo "stderr: $OUT/sdkcov-1.err"; exit 0
fi
[ -f "$OUT/results.txt" ] || { echo "ref-mac: no results came back" >&2; exit 1; }
python3 "$S/report.py" "$OUT" > "$OUT/report.md"
sed -n '1,/^## Failures/p' "$OUT/report.md" | grep -v '^## Failures'
echo "report: $OUT/report.md"
