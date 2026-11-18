// indigo <udid> CMD...: host input into a booted Apple simulator through SimulatorKit's Indigo HID (as Simulator.app)
//   key <usage> [modusage]       a key press (HID page 7 usage), with a modifier held (227 = left command)
//   touch down|move|up <nx> <ny> one touch event, 0..1 of the screen
//   tap <nx> <ny>                a tap (down, 80 ms, up: two `touch` runs take a long press on Apple)
//   sleep <ms>                   just wait (between the commands of one INPUT sequence)
//   press <nx> <ny> <ms>          touch down, held still for ms, up (no moves: inputs.sh press)
//   drag <nx1> <ny1> <nx2> <ny2> <holdms> <ms>   touch down, hold, move, up (a drag and drop)
//   mouse create|remove          the pointer-capture mouse service
//   msg <name>                   just build+send a no-arg message (IndigoHIDMessageToCreatePointerService...)
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventRef IOHIDEventCreateRelativePointerEvent(CFAllocatorRef, uint64_t, double, double, double, uint32_t, uint32_t);
extern IOHIDEventRef IOHIDEventCreateButtonEvent(CFAllocatorRef, uint64_t, uint32_t, CFIndex, uint32_t, uint32_t);
extern void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, uint32_t);
extern uint32_t IOHIDEventGetType(IOHIDEventRef);
static id client; static void *sk;
static void sendm(void *msg) {
	if (!msg) { fprintf(stderr, "nil message\n"); return; }
	dispatch_semaphore_t s = dispatch_semaphore_create(0);
	((void (*)(id, SEL, void *, BOOL, id, id))objc_msgSend)(client, sel_registerName("sendWithMessage:freeWhenDone:completionQueue:completion:"), msg, YES, dispatch_get_global_queue(0, 0), ^(NSError *err) { if (err) fprintf(stderr, "send: %s\n", err.description.UTF8String); dispatch_semaphore_signal(s); });
	dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}
