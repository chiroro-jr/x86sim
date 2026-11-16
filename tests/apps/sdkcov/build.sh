#!/bin/bash
# x86Sim sdkcov: build the SDK coverage app for each platform's arm64 simulator with swiftc (no Xcode project) into
# $X86SIM_SCRATCH/apps/sdkcov-<platform>.app (bundle id com.x86sim.test.sdkcov on all four).
# Usage: tests/apps/sdkcov/build.sh [ios] [tvos] [watchos] [xros]   (default: all four)
# Linux (build/linux-env.sh) or the Mac (X86SIM_BUILD=mac, over ssh), as tests/apps/build.sh.
# App extensions (sources in ext/, module sdkcov each, App Group group.com.x86sim.test.sdkcov): sdkcovWidget.appex
# (PlugIns/, WidgetKit: iOS, watchOS, visionOS), sdkcovFileProvider.appex (PlugIns/, File Provider: iOS, visionOS) and
# sdkcovExt.appex (Extensions/, ExtensionKit: iOS only) bound to the extension point the app defines in
# Extensions/sdkcov.appexpt (the file Xcode's exutil extract-extension-points makes from an AppExtensionPoint
# definition), sdkcovDownloader.appex (Extensions/, Background Assets: iOS, tvOS, visionOS; AssetPackManager traps in an
# app with BAAppGroupID and no downloader extension). checks/P3_Extensions.swift drives them.
set -e
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/build/mac-env.sh"
# SDKCOV_APPS: where the built .app goes (default $X86SIM_SCRATCH/apps); a private one lets parallel work (e.g. a git
# worktree per agent) build without replacing each other's app. run.sh / ref-mac.sh / inputs.sh read the same variable.
A=$X86SIM_ROOT/tests/apps; S=$A/sdkcov; OUT=${SDKCOV_APPS:-$X86SIM_SCRATCH/apps}; mkdir -p "$OUT"
# a bundle's Info.plist: plist_bundle FILE BUNDLE-ID EXECUTABLE PACKAGE-TYPE EXTRA-KEYS (the platform keys from the loop)
plist_bundle() {
	cat > "$1" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleName</key><string>$3</string><key>CFBundleDisplayName</key><string>$3</string>
<key>CFBundleExecutable</key><string>$3</string><key>CFBundlePackageType</key><string>$4</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>$plat</string></array>
<key>DTPlatformName</key><string>$sdk</string><key>MinimumOSVersion</key><string>27.0</string>
<key>UIDeviceFamily</key><array>$fam</array>
$5
</dict></plist>
PL
}
# an extension's entitlements (__TEXT,__entitlements, as for the app): its application id + the app's App Group
ents_ext() {
	cat > "$1" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>application-identifier</key><string>$2</string>
	<key>com.apple.security.get-task-allow</key><true/>
	<key>com.apple.security.application-groups</key><array><string>group.com.x86sim.test.sdkcov</string></array>
</dict></plist>
PL
}
BID=com.x86sim.test.sdkcov
# Background Assets (iOS, tvOS, visionOS): the App Group shared with the downloader extension (ext/Downloader.swift),
# Apple-hosted (managed) asset packs, and the initial download restrictions (the framework exits the app, "BUG IN
# CLIENT OF BackgroundAssets", when an asset-pack call finds no BAInitialDownloadRestrictions)
ba='
<key>BAHasManagedAssetPacks</key><true/><key>BAUsesAppleHosting</key><true/>
<key>BAInitialDownloadRestrictions</key><dict><key>BADownloadAllowance</key><integer>1048576</integer><key>BAEssentialDownloadAllowance</key><integer>1048576</integer><key>BADownloadDomainAllowList</key><array><string>example.com</string></array></dict>'
# NSApplicationServices (iOS, tvOS): the application service DeviceDiscoveryUI's picker browses for (its view aborts the
# app without an entry for the service, "Missing TCC info for browse")
appsvc='
<key>NSApplicationServices</key><dict><key>Browses</key><array><dict><key>NSApplicationServiceIdentifier</key><string>sdkcov</string><key>NSApplicationServiceUsageDescription</key><string>sdkcov checks the device picker</string></dict></array></dict>'
for p in ${*:-ios tvos watchos xros}; do
	multi='<false/>'
	# the extensions built for this platform (ext/*.swift, see the header)
	exts=
	case $p in
	# iPhone and iPad; on iPad all four orientations (iPad multitasking: Split View, Slide Over, Stage Manager windows need
	# them) and more than one scene (More_iPadOS.swift's multiple-window checks; one scene on iPhone either way)
	# NSSupportsLiveActivities: ActivityKit's Activity.request (refused without it); NSAlarmKitUsageDescription: AlarmKit's
	# authorization request (an app without it is refused); UIBackgroundModes voip: PushKit VoIP pushes.
	# NSAccessorySetupKitSupports (Bluetooth): AccessorySetupKit's session traps without it. Apple's iOS 27.2 simulator never
	# activates an ASAccessorySession (no activated event; deviceaccessd "GetDevices failed ... ENOENT") and the app dies
	# (SIGSEGV in AccessorySetupKit) when it invalidates the session, so func:AccessorySetupKit.session-activate keeps it
	ios) sdk=iphonesimulator; tgt=arm64-apple-ios27.0-simulator; plat=iPhoneSimulator; fam='<integer>1</integer><integer>2</integer>'; multi='<true/>'
		exts='widget fileprovider extkit downloader'
		extra='<key>UISupportedInterfaceOrientations~ipad</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
