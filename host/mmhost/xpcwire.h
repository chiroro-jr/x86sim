// x86Sim: the wire between host/mmhost (inside the simulator), linux/fmrelay/fmrelay.py (Linux) and fmrelay-mac.c (on a
// Mac): XPC messages of one connection, serialized as they are, so what each end hands its own libxpc is the message the
// other end received (strings and data byte for byte).
//
// A frame: u32 length of the rest (little endian), u8 kind, u64 id, then one serialized object.
//   'M' a message without a reply, 'R' a request (the sender waits for the reply with that id), 'P' the reply to request
//   id, 'E' the request id failed on the other end (its connection broke before the reply).
// An object: a tag byte and its value. 'd' dictionary: u32 count, then u32 key length, key, object, each; 'a' array: u32
// count, objects; 's' string, 'D' data: u32 length, bytes; 'i' int64, 'u' uint64, 'f' double, 't' date: 8 bytes;
// 'b' bool: 1 byte; 'U' uuid: 16 bytes; 'n' null. Other XPC types (file descriptors, shared memory, endpoints, ports)
// do not cross a machine boundary: they go as null and are logged.
#ifndef X86SIM_XPCWIRE_H
#define X86SIM_XPCWIRE_H
#include <xpc/xpc.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>

typedef struct { unsigned char* p; size_t n, cap; } wbuf;

static void wb_put(wbuf* b, const void* d, size_t n)
{
	if (b->n + n > b->cap) {
		size_t c = b->cap ? b->cap * 2 : 256;
		while (c < b->n + n)
			c *= 2;
		b->p = realloc(b->p, c);
		b->cap = c;
	}
	memcpy(b->p + b->n, d, n);
	b->n += n;
}
static void wb_u8(wbuf* b, uint8_t v) { wb_put(b, &v, 1); }
static void wb_u32(wbuf* b, uint32_t v) { unsigned char x[4] = { v, v >> 8, v >> 16, v >> 24 }; wb_put(b, x, 4); }
static void wb_u64(wbuf* b, uint64_t v) { wb_u32(b, (uint32_t) v); wb_u32(b, (uint32_t) (v >> 32)); }

// wire_unsupported: called for an XPC type that cannot cross (the caller logs it)
static void (*wire_unsupported)(xpc_object_t o);

static void wire_enc(wbuf* b, xpc_object_t o)
{
	xpc_type_t t = xpc_get_type(o);
	if (t == XPC_TYPE_DICTIONARY) {
		wb_u8(b, 'd');
		wb_u32(b, (uint32_t) xpc_dictionary_get_count(o));
		xpc_dictionary_apply(o, ^bool(const char* k, xpc_object_t v) {
			size_t n = strlen(k);
			wb_u32(b, (uint32_t) n);
			wb_put(b, k, n);
			wire_enc(b, v);
			return true;
		});
	} else if (t == XPC_TYPE_ARRAY) {
		wb_u8(b, 'a');
		wb_u32(b, (uint32_t) xpc_array_get_count(o));
		xpc_array_apply(o, ^bool(size_t i, xpc_object_t v) { (void) i; wire_enc(b, v); return true; });
	} else if (t == XPC_TYPE_STRING) {
		size_t n = xpc_string_get_length(o);
		wb_u8(b, 's'); wb_u32(b, (uint32_t) n); wb_put(b, xpc_string_get_string_ptr(o), n);
	} else if (t == XPC_TYPE_DATA) {
		size_t n = xpc_data_get_length(o);
		wb_u8(b, 'D'); wb_u32(b, (uint32_t) n);
		if (n)
			wb_put(b, xpc_data_get_bytes_ptr(o), n);
	} else if (t == XPC_TYPE_INT64) {
		wb_u8(b, 'i'); wb_u64(b, (uint64_t) xpc_int64_get_value(o));
	} else if (t == XPC_TYPE_UINT64) {
		wb_u8(b, 'u'); wb_u64(b, xpc_uint64_get_value(o));
	} else if (t == XPC_TYPE_DOUBLE) {
		double d = xpc_double_get_value(o); uint64_t v; memcpy(&v, &d, 8);
		wb_u8(b, 'f'); wb_u64(b, v);
	} else if (t == XPC_TYPE_DATE) {
		wb_u8(b, 't'); wb_u64(b, (uint64_t) xpc_date_get_value(o));
	} else if (t == XPC_TYPE_BOOL) {
		wb_u8(b, 'b'); wb_u8(b, xpc_bool_get_value(o) ? 1 : 0);
	} else if (t == XPC_TYPE_UUID) {
		wb_u8(b, 'U'); wb_put(b, xpc_uuid_get_bytes(o), 16);
	} else {
		if (t != XPC_TYPE_NULL && wire_unsupported)
			wire_unsupported(o);
		wb_u8(b, 'n');
	}
}

