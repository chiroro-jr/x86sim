// x86Sim: stand-in for the Mac's fseventsd, the com.apple.FSEvents service that FSEvents clients in a simulator use.
//
// Apple's simulators have no fseventsd of their own: FSEvents (CoreServices' FSEventStream*, FSEvents*) looks up
// com.apple.FSEvents and reaches the Mac's fseventsd, which watches the Mac's volumes, where the simulator's files are.
// x86Sim had no such service, so FSEventsCopyUUIDForDevice returned NULL and every stream failed to start: fileproviderd
// logged "Unable to retrieve FSEvent stream UUID" and disabled a replicated FileProvider domain (POSIX 19), so the
// domain's extension never ran.
//
// This simulator job (cli/libexec/arm64/boot-a64.sh: com.x86sim.fseventsd, MachServices com.apple.FSEvents, started at
// the first lookup) speaks fseventsd's MIG protocol, as the iOS / tvOS / watchOS / visionOS 27.2 runtimes' CoreServices
// client sends it (disassembled; the same messages Apple's macOS 27 fseventsd answers, checked with a raw MIG probe on
// the Mac). Requests (to com.apple.FSEvents unless noted; replies are id + 100):
//   66000 register: port (client's callback port, make-send), OOL u32 path offsets, OOL path strings, [OOL u32 exclusion
//         offsets, OOL exclusion strings,] NDR, dev, npaths, offsets count, strings size, [nexcl, count, size,]
//         u64 latency in microseconds, u32 create flags, u64 sinceWhen (the 3-descriptor form is the older one the client
//         falls back to). Reply: a send right to the stream's own port (complex, 1 port descriptor), or NDR + error.
//   66001 flush (to the stream port): pending events are sent now; reply NDR, ret, u64 id of the last live event sent
//         (0: none); FSEventStreamFlushSync waits until it has seen that id.
//   66002 copy UUID for device: NDR, u32 dev -> NDR, ret, char[36] (the volume's UUID string, or "NO-UUID-UNKNOWN-DEVICE")
//   66003 current event id: -> NDR, ret, u64
//   66004 last event id for device before time: NDR, u32 dev, u64 seconds (CFAbsoluteTime) -> NDR, ret, u64
//   66005 purge events for device up to id: NDR, u32 dev, u64 id -> NDR, ret, u32
//   66006 unregister (to the stream port): -> NDR, ret
// Events go to the client's port as message 67000 (no reply): 4 OOL descriptors (u32 path offsets, u32 flags, u64 event
// ids, path strings), NDR, u32 count, u32 x3 array counts, u32 strings size. The flags are fseventsd's own bits, which
// the client turns into kFSEventStreamEventFlag* (FS_* below). As on the Mac:
//   - file events (kFSEventStreamCreateFlagFileEvents) carry the item's path and flags; a path's flags accumulate while
//     fseventsd keeps it in its buffer (a renamed new file: created|modified|renamed); without file events, the
//     changed item's directory is reported, with a trailing "/" and no flags;
//   - mkdir is FS_DIRCREATED (also "created" for the client), a file created FS_CREATED, chmod FS_CHOWN (the client's
//     ItemChangeOwner), utimes FS_INODEMETA, xattrs FS_XATTR;
//   - with a sinceWhen, the history since then comes first (one batch, coalesced per path, sorted by path), then a
//     history-done event on the first watched path with the last replayed id (sinceWhen when there was none).
// Watching: Linux inotify on every directory under the streams' paths (Darling processes make Linux system calls; the
// guest's path opened here, its /proc/self/fd/N handed to inotify_add_watch). Event ids and history (the last
// HISTORY_MAX events) persist in <data>/.fseventsd, as fseventsd keeps them in each volume's .fseventsd.
// Not done: kFSEventStreamCreateFlagIgnoreSelf / MarkSelf (inotify doesn't say which process made a change), hard
// link flags, extended data / document ids beyond what the client fills in itself.
#include <mach/mach.h>
#include <mach/notify.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <uuid/uuid.h>

// marked unavailable on tvOS / watchOS in the SDK headers; libsystem_kernel has them on every platform
extern mach_msg_return_t fse_mach_msg(mach_msg_header_t*, mach_msg_option_t, mach_msg_size_t, mach_msg_size_t, mach_port_name_t,
	mach_msg_timeout_t, mach_port_name_t) __asm__("_mach_msg");
extern void fse_mach_msg_destroy(mach_msg_header_t*) __asm__("_mach_msg_destroy");
#define mach_msg fse_mach_msg
#define mach_msg_destroy fse_mach_msg_destroy

// not in the simulator SDKs' headers (libxpc has them)
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char* name, mach_port_t* sp);

#define SERVICE "com.apple.FSEvents"
#define HISTORY_MAX 50000
#define BATCH_MAX 2000 // events per 67000 message
#define ACCUM_WINDOW_US 10000000ULL // how long a path's flags accumulate (fseventsd's buffer)

// fseventsd's event flags (what the client converts; public names in comments)
#define FS_CREATED 0x1 // ItemCreated
#define FS_REMOVED 0x2 // ItemRemoved
#define FS_INODEMETA 0x4 // ItemInodeMetaMod
#define FS_RENAMED 0x8 // ItemRenamed
#define FS_MODIFIED 0x10 // ItemModified
#define FS_DIRCREATED 0x80 // ItemCreated (mkdir)
#define FS_CHOWN 0x100 // ItemChangeOwner (chmod / chown)
#define FS_XATTR 0x200 // ItemXattrMod
#define FS_ISSYMLINK 0x400000
#define FS_ISFILE 0x800000
#define FS_ISDIR 0x1000000
#define FS_HISTORYDONE 0x8000000
#define FS_MUSTSCAN 0x20000000
#define FS_USERDROPPED 0x40000000
#define FS_KERNELDROPPED 0x80000000u

// FSEventStreamCreateFlags
#define CF_NODEFER 0x2
#define CF_FILEEVENTS 0x10
#define SINCE_NOW 0xffffffffffffffffULL

static FILE* logf_;
static int debug;
#define LOG(...) do { fprintf(logf_, "fseventsd: " __VA_ARGS__); fputc('\n', logf_); fflush(logf_); } while (0)
#define DBG(...) do { if (debug) LOG(__VA_ARGS__); } while (0)

