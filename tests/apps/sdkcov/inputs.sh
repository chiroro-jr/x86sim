#!/bin/bash
# x86Sim sdkcov: the host-driven input checks (checks/Inputs.swift) on a running device: each check runs alone (run.sh
# --only) with SDKCOV_INPUT_WAIT set, while this script sends its input every few seconds through the x86sim CLI
# (host/simhid), as Apple's simulator would (DeviceHub's Shake / Rotate / Face ID menus, a game controller).
# Usage: tests/apps/sdkcov/inputs.sh <device> [--no-build] [shake|orientation|biometric|bioitem|gamepad|memwarn|push|pointer|keyboard|
# drag tracking clip ctxmenu swipe sdrag ncontent widget gckey gcmouse lifecycle ...]   (default: all the device's platform has; pointer / keyboard / drag: iPad, checks/More_iPadOS.swift)
# On Apple's simulator the same inputs are: notifyutil -p com.apple.UIKit.SimulatorShake (simctl spawn), devicectl
# device orientation set, notifyutil -s com.apple.BiometricKit.enrollmentChanged 1 + notifyutil -p
# com.apple.BiometricKit_Sim.pearl.match (ref-mac.sh BIOMETRIC=1), an Indigo game controller message (SimulatorKit IndigoHIDMessageForGameControllerEvent) and
# SimDevice simulateMemoryWarning, `simctl push` (push: a remote notification with mutable-content for the notification
# service extension, checks/P10_Extensions.swift); on an iPad, Indigo keyboard (IndigoHIDMessageForKeyboardArbitrary) and touch
# (IndigoHIDMessageForMouseNSEvent, target 0x32) messages; the pointer needs Simulator's pointer capture.
set -u
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/cli/lib/config.sh"
. "$X86SIM_ROOT/cli/lib/pickdevice.sh"
S=$X86SIM_ROOT/tests/apps/sdkcov
dev=${1:?usage: tests/apps/sdkcov/inputs.sh <device> [--no-build] [check...]}; shift
pick_device "$dev" || { echo "inputs: no device $dev" >&2; exit 2; }
export X86SIM_DEVICE
. "$S/devlock.sh"; devlock "$BASH" "$0" "$dev" "$@"   # held for all the checks (their run.sh runs inside it)
build=; want=
for a in "$@"; do case $a in --no-build) build=--no-build ;; *) want="$want $a" ;; esac; done
rt=$(cat "$X86SIM_DEVICE/runtime" 2>/dev/null); plat=${rt%%-*}
case $plat in
	ios) all="shake orientation biometric bioitem gamepad memwarn push tracking clip ctxmenu swipe sdrag ncontent cvmenu pencil locbutton fpauth widget gckey health photopick control routepick"
		case $(cat "$X86SIM_DEVICE/model" 2>/dev/null) in iPad*) all="$all pointer keyboard drag gcmouse" ;; esac ;; xros) all="shake biometric bioitem gamepad memwarn tracking push gckey" ;; tvos) all="gamepad memwarn tracking gckey" ;;
	watchos) all="lifecycle locbutton swipe push" ;;
	*) echo "inputs: no input checks for $plat" >&2; exit 0 ;;