typedef struct { const unsigned char *p, *end; int bad; } rbuf;
static int rb_need(rbuf* r, size_t n) { if (r->bad || (size_t) (r->end - r->p) < n) { r->bad = 1; return 0; } return 1; }
static uint8_t rb_u8(rbuf* r) { return rb_need(r, 1) ? *r->p++ : 0; }
static uint32_t rb_u32(rbuf* r)
{
	if (!rb_need(r, 4))
		return 0;
	uint32_t v = r->p[0] | r->p[1] << 8 | r->p[2] << 16 | (uint32_t) r->p[3] << 24;
	r->p += 4;
	return v;
}
static uint64_t rb_u64(rbuf* r) { uint64_t lo = rb_u32(r); return lo | (uint64_t) rb_u32(r) << 32; }

static xpc_object_t wire_dec(rbuf* r, int depth)
{
	if (depth > 64) { r->bad = 1; return NULL; }
	switch (rb_u8(r)) {
	case 'd': {
		uint32_t n = rb_u32(r);
		xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
		for (uint32_t i = 0; i < n && !r->bad; i++) {
			uint32_t kl = rb_u32(r);
			if (!rb_need(r, kl))
				break;
			char* k = malloc(kl + 1);
			memcpy(k, r->p, kl); k[kl] = 0; r->p += kl;
			xpc_object_t v = wire_dec(r, depth + 1);
			if (v) { xpc_dictionary_set_value(d, k, v); xpc_release(v); }
			free(k);
		}
		return d;
	}
	case 'a': {
		uint32_t n = rb_u32(r);
		xpc_object_t a = xpc_array_create(NULL, 0);
		for (uint32_t i = 0; i < n && !r->bad; i++) {
			xpc_object_t v = wire_dec(r, depth + 1);
			if (v) { xpc_array_append_value(a, v); xpc_release(v); }
		}
		return a;
	}
	case 's': {
		uint32_t n = rb_u32(r);
		if (!rb_need(r, n))
			return NULL;
		char* s = malloc(n + 1);
		memcpy(s, r->p, n); s[n] = 0; r->p += n;
		xpc_object_t o = xpc_string_create(s);
		free(s);
		return o;
	}
	case 'D': {
		uint32_t n = rb_u32(r);
		if (!rb_need(r, n))
			return NULL;
		xpc_object_t o = xpc_data_create(r->p, n);
		r->p += n;
		return o;
	}
	case 'i': return xpc_int64_create((int64_t) rb_u64(r));
	case 'u': return xpc_uint64_create(rb_u64(r));
	case 'f': { uint64_t v = rb_u64(r); double d; memcpy(&d, &v, 8); return xpc_double_create(d); }
	case 't': return xpc_date_create((int64_t) rb_u64(r));
	case 'b': return xpc_bool_create(rb_u8(r) != 0);
	case 'U': {
		if (!rb_need(r, 16))
			return NULL;
		xpc_object_t o = xpc_uuid_create(r->p);
		r->p += 16;
		return o;
	}
	case 'n': return xpc_null_create();
	default: r->bad = 1; return NULL;
	}
}

// one end of the wire: file descriptors to read and write (a socket: the same one), written under a lock (frames from
// several queues stay whole)
typedef struct { int rfd, wfd; pthread_mutex_t mu; } wire;

static int wire_write_all(int fd, const unsigned char* p, size_t n)
{
	while (n) {
		ssize_t w = write(fd, p, n);
		if (w < 0 && errno == EINTR)
			continue;
		if (w <= 0)
			return -1;
		p += w; n -= (size_t) w;
	}
	return 0;
}