// x86Sim: a Linux system call (Darling processes are Linux processes): under libarm64jit, "svc #0xfffe" is one, with
// x8 = the x86_64 system call number (as in host/openurl)
static long linux_syscall3(long n, long a, long b, long c)
{
	register long x0 __asm__("x0") = a, x1 __asm__("x1") = b, x2 __asm__("x2") = c;
	register long x8 __asm__("x8") = n;
	__asm__ volatile("svc #0xfffe" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}
#define L_READ 0
#define L_IOCTL 16
#define L_INOTIFY_ADD_WATCH 254
#define L_INOTIFY_RM_WATCH 255
#define L_INOTIFY_INIT1 294
#define L_FIONREAD 0x541b
#define IN_MODIFY 0x2
#define IN_ATTRIB 0x4
#define IN_MOVED_FROM 0x40
#define IN_MOVED_TO 0x80
#define IN_CREATE 0x100
#define IN_DELETE 0x200
#define IN_DELETE_SELF 0x400
#define IN_MOVE_SELF 0x800
#define IN_Q_OVERFLOW 0x4000
#define IN_IGNORED 0x8000
#define IN_ONLYDIR 0x1000000
#define IN_ISDIR 0x40000000
struct linux_inotify_event { int wd; uint32_t mask, cookie, len; char name[]; };

static uint64_t now_us(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return (uint64_t)tv.tv_sec * 1000000 + tv.tv_usec;
}

static int under(const char* path, const char* root) // path is root or inside it
{
	size_t n = strlen(root);
	if (n == 1 && root[0] == '/')
		return path[0] == '/';
	return strncmp(path, root, n) == 0 && (path[n] == 0 || path[n] == '/');
}

// ---- state (all under mu) ----
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t idle = PTHREAD_COND_INITIALIZER;
static int ifd = -1, reading; // the inotify thread is handling events
static mach_port_t pset, svc, wake;
static uint64_t cur_id; // the last event id given out
static char* statedir;
static char home_uuid[37], root_uuid[37];
static dev_t home_dev, root_dev;

struct ev { uint64_t id; uint32_t flags; char* path; };
struct stream {
	int used;
	mach_port_t port, client;
	uint32_t dev, flags;
	uint64_t latency, since, deadline, last_delivery, last_live;
	int npaths, nexcl;
	char** paths; // as registered (absolute; relative to "/" when dev != 0)
	char** excl;
	struct ev* pend;
	int npend, cappend;
	int dropped;
};
static struct stream* streams;
static int nstreams;

struct watch { char* path; int wd; };
static struct watch* watches; // indexed by wd
static int nwatches;

// history: a ring of the last HISTORY_MAX events, with the time of each (FSEventsGetLastEventIdForDeviceBeforeTime)
struct hist { uint64_t id, t; uint32_t flags; char* path; };
static struct hist* hist;
static int hhead, hcount;
static uint64_t hist_floor; // events with ids up to this were dropped from the history
static FILE* histf;
static int hist_lines;

// per-path accumulated flags (fseventsd's in-memory buffer)
struct accum { char* path; uint32_t flags; uint64_t t; };
static struct accum* acc;
static int nacc, capacc;
static uint64_t acc_epoch;

// ---- persistence ----
static void save_state(void)
{
	char p[1024], q[1040];
	snprintf(p, sizeof p, "%s/state", statedir);
	snprintf(q, sizeof q, "%s.new", p);
	FILE* f = fopen(q, "w");
	if (!f)
		return;
	fprintf(f, "%llu %llu %s\n", (unsigned long long)cur_id, (unsigned long long)hist_floor, home_uuid);
	fclose(f);
	rename(q, p);
}

static void hist_add(uint64_t id, uint32_t flags, const char* path, uint64_t t, int persist)
{
	struct hist* h;
	if (hcount == HISTORY_MAX) {
		h = &hist[hhead];
		if (h->id > hist_floor)
			hist_floor = h->id;
		free(h->path);
		hhead = (hhead + 1) % HISTORY_MAX;
		hcount--;
	}
	h = &hist[(hhead + hcount++) % HISTORY_MAX];
	h->id = id;
	h->flags = flags;
	h->path = strdup(path);
	h->t = t;
	if (persist && histf) {
		fprintf(histf, "%llu %x %llu %s\n", (unsigned long long)id, flags, (unsigned long long)t, path);
		hist_lines++;
	}
}

// rewrite the history file with what the ring holds (when it grew to twice that)
static void hist_compact(void)
{
	char p[1024], q[1040];
	snprintf(p, sizeof p, "%s/history", statedir);
	snprintf(q, sizeof q, "%s.new", p);
	FILE* f = fopen(q, "w");
	if (!f)
		return;
	for (int i = 0; i < hcount; i++) {
		struct hist* h = &hist[(hhead + i) % HISTORY_MAX];
		fprintf(f, "%llu %x %llu %s\n", (unsigned long long)h->id, h->flags, (unsigned long long)h->t, h->path);
	}
	fclose(f);
	rename(q, p);
	if (histf)
		fclose(histf);
	histf = fopen(p, "a");
	hist_lines = hcount;
	save_state();
}

static void load_state(void)
{
	const char* home = getenv("HOME");
	char p[1024];
	if (asprintf(&statedir, "%s/.fseventsd", home && *home ? home : "/private/var/tmp") < 0)
		exit(1);
	mkdir(statedir, 0700);
	snprintf(p, sizeof p, "%s/state", statedir);
	FILE* f = fopen(p, "r");
	if (f) {
		unsigned long long a = 0, b = 0;
		char u[64] = "";
		if (fscanf(f, "%llu %llu %63s", &a, &b, u) >= 2) {
			cur_id = a;
			hist_floor = b;
		}
		if (strlen(u) == 36)
			strcpy(home_uuid, u);
		fclose(f);
	}
	if (!home_uuid[0]) {
		uuid_t u;
		uuid_generate_random(u);
		uuid_unparse_upper(u, home_uuid);
	}
	// the root volume: another UUID, derived from this one (stable across boots)
	strcpy(root_uuid, home_uuid);
	root_uuid[35] = root_uuid[35] == 'F' ? '0' : (root_uuid[35] == '9' ? 'A' : root_uuid[35] + 1);
	hist = calloc(HISTORY_MAX, sizeof *hist);
	snprintf(p, sizeof p, "%s/history", statedir);
	f = fopen(p, "r");
	if (f) {
		char line[2048];
		while (fgets(line, sizeof line, f)) {
			unsigned long long id, t;
			unsigned flags;
			int n = 0;
			if (sscanf(line, "%llu %x %llu %n", &id, &flags, &t, &n) < 3 || !n)
				continue;
			char* path = line + n;
			path[strcspn(path, "\n")] = 0;
			hist_add(id, flags, path, t, 0);
			hist_lines++;
			if (id > cur_id)
				cur_id = id;
		}
		fclose(f);
	}
	histf = fopen(p, "a");
	if (hist_lines > 2 * HISTORY_MAX)
		hist_compact();
	save_state();
	struct stat st;
	if (stat(home && *home ? home : "/", &st) == 0)
		home_dev = st.st_dev;
	if (stat("/", &st) == 0)
		root_dev = st.st_dev;
}

// ---- watches ----
// wd -> path (watches[]), and path -> wd through a hash table (a device's data has ~20,000 directories)
#define WHASH 65536
static int* whash; // wd + 1 per slot, 0 empty, -1 deleted (open addressing)
static unsigned hash_path(const char* p)
{
	unsigned h = 2166136261u;
	while (*p)
		h = (h ^ (unsigned char)*p++) * 16777619u;
	return h;
}
static int find_watch(const char* path)
{
	if (!whash)
		return -1;
	for (unsigned i = hash_path(path) % WHASH, n = 0; n < WHASH; i = (i + 1) % WHASH, n++) {
		int v = whash[i];
		if (!v)
			return -1;
		if (v > 0 && watches[v - 1].path && strcmp(watches[v - 1].path, path) == 0)
			return v - 1;
	}
	return -1;
}
static void hash_del(int wd)
{
	for (unsigned i = hash_path(watches[wd].path) % WHASH, n = 0; n < WHASH && whash[i]; i = (i + 1) % WHASH, n++)
		if (whash[i] == wd + 1) {
			whash[i] = -1;
			return;
		}
}
// set (path non-NULL, taken over) or clear a watch's path
static void set_watch_path(int wd, char* path)
{
	if (!whash)
		whash = calloc(WHASH, sizeof *whash);
	if (watches[wd].path) {
		hash_del(wd);
		free(watches[wd].path);
	}
	watches[wd].path = path;
	if (!path)
		return;
	for (unsigned i = hash_path(path) % WHASH, n = 0; n < WHASH; i = (i + 1) % WHASH, n++)
		if (whash[i] <= 0) {
			whash[i] = wd + 1;
			return;
		}
}

// what is never watched below a stream root: the Linux host's own file system (guest /Volumes/SystemRoot, except the
// way to and into this device's data, $HOME), the kernel's and the read-only system's directories. A stream on "/"
// (a daemon watching the whole volume, as Apple's fseventsd does cheaply in the kernel) would otherwise crawl the
// whole host with inotify; Apple's simulator has no changes of its own in those places either.
static const char* home_dir;
static int outside_device(const char* path)
{
	static const char* sys[] = { "/dev", "/proc", "/sys", "/System", "/usr", "/bin", "/sbin", "/cores", "/Volumes", NULL };
	for (int i = 0; sys[i]; i++)
		if (under(path, sys[i]))
			return !(home_dir && (under(home_dir, path) || under(path, home_dir)));
	return 0;
}

// 1: watched now, 0: was watched already, -1: can't
static int add_watch(const char* path)
{
	if (find_watch(path) >= 0)
		return 0;
	int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
	if (fd < 0)
		return -1;
	char fdpath[64];
	snprintf(fdpath, sizeof fdpath, "/proc/self/fd/%d", fd);
	long wd = linux_syscall3(L_INOTIFY_ADD_WATCH, ifd, (long)fdpath,
		IN_MODIFY | IN_ATTRIB | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR);
	close(fd);
	if (wd < 0) {
		LOG("inotify_add_watch %s: %ld", path, wd);
		return -1;
	}
	if (wd >= nwatches) {
		int n = wd + 1024;
		watches = realloc(watches, n * sizeof *watches);
		memset(watches + nwatches, 0, (n - nwatches) * sizeof *watches);
		nwatches = n;
	}
	set_watch_path(wd, strdup(path));
	watches[wd].wd = wd;
	DBG("watch %ld %s", wd, path);
	return 1;
}

static void rm_watch(int wd)
{
	if (wd < 0 || wd >= nwatches || !watches[wd].path)
		return;
	linux_syscall3(L_INOTIFY_RM_WATCH, ifd, wd, 0);
	set_watch_path(wd, NULL);
}

static void raw_event(const char* path, uint32_t flags);

// watch dir and everything under it; created: report what is found as created (a new directory's contents made before
// its watch was in place)
// (a directory watched already has its tree watched, unless it is a stream root being set up: force)
static void watch_tree_f(const char* dir, int created, int force)
{
	int w = add_watch(dir);
	if (w < 0 || (w == 0 && !created && !force))
		return;
	if (outside_device(dir) && !(home_dir && under(home_dir, dir)))
		return;
	DIR* d = opendir(dir);
	if (!d)
		return;
	struct dirent* e;
	while ((e = readdir(d))) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		char* p;
		if (asprintf(&p, "%s%s%s", dir, strcmp(dir, "/") ? "/" : "", e->d_name) < 0)
			continue;
		struct stat st;
		if (lstat(p, &st) == 0) {
			// (a file found with data was written too, before the watch saw it: fseventsd would say modified)
			if (created)
				raw_event(p, S_ISDIR(st.st_mode) ? FS_DIRCREATED | FS_ISDIR : FS_CREATED | (S_ISLNK(st.st_mode) ? FS_ISSYMLINK :
					FS_ISFILE | (S_ISREG(st.st_mode) && st.st_size > 0 ? FS_MODIFIED : 0)));
			// on the way to $HOME through a skipped directory: only that way
			if (S_ISDIR(st.st_mode) && strcmp(p, statedir) && (!outside_device(dir) || (home_dir && under(home_dir, p))))
				watch_tree_f(p, created, 0);
		}
		free(p);
	}
	closedir(d);
	// $HOME under this directory, through a link (guest /Volumes/SystemRoot): its tree too
	if (home_dir && under(home_dir, dir) && strcmp(home_dir, dir))
		watch_tree_f(home_dir, created, 0);
}
static void watch_tree(const char* dir, int created) { watch_tree_f(dir, created, 0); }

