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
