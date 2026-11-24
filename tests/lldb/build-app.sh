#!/bin/bash
# x86Sim: builds tests/lldb/dbgapp.m into $X86SIM_SCRATCH/apps/dbgapp.app (+ dbgapp.app.dSYM) for the arm64 iOS
# Simulator, with debug info, on Linux (build/linux-env.sh: clang + ld64.lld + dsymutil) or the Mac.
set -e
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
. "$X86SIM_ROOT/build/mac-env.sh"
OUT=$X86SIM_SCRATCH/apps; mkdir -p "$OUT"
S=$X86SIM_ROOT/tests/lldb/dbgapp.m
tar cf - -C "$(dirname "$S")" dbgapp.m | mac "set -e; W=\$(mktemp -d /tmp/x86app.XXXXXX); cd \$W; tar xf -
	APP=dbgapp.app; mkdir -p \$APP
	$SIMCC -g -O0 -fobjc-arc -framework UIKit -framework Foundation -c -o dbgapp.o dbgapp.m
	$SIMCC -g -fobjc-arc -framework UIKit -framework Foundation -o \$APP/dbgapp dbgapp.o
	dsymutil -o dbgapp.app.dSYM \$APP/dbgapp
	cat > \$APP/Info.plist <<PL
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>CFBundleIdentifier</key><string>com.x86sim.test.dbgapp</string>
<key>CFBundleName</key><string>dbgapp</string><key>CFBundleExecutable</key><string>dbgapp</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>DTPlatformName</key><string>iphonesimulator</string><key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array><key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PL
	codesign -f -s - \$APP >&2
	tar cf - \$APP dbgapp.app.dSYM; cd /; rm -rf \$W" | (cd "$OUT" && rm -rf dbgapp.app dbgapp.app.dSYM && tar xf -)
ls -d "$OUT/dbgapp.app" "$OUT/dbgapp.app.dSYM"