static char* stream_root(struct stream* s, int i) // a stream path as an absolute path here
{
	static char buf[2048];
	if (!s->dev)
		return s->paths[i];
	snprintf(buf, sizeof buf, "/%s", s->paths[i][0] == '/' ? s->paths[i] + 1 : s->paths[i]);
	return buf;
}

// watch a stream root: its tree, or (not there yet) its deepest existing ancestor, to see it appear
static void ensure_root(const char* root)
{
	struct stat st;
	if (lstat(root, &st) == 0 && S_ISDIR(st.st_mode)) {
		watch_tree_f(root, 0, 1);
		return;
	}
	char* a = strdup(root);
	for (;;) {
		char* sl = strrchr(a, '/');
		if (!sl)
			break;
		if (sl == a) {
			a[1] = 0;
			add_watch(a);
			break;
		}
		*sl = 0;
		if (lstat(a, &st) == 0 && S_ISDIR(st.st_mode)) {
			add_watch(a);
			break;
		}
	}
	free(a);
}

// a directory appeared at path: watch it if a stream covers it, or it leads to a stream root
static void dir_appeared(const char* path, int report)
{
	int covered = 0;
	for (int i = 0; i < nstreams; i++) {
		struct stream* s = &streams[i];
		if (!s->used)
			continue;
		for (int j = 0; j < s->npaths; j++) {
			char* r = stream_root(s, j);
			if (under(path, r))
				covered = 1;
			else if (under(r, path))
				ensure_root(r);
		}
	}
	if (covered)
		watch_tree(path, report);
}

