#!/bin/bash
# x86Sim sdkcov: the host-driven input checks (checks/Inputs.swift) on a running device: each check runs alone (run.sh
# --only) with SDKCOV_INPUT_WAIT set, while this script sends its input every few seconds through the x86sim CLI
# (host/simhid), as Apple's simulator would (DeviceHub's Shake / Rotate / Face ID menus, a game controller).
# Usage: tests/apps/sdkcov/inputs.sh <device> [--no-build] [shake|orientation|biometric|gamepad ...]   (default: all
# the device's platform has)
# On Apple's simulator the same inputs are: notifyutil -p com.apple.UIKit.SimulatorShake (simctl spawn), devicectl
# device orientation set, notifyutil -s com.apple.BiometricKit.enrollmentChanged 1 + devicectl device simulate
# biometrics --success, an Indigo game controller message (SimulatorKit IndigoHIDMessageForGameControllerEvent) and
# SimDevice simulateMemoryWarning.
set -u
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/cli/lib/config.sh"
. "$X86SIM_ROOT/cli/lib/pickdevice.sh"
S=$X86SIM_ROOT/tests/apps/sdkcov
dev=${1:?usage: tests/apps/sdkcov/inputs.sh <device> [--no-build] [check...]}; shift
pick_device "$dev" || { echo "inputs: no device $dev" >&2; exit 2; }
export X86SIM_DEVICE
build=; want=
for a in "$@"; do case $a in --no-build) build=--no-build ;; *) want="$want $a" ;; esac; done
rt=$(cat "$X86SIM_DEVICE/runtime" 2>/dev/null); plat=${rt%%-*}
case $plat in
	ios) all="shake orientation biometric gamepad memwarn" ;; xros) all="shake biometric gamepad memwarn" ;; tvos) all="gamepad memwarn" ;;
	*) echo "inputs: no input checks for $plat" >&2; exit 0 ;;
esac
xs() { "$X86SIM_ROOT/cli/x86sim" "$@"; }
WAIT=${WAIT:-40}
fails=0
for k in ${want:-$all}; do
	case $k in
		shake) id=func:UIKit.input-shake; send() { xs shake; } ; undo() { :; } ;;
		orientation) id=func:UIKit.input-orientation; send() { xs orientation landscapeLeft >/dev/null; } ; undo() { xs orientation portrait >/dev/null; } ;;
		biometric) id=func:LocalAuthentication.input-biometric; send() { xs biometric enroll; xs biometric match; } ; undo() { xs biometric unenroll; } ;;
		gamepad) id=func:GameController.input-gamepad; send() { xs gamepad press a; } ; undo() { :; } ;;
		memwarn) id=func:UIKit.input-memory-warning; send() { xs memwarn; } ; undo() { :; } ;;
		*) echo "inputs: unknown check $k" >&2; exit 2 ;;
	esac
	OUT=$X86SIM_SCRATCH/apps/sdkcov-$plat-inputs-$k; rm -rf "$OUT"
	SIMCTL_CHILD_SDKCOV_INPUT_WAIT=$WAIT OUT=$OUT "$S/run.sh" "$dev" $build --only "$id" >/dev/null 2>&1 &
	rp=$!; build=--no-build
	# the app needs a few seconds to start and reach the check; the input repeats until the run ends
	timeout 8 tail -f /dev/null
	while kill -0 $rp 2>/dev/null; do send >/dev/null 2>&1; timeout 3 tail -f /dev/null; done
	wait $rp
	undo >/dev/null 2>&1
	r=$(grep -h "X86TEST sdkcov $id " "$OUT"/sdkcov-*.err 2>/dev/null | tail -1)
	echo "${r:-$id: no result (see $OUT)}"
	case $r in *" PASS "*|*" SKIP "*) ;; *) fails=$((fails + 1)) ;; esac
done
exit $fails