static void key(int u, int dir) { void *(*f)(int, int) = dlsym(sk, "IndigoHIDMessageForKeyboardArbitrary"); sendm(f(u, dir)); }
static int g_edge = 0;
static void touch(int type, double x, double y) {
	void *(*f)(CGPoint *, CGPoint *, int, NSEventType, CGSize, int) = dlsym(sk, "IndigoHIDMessageForMouseNSEvent");
	CGPoint p = CGPointMake(x, y);
	sendm(f(&p, NULL, 0x32, (NSEventType)type, CGSizeMake(1, 1), g_edge));
}
int main(int argc, char **argv) { @autoreleasepool {
	dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
	sk = dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW);
	if (!sk || argc < 3) { fprintf(stderr, "usage / %s\n", dlerror()); return 1; }
	Class hc = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
	NSString *dev = [NSString stringWithUTF8String:argv[1]];
	id ctx = ((id (*)(id, SEL, id, id *))objc_msgSend)(NSClassFromString(@"SimServiceContext"), sel_registerName("sharedServiceContextForDeveloperDir:error:"), @"/Applications/Xcode.app/Contents/Developer", nil);
	id set = ((id (*)(id, SEL, id *))objc_msgSend)(ctx, sel_registerName("defaultDeviceSetWithError:"), nil);
	id d = nil; for (id x in [set valueForKey:@"devices"]) if ([[[x valueForKey:@"UDID"] UUIDString] isEqual:dev]) d = x;
	if (!d) { fprintf(stderr, "no device %s\n", argv[1]); return 1; }
	NSError *e = nil;
	client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([hc alloc], sel_registerName("initWithDevice:error:"), d, &e);
	if (!client) { fprintf(stderr, "hid client: %s\n", e.description.UTF8String); return 1; }
	usleep(300000);
	const char *c = argv[2];
	if (!strcmp(c, "key")) {
		int u = atoi(argv[3]), m = argc > 4 ? atoi(argv[4]) : 0;
		if (m) { key(m, 1); usleep(50000); }
		key(u, 1); usleep(80000); key(u, 2);
		if (m) { usleep(50000); key(m, 2); }
	} else if (!strcmp(c, "touch")) {
		int t = !strcmp(argv[3], "down") ? NSEventTypeLeftMouseDown : !strcmp(argv[3], "up") ? NSEventTypeLeftMouseUp : NSEventTypeLeftMouseDragged;
		touch(t, atof(argv[4]), atof(argv[5]));
	} else if (!strcmp(c, "tap")) {
		touch(NSEventTypeLeftMouseDown, atof(argv[3]), atof(argv[4])); usleep(80000); touch(NSEventTypeLeftMouseUp, atof(argv[3]), atof(argv[4]));
	} else if (!strcmp(c, "sleep")) {
		usleep(atoi(argv[3]) * 1000);
	} else if (!strcmp(c, "press")) {
		touch(NSEventTypeLeftMouseDown, atof(argv[3]), atof(argv[4])); usleep(atoi(argv[5]) * 1000); touch(NSEventTypeLeftMouseUp, atof(argv[3]), atof(argv[4]));
	} else if (!strcmp(c, "drag")) {
		if (argc > 9) g_edge = atoi(argv[9]);
		double x1 = atof(argv[3]), y1 = atof(argv[4]), x2 = atof(argv[5]), y2 = atof(argv[6]); int hold = atoi(argv[7]), ms = atoi(argv[8]);
		touch(NSEventTypeLeftMouseDown, x1, y1);
		for (int i = 0; i < hold / 50; i++) { usleep(50000); touch(NSEventTypeLeftMouseDragged, x1 + 0.001 * (i & 1), y1); }
		int n = ms / 16 < 2 ? 2 : ms / 16;
		for (int i = 1; i <= n; i++) { usleep(16000); touch(NSEventTypeLeftMouseDragged, x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n); }
		usleep(300000); touch(NSEventTypeLeftMouseUp, x2, y2);
	} else if (!strcmp(c, "mouse")) {   // mouse <target> <nseventtype> <nx> <ny>
		void *(*f)(CGPoint *, CGPoint *, int, NSEventType, CGSize, int) = dlsym(sk, "IndigoHIDMessageForMouseNSEvent");
		CGPoint p = CGPointMake(atof(argv[5]), atof(argv[6]));
		void *m = f(&p, NULL, (int)strtol(argv[3], 0, 0), (NSEventType)atoi(argv[4]), CGSizeMake(1, 1), 0);
		printf("msg %p\n", m); sendm(m);
	} else if (!strcmp(c, "pointer")) {   // pointer <dx> <dy> <steps> [child]
		void *(*f)(IOHIDEventRef, int) = dlsym(sk, "IndigoHIDMessageForPointerEventFromHIDEventRef");
		for (int i = 0; i < atoi(argv[5]); i++) {
			uint64_t ts = mach_absolute_time();
			IOHIDEventRef e = IOHIDEventCreateRelativePointerEvent(NULL, ts, atof(argv[3]), atof(argv[4]), 0, 0, 0);
			if (argc > 6) IOHIDEventAppendEvent(e, IOHIDEventCreateButtonEvent(NULL, ts, 0, 1, 0, 0), 0);
			void *m = f(e, 0); if (!i) printf("type %u msg %p\n", IOHIDEventGetType(e), m);
			sendm(m); usleep(16000);
		}
	} else if (!strcmp(c, "home")) {
		void *(*btn)(int, int, int) = dlsym(sk, "IndigoHIDMessageForButton");
		sendm(btn(0, 1, 0x33)); usleep(100000); sendm(btn(0, 2, 0x33));
	} else if (!strcmp(c, "msg")) {
		void *(*f)(void) = dlsym(sk, argv[3]); if (!f) { fprintf(stderr, "no %s\n", argv[3]); return 1; } sendm(f());
	} else { fprintf(stderr, "unknown %s\n", c); return 1; }
	usleep(100000);
	printf("ok\n");
	return 0;
} }