// drop watches no stream covers or leads to any more
static void prune_watches(void)
{
	for (int w = 0; w < nwatches; w++) {
		if (!watches[w].path)
			continue;
		int keep = 0;
		for (int i = 0; i < nstreams && !keep; i++) {
			struct stream* s = &streams[i];
			if (!s->used)
				continue;
			for (int j = 0; j < s->npaths && !keep; j++) {
				char* r = stream_root(s, j);
				keep = under(watches[w].path, r) || under(r, watches[w].path);
			}
		}
		if (!keep)
			rm_watch(w);
	}
}

// ---- events ----
static void wake_main(void)
{
	mach_msg_header_t m = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0), .msgh_size = sizeof m,
		.msgh_remote_port = wake, .msgh_id = 1 };
	mach_msg(&m, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
}

static void pend_add(struct stream* s, uint64_t id, uint32_t flags, const char* path)
{
	for (int i = 0; i < s->npend; i++)
		if (strcmp(s->pend[i].path, path) == 0) {
			s->pend[i].flags |= flags;
			s->pend[i].id = id;
			goto schedule;
		}
	if (s->npend == s->cappend) {
		s->cappend = s->cappend ? 2 * s->cappend : 16;
		s->pend = realloc(s->pend, s->cappend * sizeof *s->pend);
	}
	s->pend[s->npend++] = (struct ev){ id, flags, strdup(path) };
schedule:
	if (!s->deadline) {
		uint64_t t = now_us();
		s->deadline = (s->flags & CF_NODEFER) && t - s->last_delivery >= s->latency ? t : t + s->latency;
		if (!s->deadline)
			s->deadline = 1;
	}
}

static int excluded(struct stream* s, const char* path)
{
	for (int i = 0; i < s->nexcl; i++)
		if (under(path, s->excl[i]))
			return 1;
	return 0;
}

// the path a stream reports for an event on path (NULL: not for this stream); buf for the result
static const char* stream_path(struct stream* s, const char* path, int filelevel, char* buf, size_t n)
{
	int hit = -1;
	for (int j = 0; j < s->npaths && hit < 0; j++)
		if (under(path, stream_root(s, j)))
			hit = j;
	if (hit < 0 || excluded(s, path))
		return NULL;
	if (filelevel) {
		snprintf(buf, n, "%s", path);
	} else {
		// the changed item's directory, with a trailing slash; the root itself changing isn't the stream's
		const char* sl = strrchr(path, '/');
		if (!sl)
			return NULL;
		size_t len = sl - path;
		if (len == 0)
			snprintf(buf, n, "/");
		else
			snprintf(buf, n, "%.*s/", (int)len, path);
		char dir[2048];
		snprintf(dir, sizeof dir, "%.*s", (int)(len ? len : 1), path);
		if (!under(dir, stream_root(s, hit)))
			return NULL;
	}
	if (s->dev) // relative to the device
		memmove(buf, buf + 1, strlen(buf));
	return buf;
}

static void deliver_to_streams(uint64_t id, uint32_t flags, const char* path)
{
	char buf[2048];
	for (int i = 0; i < nstreams; i++) {
		struct stream* s = &streams[i];
		if (!s->used)
			continue;
		int file = s->flags & CF_FILEEVENTS;
		const char* p = stream_path(s, path, file, buf, sizeof buf);
		if (p)
			pend_add(s, id, file ? flags : flags & (FS_MUSTSCAN | FS_USERDROPPED | FS_KERNELDROPPED), p);
	}
}

// one change: a new event id, the path's accumulated flags, history, the streams that watch it
static void raw_event(const char* path, uint32_t flags)
{
	if (under(path, statedir))
		return;
	uint64_t t = now_us();
	if (t - acc_epoch > ACCUM_WINDOW_US) {
		for (int i = 0; i < nacc; i++)
			free(acc[i].path);
		nacc = 0;
		acc_epoch = t;
	}
	int k;
	for (k = 0; k < nacc; k++)
		if (strcmp(acc[k].path, path) == 0)
			break;
	if (k == nacc) {
		if (nacc == capacc) {
			capacc = capacc ? 2 * capacc : 64;
			acc = realloc(acc, capacc * sizeof *acc);
		}
		acc[nacc++] = (struct accum){ strdup(path), 0, t };
	}
	uint32_t typ = flags & (FS_ISFILE | FS_ISDIR | FS_ISSYMLINK);
	if (typ) // a path that became another kind of item: only that kind
		acc[k].flags &= ~(FS_ISFILE | FS_ISDIR | FS_ISSYMLINK);
	// a repeat of the last change to this path (writes): nothing new
	if ((acc[k].flags | flags) == acc[k].flags && hcount && hist[(hhead + hcount - 1) % HISTORY_MAX].flags == acc[k].flags &&
		strcmp(hist[(hhead + hcount - 1) % HISTORY_MAX].path, path) == 0)
		return;
	acc[k].flags |= flags;
	uint64_t id = ++cur_id;
	hist_add(id, acc[k].flags, path, t / 1000000, 1);
	if (hist_lines > 2 * HISTORY_MAX)
		hist_compact();
	DBG("event %llu %08x %s", (unsigned long long)id, acc[k].flags, path);
	deliver_to_streams(id, acc[k].flags, path);
}