<key>NSSupportsLiveActivities</key><true/>
<key>NSHealthUpdateUsageDescription</key><string>sdkcov checks HealthKit writes</string>
<key>NSAlarmKitUsageDescription</key><string>sdkcov checks AlarmKit</string>
<key>UIBackgroundModes</key><array><string>voip</string></array>
<key>NSAccessorySetupKitSupports</key><array><string>Bluetooth</string></array>
<key>BAAppGroupID</key><string>group.com.x86sim.test.sdkcov</string>'"$ba$appsvc" ;;
	tvos) sdk=appletvsimulator; tgt=arm64-apple-tvos27.0-simulator; plat=AppleTVSimulator; fam='<integer>3</integer>'; exts=downloader  # no extkit: as watchOS below
		extra='<key>BAAppGroupID</key><string>group.com.x86sim.test.sdkcov</string>'"$ba$appsvc" ;;
	# a standalone (watch-only) app: watchOS installs and runs it without an iPhone companion
	watchos) sdk=watchsimulator; tgt=arm64-apple-watchos27.0-simulator; plat=WatchSimulator; fam='<integer>4</integer>'
		# no ExtensionKit extension (tvOS, visionOS neither): their installd refuses an appex whose EXExtensionPointIdentifier is not one of
		# Apple's ("does not specify an Apple extension point"), so the app defines no extension point there either
		exts='widget'
		# WKBackgroundModes self-care: WKExtendedRuntimeSession runs (refused with error 7 without it); the Health usage
		# strings: the workout check may ask for Health access (an app without them is killed when it asks)
		extra='<key>WKApplication</key><true/><key>WKWatchOnly</key><true/><key>WKBackgroundModes</key><array><string>self-care</string></array><key>NSHealthShareUsageDescription</key><string>sdkcov reads workouts it saved</string><key>NSHealthUpdateUsageDescription</key><string>sdkcov saves a test workout</string>'
		# Xcode's watch SDK: the one in sdks/WatchSimulator.sdk is sim-sdk.py's substitute (macOS headers, no WatchKit)
		[ "$X86SIM_BUILD" = linux ] && export SDK_WATCHOS=$X86SIM_ROOT/sdks/WatchSimulator-xcode.sdk ;;
	# Xcode's visionOS SDK: sdks/XRSimulator.sdk is sim-sdk.py's substitute (iOS's framework list, not visionOS's)
	# NSWorldSensingUsageDescription / NSHandsTrackingUsageDescription: ARKit's plane detection / hand tracking
	# authorization (an app asking without them is killed)
	xros) sdk=xrsimulator; tgt=arm64-apple-xros27.0-simulator; plat=XRSimulator; fam='<integer>7</integer>'; multi='<true/>'  # volume + immersive spaces
		exts='widget fileprovider downloader'  # no extkit: as watchOS below
		extra='<key>NSWorldSensingUsageDescription</key><string>sdkcov checks ARKit plane detection</string>
