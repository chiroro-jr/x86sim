#!/bin/bash
# x86Sim: builds the x86sim profile test targets for the arm64 iOS Simulator (Linux clang + ld64.lld, or the Mac):
# $X86SIM_SCRATCH/apps/profapp.app (tests/profile/profapp.m) and $X86SIM_SCRATCH/apps/profhot.sim (profhot.c,
# a command-line binary for tests/arm64/run.sh). Frame pointers as Apple's toolchain always keeps them on arm64.
set -e
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
. "$X86SIM_ROOT/build/mac-env.sh"
OUT=$X86SIM_SCRATCH/apps; mkdir -p "$OUT"
tar cf - -C "$X86SIM_ROOT/tests/profile" profwork.h profhot.c profapp.m | mac "set -e; W=\$(mktemp -d \${TMPDIR:-/tmp}/x86prof.XXXXXX); cd \$W; tar xf -
	APP=profapp.app; mkdir -p \$APP
	$SIMCC -O1 -fobjc-arc -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation -o \$APP/profapp profapp.m
	$SIMCC -O1 -o profhot.sim profhot.c
	cat > \$APP/Info.plist <<PL
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>CFBundleIdentifier</key><string>com.x86sim.test.profapp</string>
<key>CFBundleName</key><string>profapp</string><key>CFBundleExecutable</key><string>profapp</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>DTPlatformName</key><string>iphonesimulator</string><key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array><key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PL
	codesign -f -s - \$APP >&2
	codesign -f -s - profhot.sim >&2
	tar cf - \$APP profhot.sim; cd /; rm -rf \$W" | (cd "$OUT" && rm -rf profapp.app profhot.sim && tar xf -)
ls -d "$OUT/profapp.app" "$OUT/profhot.sim"