static uint32_t item_type(const char* path, int isdir)
{
	if (isdir)
		return FS_ISDIR;
	struct stat st;
	if (lstat(path, &st) == 0) {
		if (S_ISLNK(st.st_mode))
			return FS_ISSYMLINK;
		if (S_ISDIR(st.st_mode))
			return FS_ISDIR;
	}
	return FS_ISFILE;
}

// a watched directory moved from old to new: rename the watches under it
static void move_watches(const char* old, const char* new)
{
	size_t n = strlen(old);
	for (int w = 0; w < nwatches; w++)
		if (watches[w].path && under(watches[w].path, old)) {
			char* p;
			if (asprintf(&p, "%s%s", new, watches[w].path + n) >= 0)
				set_watch_path(w, p);
		}
}

static void drop_watches_under(const char* path)
{
	for (int w = 0; w < nwatches; w++)
		if (watches[w].path && under(watches[w].path, path))
			rm_watch(w);
}

static void overflow(void)
{
	// the kernel dropped events: every stream rescans its paths, as fseventsd's MustScanSubDirs|KernelDropped
	for (int i = 0; i < nstreams; i++) {
		struct stream* s = &streams[i];
		if (!s->used)
			continue;
		for (int j = 0; j < s->npaths; j++)
			pend_add(s, ++cur_id, FS_MUSTSCAN | FS_KERNELDROPPED, s->paths[j]);
	}
}

static void handle_inotify(char* buf, long n)
{
	char* movedfrom = NULL; // a directory moved away; dropped unless its IN_MOVED_TO follows
	uint32_t cookie = 0;
	for (char* p = buf; p < buf + n;) {
		struct linux_inotify_event* e = (struct linux_inotify_event*)p;
		p += sizeof *e + e->len;
		if (e->mask & IN_Q_OVERFLOW) {
			overflow();
			continue;
		}
		if (e->wd < 0 || e->wd >= nwatches || !watches[e->wd].path)
			continue;
		if (e->mask & IN_IGNORED) {
			set_watch_path(e->wd, NULL);
			continue;
		}
		const char* dir = watches[e->wd].path;
		char* path;
		if (e->len && e->name[0]) {
			if (asprintf(&path, "%s%s%s", dir, strcmp(dir, "/") ? "/" : "", e->name) < 0)
				continue;
		} else {
			path = strdup(dir);
		}
		int isdir = (e->mask & IN_ISDIR) != 0;
		if (movedfrom && !((e->mask & IN_MOVED_TO) && e->cookie == cookie)) {
			drop_watches_under(movedfrom);
			free(movedfrom);
			movedfrom = NULL;
		}
		if (e->mask & IN_CREATE) {
			raw_event(path, isdir ? FS_DIRCREATED | FS_ISDIR : FS_CREATED | item_type(path, 0));
			if (isdir)
				dir_appeared(path, 1);
		} else if (e->mask & IN_DELETE) {
			raw_event(path, FS_REMOVED | (isdir ? FS_ISDIR : FS_ISFILE));
		} else if (e->mask & IN_MOVED_FROM) {
			raw_event(path, FS_RENAMED | item_type(path, isdir));
			if (isdir) {
				movedfrom = strdup(path);
				cookie = e->cookie;
			}
		} else if (e->mask & IN_MOVED_TO) {
			raw_event(path, FS_RENAMED | item_type(path, isdir));
			if (isdir) {
				if (movedfrom && e->cookie == cookie) {
					move_watches(movedfrom, path);
					free(movedfrom);
					movedfrom = NULL;
				}
				dir_appeared(path, 0);
			}
		} else if (e->mask & IN_MODIFY) {
			if (!isdir)
				raw_event(path, FS_MODIFIED | item_type(path, 0));
		} else if (e->mask & IN_ATTRIB) {
			// inotify doesn't say what changed. utimes sets the modification time to the change time; chmod / chown /
			// xattrs change only the latter (fseventsd: chmod is "change owner", as Apple's simulator shows)
			struct stat st;
			uint32_t f = FS_CHOWN;
			if (lstat(path, &st) == 0 && st.st_mtimespec.tv_sec == st.st_ctimespec.tv_sec &&
				st.st_mtimespec.tv_nsec == st.st_ctimespec.tv_nsec)
				f = FS_INODEMETA;
			raw_event(path, f | item_type(path, isdir));
		} else if (e->mask & (IN_DELETE_SELF | IN_MOVE_SELF)) {
			// its parent reports it; a stream root deleted or moved away: watch for it to come back
			if (e->mask & IN_DELETE_SELF)
				rm_watch(e->wd);
		}
		free(path);
	}
	if (movedfrom) {
		drop_watches_under(movedfrom);
		free(movedfrom);
	}
}

static void* inotify_thread(void* arg)
{
	static char buf[64 * 1024] __attribute__((aligned(8)));
	(void)arg;
	for (;;) {
		long n = linux_syscall3(L_READ, ifd, (long)buf, sizeof buf);
		if (n == -4 /* EINTR */)
			continue;
		if (n <= 0) {
			LOG("inotify read: %ld", n);
			return NULL;
		}
		pthread_mutex_lock(&mu);
		reading = 1;
		handle_inotify(buf, n);
		reading = 0;
		pthread_cond_broadcast(&idle);
		pthread_mutex_unlock(&mu);
		wake_main();
	}
}

// wait (mu held) until the inotify thread has handled every change made so far
static void drain(void)
{
	for (int i = 0; i < 100; i++) {
		int pending = 0;
		long r = linux_syscall3(L_IOCTL, ifd, L_FIONREAD, (long)&pending);
		if (!reading && (r < 0 || pending <= 0))
			return;
		struct timespec ts;
		struct timeval tv;
		gettimeofday(&tv, NULL);
		ts.tv_sec = tv.tv_sec;
		ts.tv_nsec = tv.tv_usec * 1000 + 20 * 1000000;
		if (ts.tv_nsec >= 1000000000) {
			ts.tv_sec++;
			ts.tv_nsec -= 1000000000;
		}
		pthread_cond_timedwait(&idle, &mu, &ts);
	}
}

