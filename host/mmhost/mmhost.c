// x86Sim: stand-in for the Mac host's model manager service, com.apple.modelmanager.simulator (FoundationModels).
//
// In Apple's simulators the system language model runs on the Mac: an app's FoundationModels asks the simulator's
// modelmanagerd (com.apple.modelmanager), which runs its inference providers as extensions; the simulator's one,
// HostInferenceProviderService.appex, connects to the Mac's own modelmanagerd through the host Mach service
// com.apple.modelmanager.simulator (offered while the Mac's ModelManager/simulator feature flag is on), Swift XPC with
// Codable messages (_CodableBody & co.), and passes each request on (model info, safety checks, the generation; streaming
// is the client asking for the next result again and again). Without a host service the model stays modelNotReady.
//
// This simulator job (cli/libexec/arm64/boot-a64.sh: com.x86sim.mmhost, MachServices com.apple.modelmanager.simulator,
// started at the first lookup, only while X86SIM_FM_RELAY names a Mac; simshim keeps the connection a simulator one)
// carries every connection, message for message, to linux/fmrelay/fmrelay.py over the Unix socket
// $X86SIM_FMRELAY_SOCK; that one runs fmrelay-mac.c on the Mac, which opens the same service there and sends the messages
// on, as the appex on Apple's simulator would. The replies come back the same way, byte for byte (xpcwire.h). When the
// Mac cannot be reached the connection is cancelled, as when the host service goes away: requests fail, the model
// reports not ready.
#include "xpcwire.h"
#include <sys/un.h>
#include <signal.h>

// marked unavailable in the simulator SDKs' headers, but libxpc has it
extern xpc_connection_t mm_create_mach_service(const char*, dispatch_queue_t, uint64_t) __asm__("_xpc_connection_create_mach_service");
extern pid_t mm_get_pid(xpc_connection_t) __asm__("_xpc_connection_get_pid");

#define SERVICE "com.apple.modelmanager.simulator"

static void unsupported(xpc_object_t o)
{
	char* d = xpc_copy_description(o);
	fprintf(stderr, "mmhost: an XPC object that cannot cross to the Mac went as null: %.300s\n", d);
	free(d);
}

static int relay_connect(void)
{
	const char* path = getenv("X86SIM_FMRELAY_SOCK");
	struct sockaddr_un a = { .sun_family = AF_UNIX };
	if (!path || strlen(path) >= sizeof a.sun_path)
		return -1;
	strcpy(a.sun_path, path);
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	if (connect(fd, (struct sockaddr*) &a, sizeof a) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void closed(bridge* b)
{
	// the bridge itself stays (its reader thread may still look at it); the connection goes
	xpc_release(b->c);
}

static void new_peer(xpc_connection_t c)
{
	int fd = relay_connect();
	pid_t pid = mm_get_pid(c);
	if (fd < 0) {
		fprintf(stderr, "mmhost: pid %d: no relay at %s (%s): connection cancelled\n", pid,
			getenv("X86SIM_FMRELAY_SOCK") ?: "(X86SIM_FMRELAY_SOCK unset)", strerror(errno));
		xpc_connection_cancel(c);
		return;
	}
	bridge* b = calloc(1, sizeof *b);
	b->c = xpc_retain(c);
	b->w.rfd = b->w.wfd = fd;
	b->q = dispatch_queue_create("mmhost.peer", DISPATCH_QUEUE_SERIAL);
	b->who = "mmhost";
	b->on_close = closed;
	fprintf(stderr, "mmhost: pid %d: connection relayed\n", pid);
	bridge_start(b);
}

int main(void)
{
	setvbuf(stderr, NULL, _IOLBF, 0);
	signal(SIGPIPE, SIG_IGN);
	wire_unsupported = unsupported;
	dispatch_queue_t q = dispatch_queue_create("mmhost", DISPATCH_QUEUE_SERIAL);
	xpc_connection_t l = mm_create_mach_service(SERVICE, q, XPC_CONNECTION_MACH_SERVICE_LISTENER);
	xpc_connection_set_event_handler(l, ^(xpc_object_t e) {
		if (xpc_get_type(e) == XPC_TYPE_CONNECTION)
			new_peer((xpc_connection_t) e);
		else
			fprintf(stderr, "mmhost: listener event %p\n", (void*) e);
	});
	xpc_connection_activate(l);
	fprintf(stderr, "mmhost: serving %s through %s\n", SERVICE, getenv("X86SIM_FMRELAY_SOCK") ?: "(no relay)");
	dispatch_main();
}
