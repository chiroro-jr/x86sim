// x86Sim: stand-in for the Mac host's Nearby Interaction service, com.apple.CoreSimulator.NearbyInteraction.
//
// In Apple's simulators NearbyInteraction.framework has no nearbyd: an app's NISession talks to CoreSimulator on the
// Mac (NIServerConnection, NIServerConnection_Sim.m: xpc_connection_create_mach_service + enable_sim2host). It makes its
// discovery token itself (16 random bytes) and checks in with it; the Mac's SimNearbyDeviceManager answers with this
// device's properties and the other booted devices with their peers' tokens, and then sends "distance_update" events
// computed from where the simulator windows are on the Mac's screen. NISession.discoveryToken waits for that check-in:
// with no such service here the check-in failed and the token stayed nil.
//
// This simulator job (cli/libexec/arm64/boot-a64.sh: com.x86sim.nisimhost, MachServices
// com.apple.CoreSimulator.NearbyInteraction, started at the first lookup; simshim keeps the connection a simulator one)
// answers the same messages for this one device. Wire format, as Apple's CoreSimulator 1174.21 sends it (seen with
// a probe in Apple's iOS 27.2 simulator):
//   -> {command: "checkin", discovery_token: <base64>}
//   <- reply {simulator_udid: <uuid>, simulator_name, simulator_platform, simulator_runtime_version,
//            simulator_runtime_build, coresimulator_version: "1174.21", known_devices: [<device props + discovery_tokens>]}
//   -> {command: "request_distance_update"}   <- reply {}
//   <- event {event: "distance_update", updates: [{<udid>, discovery_tokens: [this device's tokens], device_rect_x/y/w/h,
//            device_center_x/y, device_rotation: 0.0}]} to every peer of the device, after each check-in and request.
// There are no other devices here (each x86Sim device is its own world), so known_devices is empty and the updates list
// only this device, as Apple's does with a single booted simulator.
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <uuid/uuid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <TargetConditionals.h>

// marked unavailable in the simulator SDKs' headers, but libxpc has it (Apple's own NearbyInteraction calls it)
extern xpc_connection_t nisim_create_mach_service(const char*, dispatch_queue_t, uint64_t) __asm__("_xpc_connection_create_mach_service");
extern pid_t nisim_get_pid(xpc_connection_t) __asm__("_xpc_connection_get_pid");

#define SERVICE "com.apple.CoreSimulator.NearbyInteraction"
#define MAXPEERS 64

static dispatch_queue_t q;
static struct peer { xpc_connection_t c; char* token; } peers[MAXPEERS];

#define LOG(...) do { fprintf(stderr, "nisimhost: " __VA_ARGS__); fputc('\n', stderr); } while (0)

static const char* env(const char* k, const char* def) { const char* v = getenv(k); return v && *v ? v : def; }

static const char* platform(void)
{
#if TARGET_OS_WATCH
	return "watchOS";
#elif TARGET_OS_TV
	return "tvOS";
#elif TARGET_OS_VISION
	return "xrOS";
#else
	return "iOS";
#endif
}

// xpc_dictionary_set_simdevice_properties: this device
static void set_device(xpc_object_t d)
{
	uuid_t u;
	if (uuid_parse(env("SIMULATOR_UDID", ""), u) != 0)
		uuid_clear(u);
	xpc_dictionary_set_uuid(d, "simulator_udid", u);
	xpc_dictionary_set_string(d, "simulator_name", env("SIMULATOR_DEVICE_NAME", "x86Sim"));
	xpc_dictionary_set_string(d, "simulator_platform", platform());
	xpc_dictionary_set_string(d, "simulator_runtime_version", env("SIMULATOR_RUNTIME_VERSION", ""));
	xpc_dictionary_set_string(d, "simulator_runtime_build", env("SIMULATOR_RUNTIME_BUILD_VERSION", ""));
}