// ---- messages ----
#pragma pack(push, 4)
typedef struct {
	mach_msg_header_t h;
	mach_msg_body_t body;
	mach_msg_ool_descriptor_t ool[4];
	NDR_record_t ndr;
	uint32_t n, c0, c1, c2, c3;
} callback_msg;
typedef struct {
	mach_msg_header_t h;
	mach_msg_body_t body;
	mach_msg_port_descriptor_t port;
	mach_msg_ool_descriptor_t ool[4];
	NDR_record_t ndr;
	uint32_t dev, npaths, offcnt, strcnt, nexcl, exoffcnt, exstrcnt;
	uint64_t latency;
	uint32_t flags;
	uint64_t since;
} register_req;
typedef struct {
	mach_msg_header_t h;
	mach_msg_body_t body;
	mach_msg_port_descriptor_t port;
	mach_msg_ool_descriptor_t ool[2];
	NDR_record_t ndr;
	uint32_t dev, npaths, offcnt, strcnt;
	uint64_t latency;
	uint32_t flags;
	uint64_t since;
} register_req_old;
typedef struct { mach_msg_header_t h; mach_msg_body_t body; mach_msg_port_descriptor_t port; } register_rep;
typedef struct { mach_msg_header_t h; NDR_record_t ndr; uint32_t dev; uint64_t v; } dev_req;
typedef struct { mach_msg_header_t h; NDR_record_t ndr; kern_return_t ret; } ret_rep;
typedef struct { mach_msg_header_t h; NDR_record_t ndr; kern_return_t ret; uint64_t v; } u64_rep;
typedef struct { mach_msg_header_t h; NDR_record_t ndr; kern_return_t ret; uint32_t v; } u32_rep;
typedef struct { mach_msg_header_t h; NDR_record_t ndr; kern_return_t ret; char uuid[36]; } uuid_rep;
#pragma pack(pop)

static int evcmp_path(const void* a, const void* b) { return strcmp(((struct ev*)a)->path, ((struct ev*)b)->path); }
static int evcmp_id(const void* a, const void* b)
{
	uint64_t x = ((struct ev*)a)->id, y = ((struct ev*)b)->id;
	return x < y ? -1 : x > y;
}

// send events to a stream's client (67000); returns 0 if the client is gone
static int send_events(struct stream* s, struct ev* ev, int n)
{
	for (int base = 0; base < n; base += BATCH_MAX) {
		int k = n - base < BATCH_MAX ? n - base : BATCH_MAX;
		uint32_t* offs = malloc(4 * k);
		uint32_t* flags = malloc(4 * k);
		uint64_t* ids = malloc(8 * k);
		size_t size = 0;
		for (int i = 0; i < k; i++)
			size += strlen(ev[base + i].path) + 1;
		char* strs = malloc(size ? size : 1);
		size_t o = 0;
		for (int i = 0; i < k; i++) {
			struct ev* e = &ev[base + i];
			offs[i] = o;
			flags[i] = e->flags;
			ids[i] = e->id;
			size_t l = strlen(e->path) + 1;
			memcpy(strs + o, e->path, l);
			o += l;
			DBG("  -> stream %x: %llu %08x %s", s->port, (unsigned long long)e->id, e->flags, e->path);
		}
		callback_msg m = { 0 };
		m.h.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
		m.h.msgh_size = sizeof m;
		m.h.msgh_remote_port = s->client;
		m.h.msgh_id = 67000;
		m.body.msgh_descriptor_count = 4;
		void* addr[4] = { offs, flags, ids, strs };
		uint32_t sz[4] = { 4 * k, 4 * k, 8 * k, (uint32_t)size };
		for (int i = 0; i < 4; i++)
			m.ool[i] = (mach_msg_ool_descriptor_t){ addr[i], FALSE, 0, MACH_MSG_VIRTUAL_COPY, MACH_MSG_OOL_DESCRIPTOR, sz[i] };
		m.ndr = NDR_record;
		m.n = m.c0 = m.c1 = m.c2 = k;
		m.c3 = size;
		kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
		free(offs);
		free(flags);
		free(ids);
		free(strs);
		if (kr == MACH_SEND_INVALID_DEST || kr == MACH_SEND_INVALID_RIGHT)
			return 0;
		if (kr) {
			LOG("send to stream %x: %#x", s->port, kr);
			s->dropped = 1; // the next batch says so
			return 1;
		}
	}
	return 1;
}

static void stream_free(struct stream* s)
{
	DBG("stream %x gone", s->port);
	if (s->client)
		mach_port_deallocate(mach_task_self(), s->client);
	if (s->port)
		mach_port_mod_refs(mach_task_self(), s->port, MACH_PORT_RIGHT_RECEIVE, -1);
	for (int i = 0; i < s->npaths; i++)
		free(s->paths[i]);
	for (int i = 0; i < s->nexcl; i++)
		free(s->excl[i]);
	for (int i = 0; i < s->npend; i++)
		free(s->pend[i].path);
	free(s->paths);
	free(s->excl);
	free(s->pend);
	memset(s, 0, sizeof *s);
	prune_watches();
}

static void deliver(struct stream* s)
{
	if (!s->npend && !s->dropped)
		return;
	if (s->dropped) {
		for (int j = 0; j < s->npaths; j++)
			pend_add(s, cur_id, FS_MUSTSCAN | FS_USERDROPPED, s->paths[j]);
		s->dropped = 0;
	}
	qsort(s->pend, s->npend, sizeof *s->pend, evcmp_id);
	uint64_t last = s->pend[s->npend - 1].id;
	int ok = send_events(s, s->pend, s->npend);
	for (int i = 0; i < s->npend; i++)
		free(s->pend[i].path);
	s->npend = 0;
	s->deadline = 0;
	s->last_delivery = now_us();
	if (!ok) {
		stream_free(s);
		return;
	}
	if (last > s->last_live)
		s->last_live = last;
}