<key>NSHandsTrackingUsageDescription</key><string>sdkcov checks ARKit hand tracking</string>
<key>NSHealthUpdateUsageDescription</key><string>sdkcov checks HealthKit writes</string>
<key>BAAppGroupID</key><string>group.com.x86sim.test.sdkcov</string>'"$ba"
		[ "$X86SIM_BUILD" = linux ] && export SDK_XROS=$X86SIM_ROOT/sdks/XRSimulator-xcode.sdk ;;
	*) echo "sdkcov build: unknown platform $p (ios, tvos, watchos, xros)" >&2; exit 2 ;;
	esac
	[ -f "$S/manifest-$p.json" ] || { echo "sdkcov build: no manifest-$p.json (gen-manifest.py $p)" >&2; exit 1; }
	echo "== sdkcov $p" >&2
	# the generated plists (app, extensions, extension point, entitlements) go to the build in gen/
	G=$(mktemp -d /tmp/sdkcov-gen.XXXXXX); mkdir -p "$G/gen"
	plist_bundle "$G/gen/app.plist" $BID sdkcov APPL "<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key>$multi</dict>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
<key>BGTaskSchedulerPermittedIdentifiers</key><array><string>com.x86sim.test.sdkcov.refresh</string></array>
<key>NSUserActivityTypes</key><array><string>com.x86sim.test.sdkcov.activity</string></array>
<key>NSLocationWhenInUseUsageDescription</key><string>sdkcov checks Core Location</string>
<key>NSContactsUsageDescription</key><string>sdkcov checks Contacts</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>sdkcov checks EventKit</string>
<key>NSPhotoLibraryUsageDescription</key><string>sdkcov checks Photos</string>
<key>NSMicrophoneUsageDescription</key><string>sdkcov checks audio input</string>
<key>NSSpeechRecognitionUsageDescription</key><string>sdkcov checks Speech</string>
<key>NSHealthShareUsageDescription</key><string>sdkcov checks HealthKit</string>
<key>NSHomeKitUsageDescription</key><string>sdkcov checks HomeKit</string>
<key>NSMotionUsageDescription</key><string>sdkcov checks Core Motion</string>
<key>NSFaceIDUsageDescription</key><string>sdkcov checks biometrics</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>sdkcov checks Core Bluetooth</string>
<key>NSLocalNetworkUsageDescription</key><string>sdkcov checks Network on loopback</string>
<key>NSAppleMusicUsageDescription</key><string>sdkcov checks the media library and Apple Music</string>
<key>NSVideoSubscriberAccountUsageDescription</key><string>sdkcov checks the TV provider account</string>
<key>NSBonjourServices</key><array><string>_sdkcov._tcp</string></array>
$extra"
	# the watch's NSHealthShareUsageDescription is in $extra: one copy (plutil rejects a duplicate key)
	[ $p = watchos ] && python3 -I - "$G/gen/app.plist" <<'PY'
import sys, re
s = open(sys.argv[1]).read()
k = '<key>NSHealthShareUsageDescription</key><string>sdkcov checks HealthKit</string>\n'
open(sys.argv[1], 'w').write(s.replace(k, '', 1))
PY
	for e in $exts; do case $e in
		widget) plist_bundle "$G/gen/widget.plist" $BID.widget sdkcovWidget 'XPC!' '<key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>'
			ents_ext "$G/gen/widget.entitlements" $BID.widget ;;
		fileprovider) plist_bundle "$G/gen/fileprovider.plist" $BID.fileprovider sdkcovFileProvider 'XPC!' '<key>NSExtension</key><dict>
