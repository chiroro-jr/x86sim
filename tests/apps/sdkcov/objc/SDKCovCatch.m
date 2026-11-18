// sdkcov: see SDKCovCatch.h
#import "SDKCovCatch.h"

NSArray<NSString *> *SDKCovCatch(void (^block)(void)) {
	@try {
		block();
	} @catch (NSException *e) {
		return @[e.name, e.reason ?: @""];
	}
	return nil;
}

#include <TargetConditionals.h>
#if TARGET_OS_TV
// SwiftUI view modifiers with availability (contextMenu, popover) emit calls to compiler-rt's
// __isPlatformVersionAtLeast, which this toolchain doesn't link for tvOS: the app's deployment target (27.0) is the
// runtime it runs on, so every check answers yes
int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor) {
	(void)platform; return major <= 27 ? 1 : 0;
}
#endif