static void send_distance_updates(void)
{
	xpc_object_t toks = xpc_array_create(NULL, 0);
	for (int i = 0; i < MAXPEERS; i++)
		if (peers[i].c && peers[i].token)
			xpc_array_set_string(toks, XPC_ARRAY_APPEND, peers[i].token);
	xpc_object_t self = xpc_dictionary_create(NULL, NULL, 0);
	uuid_t u;
	if (uuid_parse(env("SIMULATOR_UDID", ""), u) != 0)
		uuid_clear(u);
	xpc_dictionary_set_uuid(self, "simulator_udid", u);
	xpc_dictionary_set_value(self, "discovery_tokens", toks);
	static const char* const zero[] = { "device_rect_x", "device_rect_y", "device_rect_w", "device_rect_h",
		"device_center_x", "device_center_y", "device_rotation" };
	for (size_t i = 0; i < sizeof zero / sizeof *zero; i++)
		xpc_dictionary_set_double(self, zero[i], 0.0);
	xpc_object_t ups = xpc_array_create(&self, 1);
	xpc_object_t ev = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(ev, "event", "distance_update");
	xpc_dictionary_set_value(ev, "updates", ups);
	for (int i = 0; i < MAXPEERS; i++)
		if (peers[i].c && peers[i].token)
			xpc_connection_send_message(peers[i].c, ev);
	xpc_release(ev); xpc_release(ups); xpc_release(self); xpc_release(toks);
}

static struct peer* find(xpc_connection_t c)
{
	for (int i = 0; i < MAXPEERS; i++)
		if (peers[i].c == c)
			return &peers[i];
	return NULL;
}

static void message(xpc_connection_t c, xpc_object_t m)
{
	struct peer* p = find(c);
	const char* cmd = xpc_dictionary_get_string(m, "command");
	xpc_object_t r = xpc_dictionary_create_reply(m);
	if (!r) {
		LOG("pid %d: message without reply port (%s)", nisim_get_pid(c), cmd ? cmd : "?");
		return;
	}
	int update = 0;
	if (cmd && !strcmp(cmd, "checkin")) {
		const char* tok = xpc_dictionary_get_string(m, "discovery_token");
		if (p && tok) {
			free(p->token);
			p->token = strdup(tok);
		}
		LOG("pid %d: checkin with discovery token %s", nisim_get_pid(c), tok ? tok : "(none)");
		set_device(r);
		xpc_dictionary_set_string(r, "coresimulator_version", "1174.21");
		xpc_object_t known = xpc_array_create(NULL, 0);   // no other devices
		xpc_dictionary_set_value(r, "known_devices", known);
		xpc_release(known);
		update = 1;
	} else if (cmd && !strcmp(cmd, "request_distance_update")) {
		update = 1;
	} else {
		LOG("pid %d: unknown command %s", nisim_get_pid(c), cmd ? cmd : "(none)");
		xpc_dictionary_set_string(r, "error_message", "Unknown command");
	}
	xpc_connection_send_message(c, r);
	xpc_release(r);
	if (update)
		send_distance_updates();
}

static void new_peer(xpc_connection_t c)
{
	struct peer* p = find(NULL);
	if (!p) {
		LOG("too many peers");
		xpc_connection_cancel(c);
		return;
	}
	p->c = c;
	xpc_retain(c);
	xpc_connection_set_target_queue(c, q);
	xpc_connection_set_event_handler(c, ^(xpc_object_t e) {
		if (xpc_get_type(e) == XPC_TYPE_DICTIONARY) {
			message(c, e);
			return;
		}
		if (e == XPC_ERROR_CONNECTION_INVALID) {   // the peer went away: its token too
			struct peer* q2 = find(c);
			if (q2) {
				free(q2->token);
				q2->token = NULL;
				q2->c = NULL;
				xpc_release(c);
			}
		}
	});
	xpc_connection_activate(c);
}

int main(void)
{
	setvbuf(stderr, NULL, _IOLBF, 0);
	q = dispatch_queue_create("nisimhost", DISPATCH_QUEUE_SERIAL);
	xpc_connection_t l = nisim_create_mach_service(SERVICE, q, XPC_CONNECTION_MACH_SERVICE_LISTENER);
	xpc_connection_set_event_handler(l, ^(xpc_object_t e) {
		if (xpc_get_type(e) == XPC_TYPE_CONNECTION)
			new_peer((xpc_connection_t) e);
		else
			LOG("listener event %p", (void*) e);
	});
	xpc_connection_activate(l);
	LOG("serving %s for %s (%s)", SERVICE, env("SIMULATOR_DEVICE_NAME", "?"), env("SIMULATOR_UDID", "?"));
	dispatch_main();
}