<key>NSExtensionPointIdentifier</key><string>com.apple.fileprovider-nonui</string>
<key>NSExtensionPrincipalClass</key><string>SDKCovFileProvider</string>
<key>NSExtensionFileProviderSupportsEnumeration</key><true/>
<key>NSExtensionFileProviderDocumentGroup</key><string>group.com.x86sim.test.sdkcov</string></dict>'
			ents_ext "$G/gen/fileprovider.entitlements" $BID.fileprovider ;;
		downloader) plist_bundle "$G/gen/downloader.plist" $BID.downloader sdkcovDownloader 'XPC!' '<key>EXAppExtensionAttributes</key><dict><key>EXExtensionPointIdentifier</key><string>com.apple.background-asset-downloader-extension</string></dict>'
			ents_ext "$G/gen/downloader.entitlements" $BID.downloader ;;
		extkit) plist_bundle "$G/gen/extkit.plist" $BID.ext sdkcovExt 'XPC!' '<key>EXAppExtensionAttributes</key><dict><key>EXExtensionPointIdentifier</key><string>com.x86sim.test.sdkcov.sdkcov-ext</string></dict>'
			ents_ext "$G/gen/extkit.entitlements" $BID.ext
			# the extension point (exutil's output for AppExtensionPoint.Definition { Name("sdkcov-ext"); UserInterface() }):
			# a user interface (an EXHostViewController scene) on iOS only (UserInterface is iOS / macOS API)
			ui='<false/>'; [ $p = ios ] && ui='<true/>'
			cat > "$G/gen/sdkcov.appexpt" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.x86sim.test.sdkcov.sdkcov-ext</key><dict>
		<key>EXExtensionPointName</key><string>sdkcov-ext</string>
		<key>EXPresentsUserInterface</key>$ui
		<key>EXRequiresEnhancedSecurity</key><false/>
	</dict>
	<key>EXVersion</key><integer>2</integer>
</dict></plist>
PL
			;;
	esac; done
	tar cf - -C "$A" common.swift sdkcov -C "$G" gen | mac "set -e; W=\$(mktemp -d /tmp/sdkcov.XXXXXX); cd \$W; tar xf -
		APP=sdkcov-$p.app; mkdir -p \$APP
		nice xcrun -sdk $sdk swiftc -target $tgt -Onone -parse-as-library -module-name sdkcov \
			-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker sdkcov/sdkcov.entitlements \
			-o \$APP/sdkcov common.swift sdkcov/*.swift sdkcov/checks/*.swift 2>&1 >&2 | grep -v 'directory not found for option -L' >&2 || true
		test -x \$APP/sdkcov
		cp sdkcov/manifest-$p.json \$APP/manifest.json
		cp gen/app.plist \$APP/Info.plist
		# extensions: ext NAME DIR SOURCE. The entry point is Foundation's _NSExtensionMain, as Xcode links every
		# extension (ExtensionKit's and WidgetKit's @main types are found and run from there: entered through their own
		# main, ExtensionFoundation traps on its unset _EXRunningExtension)
		ext() { n=\$1 d=\$2 src=\$3; shift 3; X=\$APP/\$d/sdkcov\$n.appex
			case \$n in Widget) g=widget ;; FileProvider) g=fileprovider ;; Ext) g=extkit ;; Downloader) g=downloader ;; esac
			mkdir -p \$X
			nice xcrun -sdk $sdk swiftc -target $tgt -Onone -parse-as-library -application-extension -module-name sdkcov \
				-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker gen/\$g.entitlements -Xlinker -e -Xlinker _NSExtensionMain \
				-o \$X/sdkcov\$n sdkcov/ext/Marks.swift sdkcov/ext/\$src 2>&1 >&2 | grep -v 'directory not found for option -L' >&2 || true
			test -x \$X/sdkcov\$n
			cp gen/\$g.plist \$X/Info.plist
			codesign -f -s - --entitlements sdkcov/sign.entitlements \$X >&2
		}
		for e in $exts; do case \$e in
			widget) ext Widget PlugIns Widget.swift ;;
			fileprovider) ext FileProvider PlugIns FileProvider.swift ;;
			extkit) ext Ext Extensions ExtKit.swift; cp gen/sdkcov.appexpt \$APP/Extensions/ ;;
			downloader) ext Downloader Extensions Downloader.swift ;;
		esac; done
		codesign -f -s - --entitlements sdkcov/sign.entitlements \$APP >&2
		tar cf - \$APP; cd /; rm -rf \$W" | (cd "$OUT" && rm -rf "sdkcov-$p.app" && tar xf -)
	rm -rf "$G"
	ls -d "$OUT/sdkcov-$p.app"
done