static int wire_send(wire* w, char kind, uint64_t id, xpc_object_t o)
{
	wbuf b = { 0 };
	wb_u32(&b, 0);
	wb_u8(&b, (uint8_t) kind);
	wb_u64(&b, id);
	if (o)
		wire_enc(&b, o);
	else
		wb_u8(&b, 'n');
	uint32_t len = (uint32_t) (b.n - 4);
	b.p[0] = len; b.p[1] = len >> 8; b.p[2] = len >> 16; b.p[3] = len >> 24;
	pthread_mutex_lock(&w->mu);
	int rc = wire_write_all(w->wfd, b.p, b.n);
	pthread_mutex_unlock(&w->mu);
	free(b.p);
	return rc;
}

static int wire_read_all(int fd, unsigned char* p, size_t n)
{
	while (n) {
		ssize_t r = read(fd, p, n);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		p += r; n -= (size_t) r;
	}
	return 0;
}

// wire_recv: the next frame (blocking); 0, or -1 at the end of the wire or a malformed frame. *o: the object (retained)
static int wire_recv(int fd, char* kind, uint64_t* id, xpc_object_t* o)
{
	unsigned char h[4];
	if (wire_read_all(fd, h, 4) < 0)
		return -1;
	uint32_t len = h[0] | h[1] << 8 | h[2] << 16 | (uint32_t) h[3] << 24;
	if (len < 9 || len > (1u << 30))
		return -1;
	unsigned char* p = malloc(len);
	if (!p || wire_read_all(fd, p, len) < 0) {
		free(p);
		return -1;
	}
	rbuf r = { p + 9, p + len, 0 };
	*kind = (char) p[0];
	*id = 0;
	for (int i = 0; i < 8; i++)
		*id |= (uint64_t) p[1 + i] << (8 * i);
	*o = wire_dec(&r, 0);
	free(p);
	if (r.bad) {
		if (*o)
			xpc_release(*o);
		*o = NULL;
		return -1;
	}
	return 0;
}

// wire_copy_into: the reply XPC made for a request (xpc_dictionary_create_reply) gets the other end's reply's contents
static void wire_copy_into(xpc_object_t dst, xpc_object_t src)
{
	if (xpc_get_type(src) != XPC_TYPE_DICTIONARY)
		return;
	xpc_dictionary_apply(src, ^bool(const char* k, xpc_object_t v) { xpc_dictionary_set_value(dst, k, v); return true; });
}

// A bridge: one XPC connection (mmhost: the simulator client's; the Mac relay: its own to modelmanagerd) and one wire.
// What the connection receives goes out on the wire; what the wire brings is sent on the connection. A request keeps its
// message until the other end's reply comes back, which then goes out as XPC's reply to it. Either side ending ends both.
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <sys/socket.h>
typedef struct bridge {
	xpc_connection_t c;
	wire w;
	dispatch_queue_t q;
	struct { uint64_t id; xpc_object_t m; }* pend;   // requests waiting for the other end: their reply objects
	size_t npend, cappend;
	uint64_t next;
	int closed, trace;
	const char* who;
	void (*on_close)(struct bridge*);
} bridge;

