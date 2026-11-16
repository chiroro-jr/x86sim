// sdkcov: the one Objective-C piece of the app (build.sh compiles SDKCovCatch.m with clang for the simulator target and
// imports this header into the Swift module). Swift cannot catch an Objective-C exception; some SDK calls answer with
// one in the simulator (SafetyKit without its entitlement, ...), and a check asserts that answer.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// runs block; returns @[name, reason] of the NSException it raised, nil when it returned normally
NSArray<NSString *> * _Nullable SDKCovCatch(NS_NOESCAPE void (^block)(void));
NS_ASSUME_NONNULL_END