// the history since s->since, then history-done
static void replay(struct stream* s)
{
	int file = s->flags & CF_FILEEVENTS, n = 0, cap = 64;
	struct ev* ev = malloc(cap * sizeof *ev);
	char buf[2048];
	uint64_t maxid = 0;
	if (s->since < hist_floor)
		// part of what was asked for is no longer kept: rescan, as fseventsd says when its history was purged
		for (int j = 0; j < s->npaths; j++) {
			ev[n++] = (struct ev){ hist_floor, FS_MUSTSCAN | FS_USERDROPPED, strdup(s->paths[j]) };
			if (n == cap)
				ev = realloc(ev, (cap *= 2) * sizeof *ev);
		}
	for (int i = 0; i < hcount; i++) {
		struct hist* h = &hist[(hhead + i) % HISTORY_MAX];
		if (h->id <= s->since)
			continue;
		const char* p = stream_path(s, h->path, file, buf, sizeof buf);
		if (!p)
			continue;
		int k;
		for (k = 0; k < n; k++)
			if (strcmp(ev[k].path, p) == 0)
				break;
		if (k == n) {
			if (n == cap)
				ev = realloc(ev, (cap *= 2) * sizeof *ev);
			ev[n++] = (struct ev){ 0, 0, strdup(p) };
		}
		ev[k].flags |= file ? h->flags : 0;
		if (h->id > ev[k].id)
			ev[k].id = h->id;
		if (h->id > maxid)
			maxid = h->id;
	}
	qsort(ev, n, sizeof *ev, evcmp_path);
	int ok = !n || send_events(s, ev, n);
	for (int i = 0; i < n; i++)
		free(ev[i].path);
	free(ev);
	if (!ok)
		return;
	char* root = s->paths[0];
	struct ev done = { maxid ? maxid : s->since, FS_HISTORYDONE, root };
	send_events(s, &done, 1);
}

static char** copy_paths(uint32_t* offs, uint32_t n, const char* strs, uint32_t size)
{
	char** v = calloc(n + 1, sizeof *v);
	for (uint32_t i = 0; i < n; i++) {
		if (!offs || offs[i] >= size) {
			v[i] = strdup("/");
			continue;
		}
		v[i] = strndup(strs + offs[i], size - offs[i]);
		size_t l = strlen(v[i]);
		while (l > 1 && v[i][l - 1] == '/')
			v[i][--l] = 0;
	}
	return v;
}

static void reply(mach_msg_header_t* req, mach_msg_header_t* r, mach_msg_size_t size)
{
	r->msgh_bits |= MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(req->msgh_bits), 0);
	r->msgh_size = size;
	r->msgh_remote_port = req->msgh_remote_port;
	r->msgh_local_port = MACH_PORT_NULL;
	r->msgh_id = req->msgh_id + 100;
	kern_return_t kr = mach_msg(r, MACH_SEND_MSG | MACH_SEND_TIMEOUT, size, 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
	if (kr)
		LOG("reply %d: %#x", req->msgh_id, kr);
	req->msgh_remote_port = MACH_PORT_NULL;
}

static void reply_ret(mach_msg_header_t* req, kern_return_t ret)
{
	ret_rep r = { .ndr = NDR_record, .ret = ret };
	reply(req, &r.h, sizeof r);
}

static void handle_register(mach_msg_header_t* h)
{
	register_req* q = (register_req*)h;
	register_req_old* o = (register_req_old*)h;
	mach_msg_body_t* body = (mach_msg_body_t*)(h + 1);
	int newform = h->msgh_size == sizeof(register_req) && body->msgh_descriptor_count == 5;
	if (!(h->msgh_bits & MACH_MSGH_BITS_COMPLEX) || (!newform && !(h->msgh_size == sizeof(register_req_old) &&
		body->msgh_descriptor_count == 3))) {
		reply_ret(h, MIG_BAD_ARGUMENTS);
		return;
	}
	mach_msg_port_descriptor_t* pd = newform ? &q->port : &o->port;
	mach_msg_ool_descriptor_t* ool = newform ? q->ool : o->ool;
	int k;
	for (k = 0; k < nstreams && streams[k].used; k++)
		;
	if (k == nstreams) {
		streams = realloc(streams, ++nstreams * sizeof *streams);
		memset(&streams[k], 0, sizeof *streams);
	}
	struct stream* s = &streams[k];
	s->used = 1;
	s->client = pd->name;
	pd->name = MACH_PORT_NULL;
	s->dev = newform ? q->dev : o->dev;
	s->npaths = newform ? q->npaths : o->npaths;
	if (s->npaths > ool[0].size / 4)
		s->npaths = ool[0].size / 4;
	s->paths = copy_paths(ool[0].address, s->npaths, ool[1].address, ool[1].size);
	if (newform) {
		s->nexcl = q->nexcl;
		if (s->nexcl > (int)(ool[2].size / 4))
			s->nexcl = ool[2].size / 4;
		s->excl = copy_paths(ool[2].address, s->nexcl, ool[3].address, ool[3].size);
	}
	s->latency = newform ? q->latency : o->latency;
	s->flags = newform ? q->flags : o->flags;
	s->since = newform ? q->since : o->since;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &s->port);
	mach_port_move_member(mach_task_self(), s->port, pset);
	mach_port_t prev;
	// the client gone (its send right with it): no-senders on the stream's own port (sync 1: once the reply's send
	// right existed; with 0 it fired at once, the port having no senders yet, and every client saw its stream die)
	mach_port_request_notification(mach_task_self(), s->port, MACH_NOTIFY_NO_SENDERS, 1, s->port,
		MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
	if (debug) {
		LOG("register stream %x: dev %u flags %#x latency %llu us since %lld, %d paths, %d excluded", s->port, s->dev,
			s->flags, (unsigned long long)s->latency, (long long)s->since, s->npaths, s->nexcl);
		for (int i = 0; i < s->npaths; i++)
			LOG("  path %s", s->paths[i]);
		for (int i = 0; i < s->nexcl; i++)
			LOG("  exclude %s", s->excl[i]);
	}
	for (int i = 0; i < s->npaths; i++)
		ensure_root(stream_root(s, i));
	register_rep r = { 0 };
	r.h.msgh_bits = MACH_MSGH_BITS_COMPLEX;
	r.body.msgh_descriptor_count = 1;
	r.port = (mach_msg_port_descriptor_t){ .name = s->port, .disposition = MACH_MSG_TYPE_MAKE_SEND, .type = MACH_MSG_PORT_DESCRIPTOR };
	reply(h, &r.h, sizeof r);
	if (s->since != SINCE_NOW) {
		drain();
		replay(s);
	}
}

static struct stream* stream_for(mach_port_t port)
{
	for (int i = 0; i < nstreams; i++)
		if (streams[i].used && streams[i].port == port)
			return &streams[i];
	return NULL;
}

static const char* uuid_for(uint32_t dev)
{
	if (dev == (uint32_t)home_dev)
		return home_uuid;
	if (dev == (uint32_t)root_dev)
		return root_uuid;
	// the volume of a watched path
	for (int i = 0; i < nstreams; i++)
		for (int j = 0; streams[i].used && j < streams[i].npaths; j++) {
			struct stat st;
			if (!streams[i].dev && stat(streams[i].paths[j], &st) == 0 && (uint32_t)st.st_dev == dev)
				return home_uuid;
		}
	return NULL;
}

