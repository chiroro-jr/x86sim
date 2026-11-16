// x86Sim: the Mac end of the FoundationModels relay (host/mmhost/mmhost.c, linux/fmrelay/fmrelay.py). A user-level
// process that linux/fmrelay/fmrelay.py runs over ssh, once per simulator connection, building it first on the Mac
// (clang from the Command Line Tools) into ~/Library/Caches/x86sim-fmrelay/. It opens the Mac's own
// com.apple.modelmanager.simulator (the Mach service modelmanagerd offers Apple's simulators while the
// ModelManager/simulator feature flag is on) and carries that connection's messages over stdin / stdout (xpcwire.h).
// It ends when either side does: the connection breaks, or stdin closes (the device stopped, ssh went away).
// Usage: fmrelay-mac [service]   (X86SIM_FMRELAY_TRACE=1|2: log each frame / with its contents to stderr)
#include "xpcwire.h"
#include <signal.h>

// libxpc's simulator-to-host mode: what the simulator's HostInferenceProviderService does to its connection to this
// service (its libxpc packs messages for the host, and modelmanagerd's simulator listener reads its peers that way too:
// its own peer connections get the same mode, so plain messages failed on decoding, the connection read as interrupted)
extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t c);

static void unsupported(xpc_object_t o)
{
	char* d = xpc_copy_description(o);
	fprintf(stderr, "fmrelay-mac: an XPC object that cannot cross went as null: %.300s\n", d);
	free(d);
}

static void done(bridge* b)
{
	(void) b;
	exit(0);
}

int main(int argc, char** argv)
{
	const char* service = argc > 1 ? argv[1] : "com.apple.modelmanager.simulator";
	setvbuf(stderr, NULL, _IOLBF, 0);
	signal(SIGPIPE, SIG_IGN);
	wire_unsupported = unsupported;
	bridge* b = calloc(1, sizeof *b);
	b->q = dispatch_queue_create("fmrelay", DISPATCH_QUEUE_SERIAL);
	b->c = xpc_connection_create_mach_service(service, b->q, 0);
	if (!getenv("X86SIM_FMRELAY_NO_SIM2HOST"))
		xpc_connection_enable_sim2host_4sim(b->c);
	b->w.rfd = 0;
	b->w.wfd = 1;
	b->who = "fmrelay-mac";
	b->on_close = done;
	bridge_start(b);
	dispatch_main();
}