static void bridge_log(bridge* b, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
static void bridge_log(bridge* b, const char* fmt, ...)
{
	char m[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(m, sizeof m, fmt, ap);
	va_end(ap);
	fprintf(stderr, "%s: %s\n", b->who, m);
}

static void bridge_close(bridge* b, const char* why)   // on b->q
{
	if (b->closed)
		return;
	b->closed = 1;
	bridge_log(b, "closing: %s (%zu requests pending)", why, b->npend);
	for (size_t i = 0; i < b->npend; i++)
		xpc_release(b->pend[i].m);
	b->npend = 0;
	xpc_connection_cancel(b->c);
	shutdown(b->w.rfd, SHUT_RDWR);
	if (b->w.wfd != b->w.rfd)
		close(b->w.wfd);
	if (b->on_close)
		b->on_close(b);
}

static void bridge_trace(bridge* b, const char* dir, char kind, uint64_t id, xpc_object_t o)
{
	if (!b->trace)
		return;
	if (b->trace > 1 && o) {
		char* d = xpc_copy_description(o);
		bridge_log(b, "%s %c %llu %s", dir, kind, (unsigned long long) id, d);
		free(d);
	} else
		bridge_log(b, "%s %c %llu", dir, kind, (unsigned long long) id);
}

// a message from the connection (on b->q)
static void bridge_from_xpc(bridge* b, xpc_object_t m)
{
	if (b->closed)
		return;
	if (xpc_get_type(m) != XPC_TYPE_DICTIONARY) {
		bridge_close(b, m == XPC_ERROR_CONNECTION_INTERRUPTED ? "connection interrupted" :
			m == XPC_ERROR_CONNECTION_INVALID ? "connection invalid" : "connection error");
		return;
	}
	char kind = 'M';
	uint64_t id = 0;
	// the reply object is made now and kept until the other end answers (one made and released unsent tells the
	// client its request was dropped: its connection reads as interrupted)
	xpc_object_t r = xpc_dictionary_create_reply(m);
	if (r) {
		kind = 'R';
		id = ++b->next;
		if (b->npend == b->cappend) {
			b->cappend = b->cappend ? b->cappend * 2 : 16;
			b->pend = realloc(b->pend, b->cappend * sizeof *b->pend);
		}
		b->pend[b->npend].id = id;
		b->pend[b->npend].m = r;
		b->npend++;
	}
	bridge_trace(b, "->", kind, id, m);
	if (wire_send(&b->w, kind, id, m) < 0)
		bridge_close(b, "wire closed");
}

// a frame from the wire (on b->q)
static void bridge_from_wire(bridge* b, char kind, uint64_t id, xpc_object_t o)
{
	if (b->closed)
		return;
	bridge_trace(b, "<-", kind, id, o);
	if (kind == 'M') {
		xpc_connection_send_message(b->c, o);
	} else if (kind == 'R') {
		xpc_connection_send_message_with_reply(b->c, o, b->q, ^(xpc_object_t rep) {
			if (b->closed)
				return;
			int ok = xpc_get_type(rep) == XPC_TYPE_DICTIONARY;
			bridge_trace(b, "->", ok ? 'P' : 'E', id, rep);
			if (wire_send(&b->w, ok ? 'P' : 'E', id, ok ? rep : NULL) < 0)
				bridge_close(b, "wire closed");
		});
	} else if (kind == 'P' || kind == 'E') {
		size_t i;
		for (i = 0; i < b->npend && b->pend[i].id != id; i++)
			;
		if (i == b->npend) {
			bridge_log(b, "reply to unknown request %llu", (unsigned long long) id);
			return;
		}
		xpc_object_t r = b->pend[i].m;
		b->pend[i] = b->pend[--b->npend];
		if (kind == 'P') {
			wire_copy_into(r, o);
			xpc_connection_send_message(b->c, r);
			xpc_release(r);
		} else {
			// the other end's connection broke before it answered: so does this one (as when the host goes away)
			xpc_release(r);
			bridge_close(b, "the other end's request failed");
		}
	} else
		bridge_log(b, "unknown frame kind %c", kind);
}

static void* bridge_reader(void* arg)
{
	bridge* b = arg;
	for (;;) {
		char kind;
		uint64_t id;
		xpc_object_t o = NULL;
		if (wire_recv(b->w.rfd, &kind, &id, &o) < 0) {
			dispatch_async(b->q, ^{ bridge_close(b, "end of wire"); });
			return NULL;
		}
		dispatch_async(b->q, ^{
			bridge_from_wire(b, kind, id, o);
			if (o)
				xpc_release(o);
		});
	}
}

// bridge_start: the connection's handler goes to the bridge; the connection is activated and the wire read
static void bridge_start(bridge* b)
{
	const char* t = getenv("X86SIM_FMRELAY_TRACE");
	b->trace = t ? atoi(t) : 0;
	pthread_mutex_init(&b->w.mu, NULL);
	xpc_connection_set_target_queue(b->c, b->q);
	xpc_connection_set_event_handler(b->c, ^(xpc_object_t e) { bridge_from_xpc(b, e); });
	xpc_connection_activate(b->c);
	pthread_t th;
	pthread_create(&th, NULL, bridge_reader, b);
	pthread_detach(th);
}
#endif
