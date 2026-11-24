#!/bin/bash
# x86Sim: build XCTestDemo (app + hosted unit tests + logic tests + UI tests) for testing, as `xcodebuild
# build-for-testing` does, on the Mac ($X86SIM_MAC: Xcode's XCTest can't be linked into an Xcode project's targets on
# Linux), and copy the products (.app, .xctest, the UITests-Runner.app and the .xctestrun) back:
#   tests/apps/XCTestDemo/build.sh [OUT]     (default $X86SIM_SCRATCH/apps/XCTestDemo-products)
# Then: x86sim test <phone> --xctestrun OUT/XCTestDemo_iphonesimulator*.xctestrun  (or run.sh <phone>)
set -euo pipefail
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/cli/lib/config.sh"
MAC=${X86SIM_MAC:?set X86SIM_MAC (ssh host of a Mac with Xcode) in x86sim.env}
OUT=${1:-$X86SIM_SCRATCH/apps/XCTestDemo-products}
rm -rf "$OUT"; mkdir -p "$OUT"
tar cf - -C "$X86SIM_ROOT/tests/apps" --exclude spm XCTestDemo | ssh -o BatchMode=yes "$MAC" 'set -e
	W=$(mktemp -d /tmp/xctestdemo.XXXXXX); trap "rm -rf $W" EXIT; cd $W; tar xf -; cd XCTestDemo
	nice xcodebuild -project XCTestDemo.xcodeproj -scheme XCTestDemo -sdk iphonesimulator \
		-destination "generic/platform=iOS Simulator" -derivedDataPath $W/dd ARCHS=arm64 build-for-testing > $W/build.log 2>&1 ||
		{ tail -40 $W/build.log >&2; exit 1; }
	cd $W/dd/Build/Products && COPYFILE_DISABLE=1 tar cf - .' | tar xf - -C "$OUT" 2>/dev/null
ls "$OUT"/*.xctestrun