static void handle(mach_msg_header_t* h)
{
	pthread_mutex_lock(&mu);
	struct stream* s = h->msgh_local_port != svc ? stream_for(h->msgh_local_port) : NULL;
	switch (h->msgh_id) {
	case 1: // wake
		break;
	case MACH_NOTIFY_NO_SENDERS:
		if (s)
			stream_free(s);
		break;
	case 66000:
		handle_register(h);
		break;
	case 66001: { // flush
		u64_rep r = { .ndr = NDR_record };
		if (s) {
			drain();
			deliver(s);
			s = stream_for(h->msgh_local_port);
			r.v = s ? s->last_live : 0;
		}
		reply(h, &r.h, sizeof r);
		break;
	}
	case 66002: { // UUID for device
		dev_req* q = (dev_req*)h;
		uuid_rep r = { .ndr = NDR_record };
		const char* u = h->msgh_size >= offsetof(dev_req, v) ? uuid_for(q->dev) : NULL;
		strncpy(r.uuid, u ? u : "NO-UUID-UNKNOWN-DEVICE", sizeof r.uuid);
		DBG("uuid for dev %#x: %.36s", q->dev, r.uuid);
		reply(h, &r.h, sizeof r);
		break;
	}
	case 66003: { // current event id
		drain();
		u64_rep r = { .ndr = NDR_record, .v = cur_id };
		reply(h, &r.h, sizeof r);
		break;
	}
	case 66004: { // last event id before a time
		dev_req* q = (dev_req*)h;
		u64_rep r = { .ndr = NDR_record };
		uint64_t t = q->v + 978307200; // CFAbsoluteTime -> Unix time
		for (int i = 0; i < hcount; i++) {
			struct hist* e = &hist[(hhead + i) % HISTORY_MAX];
			if (e->t < t)
				r.v = e->id;
		}
		if (t >= (uint64_t)time(NULL) && cur_id > r.v)
			r.v = cur_id;
		reply(h, &r.h, sizeof r);
		break;
	}
	case 66005: { // purge up to an id
		dev_req* q = (dev_req*)h;
		u32_rep r = { .ndr = NDR_record };
		while (hcount && hist[hhead].id <= q->v) {
			if (hist[hhead].id > hist_floor)
				hist_floor = hist[hhead].id;
			free(hist[hhead].path);
			hhead = (hhead + 1) % HISTORY_MAX;
			hcount--;
		}
		hist_compact();
		reply(h, &r.h, sizeof r);
		break;
	}
	case 66006: // unregister
		if (s)
			stream_free(s);
		reply_ret(h, 0);
		break;
	default:
		if (h->msgh_remote_port)
			reply_ret(h, MIG_BAD_ID);
		break;
	}
	pthread_mutex_unlock(&mu);
}

int main(void)
{
	const char* home = getenv("HOME");
	char lp[1024];
	snprintf(lp, sizeof lp, "%s/tmp/x86sim-fseventsd.debug", home ? home : "");
	debug = getenv("X86SIM_FSE_DEBUG") != NULL || access(lp, F_OK) == 0;
	logf_ = stderr;
	setvbuf(stderr, NULL, _IOLBF, 0);
	load_state();
	home_dir = home && *home ? home : NULL;
	ifd = linux_syscall3(L_INOTIFY_INIT1, 02000000 /* IN_CLOEXEC */, 0, 0);
	if (ifd < 0) {
		LOG("inotify_init1: %d", ifd);
		return 1;
	}
	kern_return_t kr = bootstrap_check_in(bootstrap_port, SERVICE, &svc);
	if (kr) {
		LOG("bootstrap_check_in %s: %#x", SERVICE, kr);
		return 1;
	}
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &pset);
	mach_port_move_member(mach_task_self(), svc, pset);
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &wake);
	mach_port_insert_right(mach_task_self(), wake, wake, MACH_MSG_TYPE_MAKE_SEND);
	mach_port_limits_t lim = { 1 };
	mach_port_set_attributes(mach_task_self(), wake, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&lim, MACH_PORT_LIMITS_INFO_COUNT);
	mach_port_move_member(mach_task_self(), wake, pset);
	pthread_t th;
	pthread_create(&th, NULL, inotify_thread, NULL);
	LOG("serving %s; event id %llu, %d events of history, volume %s", SERVICE, (unsigned long long)cur_id, hcount, home_uuid);
	size_t bufsize = 16384;
	mach_msg_header_t* buf = malloc(bufsize);
	uint64_t saved_id = cur_id, saved_at = 0;
	for (;;) {
		// the next stream due
		uint64_t due = 0;
		pthread_mutex_lock(&mu);
		for (int i = 0; i < nstreams; i++)
			if (streams[i].used && streams[i].deadline && (!due || streams[i].deadline < due))
				due = streams[i].deadline;
		pthread_mutex_unlock(&mu);
		uint64_t t = now_us();
		mach_msg_option_t opt = MACH_RCV_MSG | MACH_RCV_LARGE;
		mach_msg_timeout_t to = 0;
		if (due) {
			opt |= MACH_RCV_TIMEOUT;
			to = due > t ? (due - t + 999) / 1000 : 0;
		} else if (cur_id != saved_id) {
			opt |= MACH_RCV_TIMEOUT;
			to = 1000;
		}
		kr = mach_msg(buf, opt, 0, bufsize, pset, to, MACH_PORT_NULL);
		if (kr == MACH_RCV_TOO_LARGE) {
			bufsize = buf->msgh_size + 1024;
			buf = realloc(buf, bufsize);
			continue;
		}
		if (kr == MACH_MSG_SUCCESS) {
			handle(buf);
			mach_msg_destroy(buf);
		} else if (kr != MACH_RCV_TIMED_OUT) {
			LOG("mach_msg: %#x", kr);
		}
		pthread_mutex_lock(&mu);
		t = now_us();
		for (int i = 0; i < nstreams; i++)
			if (streams[i].used && streams[i].deadline && streams[i].deadline <= t)
				deliver(&streams[i]);
		// ids and history on disk at most once a second
		if (cur_id != saved_id && t - saved_at >= 1000000) {
			if (histf)
				fflush(histf);
			save_state();
			saved_id = cur_id;
			saved_at = t;
		}
		pthread_mutex_unlock(&mu);
	}
}
