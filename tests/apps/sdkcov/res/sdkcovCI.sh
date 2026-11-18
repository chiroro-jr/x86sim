#!/bin/bash
# makes res/sdkcovCI-<platform>.metallib from res/sdkcovCI.metal on the Mac ($X86SIM_MAC, over ssh; needs Xcode's Metal
# Toolchain there): stitchable Core Image kernels (linked against CoreImage; -fcikernel is the older non-stitchable
# form and leaves these out), one library per simulator platform
set -e
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../../.." && pwd)}
. "$X86SIM_ROOT/cli/lib/config.sh"
R=$X86SIM_ROOT/tests/apps/sdkcov/res
for p in ios:iphonesimulator tvos:appletvsimulator xros:xrsimulator; do
	ssh "$X86SIM_MAC" "set -e; W=\$(mktemp -d /tmp/sdkcovCI.XXXXXX); trap 'rm -rf \$W' EXIT; cat > \$W/k.metal
		xcrun -sdk ${p#*:} metal \$W/k.metal -o \$W/k.metallib -framework CoreImage >&2
		cat \$W/k.metallib" < "$R/sdkcovCI.metal" > "$R/sdkcovCI-${p%%:*}.metallib"
	echo "sdkcovCI-${p%%:*}.metallib $(stat -c %s "$R/sdkcovCI-${p%%:*}.metallib") B"
done