esac
xs() { "$X86SIM_ROOT/cli/x86sim" "$@"; }
name=$(basename "$X86SIM_DEVICE"); name=${name#device-a64-}
WAIT=${WAIT:-40}
ALLOW=${ALLOW:-0.68 0.593}   # the notification prompt's Allow button (screen fractions)
nap() { timeout "$1" tail -f /dev/null; }
# press X Y SECS: one finger down for SECS; stroke X1 Y1 X2 Y2 HOLD: down, HOLD s still, 10 moves to X2 Y2, up
press() { xs raw "touch down $1 $2"; nap "$3"; xs raw "touch up $1 $2"; }
stroke() { local i; xs raw "touch down $1 $2"; [ "$5" = 0 ] || nap "$5"
	for i in 1 2 3 4 5 6 7 8 9 10; do xs raw "touch move $(echo "$1 $2 $3 $4 $i" | awk '{printf "%.3f %.3f", $1 + ($3 - $1) * $5 / 10, $2 + ($4 - $2) * $5 / 10}')"; done
	nap 0.3; xs raw "touch up $3 $4"; }
fails=0
for k in ${want:-$all}; do
	case $k in
		shake) id=func:UIKit.input-shake; send() { xs shake; } ; undo() { :; } ;;
		orientation) id=func:UIKit.input-orientation; send() { xs orientation landscapeLeft >/dev/null; } ; undo() { xs orientation portrait >/dev/null; } ;;
		biometric) id=func:LocalAuthentication.input-biometric; send() { xs biometric enroll; xs biometric match; } ; undo() { xs biometric unenroll; } ;;
		bioitem) id=func:Security.input-biometry-item; send() { xs biometric enroll; xs biometric match; } ; undo() { xs biometric unenroll; } ;;
		gamepad) id=func:GameController.input-gamepad; send() { xs gamepad press a; } ; undo() { :; } ;;
		memwarn) id=func:UIKit.input-memory-warning; send() { xs memwarn; } ; undo() { :; } ;;
		push) id=func:UserNotifications.service-extension-push; send() { echo '{"aps":{"alert":{"title":"sdkcov push","body":"p10"},"mutable-content":1}}' | xs push com.x86sim.test.sdkcov -; } ; undo() { :; } ;;
		# the App Clip launched by the host with _XCAppClipURL (as Xcode runs a clip target), once, after the check has
		# started (it counts launches from its start; the app can take ~25 s to get there)
		clip) id=func:AppClip.input-clip-launch; send() { [ -e "$OUT/clip-sent" ] && return
			f=$(find "$X86SIM_DEVICE"/data/tmp -name 'sdkcov-*.err' -newer "$OUT/run.log" 2>/dev/null | head -1)
			grep -qs "X86TEST sdkcov only " "$f" || return; timeout 5 tail -f /dev/null; touch "$OUT/clip-sent"
			xs launch --env _XCAppClipURL=https://example.com/sdkcov com.x86sim.test.sdkcov.Clip; } ; undo() { xs terminate com.x86sim.test.sdkcov.Clip; } ;;
		# App Tracking Transparency answered ahead: the app's kTCCServiceUserTracking row allowed (as the prompt's Allow
		# writes it; ref-mac.sh TRACKING=1 on the Mac), removed afterwards so a later run starts not determined again
		tracking) id=func:AppTrackingTransparency.input-tracking-granted; send() { sqlite3 "$X86SIM_DEVICE/data/Library/TCC/TCC.db" "insert or replace into access
			(service, client, client_type, auth_value, auth_reason, auth_version, flags) values
			('kTCCServiceUserTracking', 'com.x86sim.test.sdkcov', 0, 2, 2, 1, 0)"; } ; undo() { sqlite3 "$X86SIM_DEVICE/data/Library/TCC/TCC.db" \
			"delete from access where service = 'kTCCServiceUserTracking' and client = 'com.x86sim.test.sdkcov'"; } ;;
		# iPad: the pointer-capture mouse over the check's full-window view; ⌘K on the hardware keyboard (attached at
		# the first key); a long press on the drag source (0.25, 0.5 of the screen) moved onto the drop target (0.75, 0.5)
		pointer) id=func:UIKit.ipad-pointer-hover; send() { xs pointer at 0.5 0.5; xs pointer move 30 20; xs pointer move -30 -20; } ; undo() { xs pointer remove; } ;;
		keyboard) id=func:UIKit.ipad-key-commands; send() { xs raw "key down 227" "key down 14" "key up 14" "key up 227"; } ; undo() { :; } ;;
		drag) id=func:UIKit.ipad-drag-drop; send() {
			xs raw "touch down 0.25 0.5"; timeout 1.2 tail -f /dev/null
			for i in 1 2 3 4 5 6 7 8 9 10; do xs raw "touch move 0.$((25 + i * 5)) 0.5"; done
			timeout 0.5 tail -f /dev/null; xs raw "touch up 0.75 0.5"; } ; undo() { :; } ;;
		# touches (checks/P14_Touch.swift lays its views out at these screen fractions; ref-mac.sh INPUT= sends the same
		# through Indigo): a long press on the SwiftUI context menu view, a full right-to-left swipe on the list row, a
		# long press on the draggable text moved onto the drop destination
		ctxmenu) id=func:SwiftUI.input-context-menu-long-press; send() { press 0.5 0.5 1.5; } ; undo() { :; } ;;
		# (watchOS, P24: a swipe reveals the actions as buttons, a full swipe runs none: the swipe, then a tap on the
		# outer (first) action, as on Apple's simulator: ref-mac.sh watchos INPUT='drag 0.85 0.35 0.1 0.35 0 600;tap 0.81 0.375')
		swipe) id=func:SwiftUI.input-list-swipe-actions; case $plat in
			watchos) send() { stroke 0.85 0.35 0.1 0.35 0; nap 1; press 0.81 0.375 0.08; } ;;
			*) send() { stroke 0.95 0.35 0.05 0.35 0; } ;; esac; undo() { :; } ;;
		# Files opened by the check: Apple's first-launch keyboard tip's Continue (here: the Shared tab), Browse twice (its
		# root), the sdkcov location (the fourth row), the "< sdkcov" breadcrumb back to the app (the check opens Files
		# again). iPad: the sidebar button (shows or hides it: every other round), sdkcov in the sidebar
		fpauth) id=func:FileProviderUI.input-files-authentication-error
			case $(cat "$X86SIM_DEVICE/model" 2>/dev/null) in
			iPad*) send() { press 0.332 0.044 0.08; nap 2.5; press 0.146 0.286 0.08; nap 4; press 0.025 0.012 0.08; } ;;
			*) send() { press 0.5 0.944 0.08; nap 1.5; press 0.714 0.93 0.08; nap 1.5
				press 0.714 0.93 0.08; nap 2; press 0.4 0.453 0.08; nap 4; press 0.06 0.045 0.08; } ;;
			esac; undo() { xs terminate com.apple.DocumentsApp; } ;;
		cvmenu) id=func:UIKit.input-collection-context-menu; send() { press 0.2 0.5 1.5; } ; undo() { :; } ;;
		# (P20) a finger stroke across the PencilKit canvas; a tap on the LocationButton in the middle of the screen (Apple:
		# ref-mac.sh INPUT='drag 0.3 0.5 0.7 0.5 0 500' / INPUT='drag 0.5 0.5 0.5 0.5 100 2')
		pencil) id=func:PencilKit.input-canvas-stroke; send() { stroke 0.3 0.5 0.7 0.5 0; } ; undo() { :; } ;;
		locbutton) id=func:CoreLocationUI.input-location-button-tap; send() { press 0.5 0.5 0.1; } ; undo() { :; } ;;
		sdrag) id=func:SwiftUI.input-transferable-drag-drop; send() { stroke 0.5 0.25 0.5 0.75 1.2; } ; undo() { :; } ;;
		# the notification prompt's Allow tapped (iPhone 17 Pro layout), then a long press on the banner at the top (its middle at 0.10)
		# iPad: nothing (Apple's iPad simulator never shows the prompt; the check asserts the request stays unanswered)
		ncontent) id=func:UserNotificationsUI.input-expand-content-extension
			# the iPad's prompt is centred: Allow at (0.59, 0.546); its banners are higher up
			case $(cat "$X86SIM_DEVICE/model" 2>/dev/null) in iPad*) send() { press 0.59 0.546 0.1; press 0.5 0.06 1.5; } ;; *) send() { press $ALLOW 0.1; press 0.5 0.10 1.5; } ;; esac
			undo() { :; } ;;
		# (P23) the sdkcov widget placed on the home screen before the app starts (pre): a long press on an empty spot, the
		# edit menu's Add Widget, the gallery searched for "sdkcov", its Add Widget, Done (iPhone 17 Pro layout; Apple:
		# ref-mac.sh PRE= with the same touches through Indigo)
		widget) id=func:WidgetKit.input-placed-widget-timeline; pre() { xs home; nap 2; press 0.5 0.55 2; nap 2; press 0.17 0.037 0.1; nap 2
			press 0.33 0.107 0.1; nap 4; press 0.5 0.2 0.1; nap 2; xs type sdkcov; nap 3; press 0.3 0.29 0.1; nap 5
			press 0.5 0.905 0.1; nap 4; press 0.83 0.037 0.1; nap 2; } ; send() { :; } ; undo() { :; } ;;
		# (P23, watchOS) once the check has started: the Digital Crown pressed (the watch face), 4 s later sdkcov opened again from the host
		lifecycle) id=func:WatchKit.input-lifecycle-round-trip; send() { [ -e "$OUT/lc-sent" ] && return
			f=$(find "$X86SIM_DEVICE"/data/tmp -name 'sdkcov-*.err' -newer "$OUT/run.log" 2>/dev/null | head -1)
			grep -qs "X86TEST sdkcov only " "$f" || return; nap 6; touch "$OUT/lc-sent"
			xs home; nap 4; xs app com.x86sim.test.sdkcov; } ; undo() { :; } ;;
		# (P23) the K key (HID usage 14) on the hardware keyboard: GCKeyboard (Apple: ref-mac.sh INPUT='key 14')
		gckey) id=func:GameController.input-keyboard-key; send() { xs raw "key down 14" "key up 14"; } ; undo() { :; } ;;
		# (P24) the iPad's pointer-capture mouse moved: GCMouse (Apple: ref-mac.sh ipad INPUT='pointer 30 20 5')
		gcmouse) id=func:GameController.input-mouse-move; send() { xs pointer at 0.5 0.5; xs pointer move 30 20; xs pointer move -30 -20; } ; undo() { xs pointer remove; } ;;
		# (P25) the Health sheet once the check has started: Select All, scrolled to Continue, "Past 30 Days and Future
		# Data", Allow (iPhone 17 Pro layout; Apple's fresh simulator shows the sheet ~80 s in, so once: ref-mac.sh WAIT=150 INPUT='sleep 85000;tap 0.28 0.491;sleep 1500;drag 0.5 0.85 0.5 0.35 0 400;
		# sleep 1500;tap 0.5 0.778;sleep 2500;tap 0.5 0.56;sleep 1000;tap 0.5 0.856;sleep 200000'). Answered once per device: later
		# runs find the access granted
		health) id=func:HealthKit.input-authorization-round-trip; send() { [ -e "$OUT/health-sent" ] && return
			f=$(find "$X86SIM_DEVICE"/data/tmp -name 'sdkcov-*.err' -newer "$OUT/run.log" 2>/dev/null | head -1)
			grep -qs "X86TEST sdkcov only " "$f" || return; nap 8; touch "$OUT/health-sent"
			press 0.28 0.491 0.08; nap 1.5; stroke 0.5 0.85 0.5 0.35 0; nap 1.5; press 0.5 0.778 0.08; nap 2.5
			press 0.5 0.56 0.08; nap 1; press 0.5 0.856 0.08; } ; undo() { :; } ;;
		# (P25) the photo picker's first grid cell (selection limit 1: picked at once; Apple: ref-mac.sh INPUT='tap 0.17 0.22')
		photopick) id=func:PhotosUI.input-picker-selection; send() { press 0.17 0.22 0.08; } ; undo() { :; } ;;
		# (P25) the sdkcov control placed in Control Center before the app starts (pre: a swipe down at the top right, +,
		# Add a Control, search "sdkcov", the control, two taps on an empty spot), then, while the check waits, Control
		# Center opened, the control (top left) tapped, closed (iPhone 17 Pro layout; Apple: ref-mac.sh PRE= / INPUT=)
		control) id=func:WidgetKit.input-placed-control-perform; pre() { xs home; nap 2; stroke 0.9 0.005 0.9 0.4 0; nap 2; press 0.13 0.043 0.08; nap 2
			press 0.5 0.916 0.08; nap 4; press 0.5 0.135 0.08; nap 2; xs type sdkcov; nap 3; press 0.143 0.302 0.08; nap 3
			press 0.5 0.75 0.08; nap 2; press 0.5 0.75 0.08; nap 2; }
			send() { stroke 0.9 0.005 0.9 0.4 0; nap 2; press 0.18 0.14 0.08; nap 2; press 0.5 0.75 0.08; } ; undo() { :; } ;;
		# (P25) the AVRoutePickerView in the middle of the screen tapped (Apple: ref-mac.sh INPUT='tap 0.5 0.5')
		routepick) id=func:AVRouting.input-route-picker-discovery; send() { press 0.5 0.5 0.08; } ; undo() { :; } ;;
		*) echo "inputs: unknown check $k" >&2; exit 2 ;;
	esac
	# per device: two devices of one platform don't share (and delete) each other's OUT
	OUT=$X86SIM_SCRATCH/apps/sdkcov-$plat-$name-inputs-$k; rm -rf "$OUT"; mkdir -p "$OUT"
	# a check's one-time input before the app starts (pre), with the app built and installed first
	if [ "$(type -t pre)" = function ]; then
		[ -z "$build" ] && { nice "$S/build.sh" "$plat" >"$OUT/build.log" 2>&1 && xs install "$X86SIM_DEVICE" "${SDKCOV_APPS:-$X86SIM_SCRATCH/apps}/sdkcov-$plat.app" >>"$OUT/build.log" 2>&1 || { echo "$id: build / install failed"; fails=$((fails + 1)); continue; }; build=--no-build; }
		xs terminate com.x86sim.test.sdkcov >/dev/null 2>&1; pre >/dev/null 2>&1; unset -f pre
	fi
	SIMCTL_CHILD_SDKCOV_INPUT_WAIT=$WAIT OUT=$OUT "$S/run.sh" "$dev" $build --only "$id" >"$OUT/run.log" 2>&1 &
	rp=$!; build=--no-build
	# the app needs a few seconds to start and reach the check; the input repeats until the run ends
	timeout 8 tail -f /dev/null
	while kill -0 $rp 2>/dev/null; do send >/dev/null 2>&1; timeout 3 tail -f /dev/null; done
	wait $rp
	undo >/dev/null 2>&1
	r=$(grep -h "X86TEST sdkcov $id " "$OUT"/sdkcov-*.err 2>/dev/null | tail -1)
	echo "${r:-$id: no result (see $OUT, run.log: $(grep -v X86TEST "$OUT/run.log" 2>/dev/null | tail -1))}"
	case $r in *" PASS "*|*" SKIP "*) ;; *) fails=$((fails + 1)) ;; esac
done
exit $fails
