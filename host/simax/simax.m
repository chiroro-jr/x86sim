// x86Sim: simax, the in-process accessibility reader for agents (snapshot / type / scroll-to; host side:
// tools/launcher/core/src/ax.rs, protocol: docs/protocols/SIMAX.md).
//
// libsimshim dlopens this dylib in every process that has UIKitCore loaded at launch (apps, SpringBoard, view
// services); daemons never load it. Each such process listens on its own Unix socket next to the phone's frame ring:
//   /run/user/<uid>/x86sim-ax-<SIMULATOR_UDID>-<pid>.sock   (inside Darling: /Volumes/SystemRoot/run/user/...)
// The host connects to every one of a phone's sockets, writes one JSON request per line and reads one JSON answer
// line per request. Nothing polls: the listener thread sleeps in accept(), a request runs its UIKit work on the main
// queue (WebKit content: a DOM walk in an isolated JS world of each visible WKWebView) and answers when done.
//
// Requests ({"op": ...}):
//   info                         pid, bundle id, application state, screen, visible windows (cheap: no walk)
//   tree   [all]                 the visible accessibility elements (all: also off-screen ones in scroll views)
//   type   text [clear] [submit] insertText: into the first responder (UIKeyInput), as the software keyboard does
//   scroll oid                   scroll the element's scroll views until it is on screen (accessibilityScrollToVisible)
//   activate oid                 accessibilityActivate (an element a touch cannot reach)
//   ax     [on]                  load UIKit's accessibility bundles in this process (on by default at the first tree)
#include <TargetConditionals.h>
#if TARGET_OS_WATCH
// watchOS's headers mark UIKit unavailable (apps use SwiftUI / WatchKit), but UIKitCore runs every watch app
#include <AvailabilityInternal.h>
#undef __API_UNAVAILABLE_PLATFORM_watchos
#define __API_UNAVAILABLE_PLATFORM_watchos watchos,introduced=2.0
#endif
#import <UIKit/UIKit.h>
#if __has_include(<WebKit/WebKit.h>)
#import <WebKit/WebKit.h>
#define SIMAX_WEB 1
#endif
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>

static const char kSystemRoot[] = "/Volumes/SystemRoot";
static char g_path[256];
static atomic_bool g_ax_loaded;

static void alog(const char* fmt, ...) {
	if (!getenv("X86SIM_AX_LOG")) return;
	va_list ap;
	va_start(ap, fmt);
	char b[1024];
	vsnprintf(b, sizeof(b), fmt, ap);
	va_end(ap);
	fprintf(stderr, "simax[%d]: %s\n", getpid(), b);
}

// ---------------------------------------------------------------------------------------------------------------------
// Accessibility bundles. Without them UIKit answers only for its own controls: SpringBoard's icons, SwiftUI views and
// most system UI have no labels. UIKit loads them at launch when accessibility automation is on (what XCUITest turns
// on); a running process loads them when the AX preference changes. We turn automation on in-process only, the first
// time a process is asked for its tree, so a phone nobody inspects pays nothing.
// true the first time (the caller's answer is then taken before the bundles labelled anything: the host asks again)
static bool load_ax(void) {
	if (atomic_exchange(&g_ax_loaded, true)) return false;
	void* h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY);
	void (*set_auto)(int) = h ? dlsym(h, "_AXSSetAutomationEnabled") : NULL;
	void (*set_app)(int) = h ? dlsym(h, "_AXSApplicationAccessibilitySetEnabled") : NULL;
	if (set_app) set_app(1);
	if (set_auto) set_auto(1);
	// UIKit's own initializer re-reads the settings and loads the bundles for UIKit and this process's frameworks
	void (*init)(void) = dlsym(RTLD_DEFAULT, "_UIAccessibilityInitialize");
	if (init) init();
	alog("ax: automation %p app %p init %p", set_auto, set_app, init);
	return true;
}

// ---------------------------------------------------------------------------------------------------------------------
// Traits. Public ones from UIKit; text entry is a private bit (UIAccessibilityTraitTextEntry, 1 << 18) that UIKit's
// text fields carry once the bundles are in.
static const uint64_t kTraitTextEntry = 1ull << 18;
static const uint64_t kTraitIsEditing = 1ull << 21;
static const uint64_t kTraitTabButton = 1ull << 51;  // UIAccessibilityTraitTabBarItem-ish (private); best effort

// Classes and properties some platforms' headers mark unavailable (UISwitch on tvOS, UITextField on watchOS,
// UIScreen on visionOS) exist at run time all the same: looked up by name
static BOOL is(id o, NSString* cls) {
	Class c = NSClassFromString(cls);
	return c && [o isKindOfClass:c];
}

// a view's rect in screen points (UIKit's accessibility conversion: the coordinates accessibilityFrame uses)
static CGRect to_screen(UIView* v, CGRect r) { return UIAccessibilityConvertFrameToScreenCoordinates(r, v); }

static NSString* role_of(id e, uint64_t t) {
	if ((t & UIAccessibilityTraitSearchField) || (t & kTraitTextEntry) || is(e, @"UITextField") ||
	    (is(e, @"UITextView") && [[e valueForKey:@"editable"] boolValue]))
		return (t & UIAccessibilityTraitSearchField) ? @"searchfield" : @"textfield";
	if (is(e, @"UISwitch")) return @"switch";
	if (@available(iOS 17.0, *))
		if (t & UIAccessibilityTraitToggleButton) return @"switch";
	if (t & UIAccessibilityTraitAdjustable) return @"adjustable";
	if (t & UIAccessibilityTraitKeyboardKey) return @"key";
	if (t & UIAccessibilityTraitTabBar) return @"tabbar";
	if (t & UIAccessibilityTraitLink) return @"link";
	if (t & UIAccessibilityTraitButton) return @"button";
	if (t & UIAccessibilityTraitHeader) return @"heading";
	if (t & UIAccessibilityTraitImage) return @"image";
	if (t & UIAccessibilityTraitStaticText) return @"text";
	return @"element";
}

static NSArray* trait_names(uint64_t t) {
	NSMutableArray* a = [NSMutableArray array];
	if (t & UIAccessibilityTraitSelected) [a addObject:@"selected"];
	if (t & UIAccessibilityTraitNotEnabled) [a addObject:@"disabled"];
	if (t & UIAccessibilityTraitHeader) [a addObject:@"header"];
	if (t & UIAccessibilityTraitImage) [a addObject:@"image"];
	if (t & UIAccessibilityTraitAdjustable) [a addObject:@"adjustable"];
	if (t & UIAccessibilityTraitUpdatesFrequently) [a addObject:@"updates"];
	if (t & kTraitIsEditing) [a addObject:@"editing"];
	(void)kTraitTabButton;
	return a;
}

static NSString* str(id v) {
	if (!v) return nil;
	if ([v isKindOfClass:[NSString class]]) return [(NSString*)v length] ? v : nil;
	if ([v isKindOfClass:[NSAttributedString class]]) { NSString* s = [v string]; return s.length ? s : nil; }
	if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
	return nil;
}

static NSString* hex(id o) { return [NSString stringWithFormat:@"%lx", (unsigned long)(uintptr_t)(__bridge void*)o]; }

// ---------------------------------------------------------------------------------------------------------------------
// The walk: UIKit's accessibility containment as VoiceOver follows it (an element is a leaf; a container gives
// accessibilityElements or the count / index pair; a plain view its subviews), skipping hidden views and what a modal
// sibling (accessibilityViewIsModal: alerts, sheets) covers, and anything outside the screen unless asked.
typedef struct {
	NSMutableArray* out;
	NSMutableArray* webviews;   // WKWebViews on screen, walked by JS afterwards
	NSMutableSet* seen;
	CGRect screen;
	BOOL all;
	int win;                     // index of the window being walked
	id focus;                    // the first responder
	int budget;                  // max nodes visited
	NSMutableDictionary* nth;    // per cell key + role: how many elements of that role the cell gave so far
} Walk;

// ---------------------------------------------------------------------------------------------------------------------
// Stable keys. A cell is recycled while a list scrolls: the same object shows another row, and another object the row
// it showed. What stays is the row's index path in its table / collection view, so an element in a cell is keyed by
// "<list oid>:<section>.<item>/<role><n>" (n: the n-th element of that role in the cell). The host keeps refs on keys.
static UIView* view_of(id e) {
	id o = e;
	for (int i = 0; i < 24 && o; i++) {
		if ([o isKindOfClass:[UIView class]]) return o;
		@try { o = [o respondsToSelector:@selector(accessibilityContainer)] ? [o accessibilityContainer] : nil; } @catch (id ex) { o = nil; }
	}
	return nil;
}

static NSString* cell_key(id e) {
	UIView* cell = nil;
	BOOL table = NO;
	for (UIView* p = view_of(e); p; p = p.superview) {
		if (is(p, @"UITableViewCell")) { cell = p; table = YES; break; }
		if (is(p, @"UICollectionViewCell")) { cell = p; break; }
	}
	if (!cell) return nil;
	UIView* list = cell.superview;
	while (list && !is(list, table ? @"UITableView" : @"UICollectionView")) list = list.superview;
	if (!list) return nil;
	NSIndexPath* ip = nil;
	@try { ip = ((id(*)(id, SEL, id))objc_msgSend)(list, NSSelectorFromString(@"indexPathForCell:"), cell); } @catch (id ex) { ip = nil; }
	if (!ip || ip.length < 2) return nil;
	return [NSString stringWithFormat:@"%@:%ld.%ld", hex(list), (long)[ip indexAtPosition:0], (long)[ip indexAtPosition:1]];
}

static BOOL view_hidden(UIView* v) {
	return v.hidden || v.alpha < 0.01 || v.accessibilityElementsHidden;
}

static NSArray* children_of(id o) {
	if ([o respondsToSelector:@selector(accessibilityElements)]) {
		NSArray* a = nil;
		@try { a = [o accessibilityElements]; } @catch (id ex) { a = nil; }
		if (a.count) return a;
	}
	NSInteger n = 0;
	@try { n = [o accessibilityElementCount]; } @catch (id ex) { n = 0; }
	if (n > 0 && n != NSNotFound) {
		NSMutableArray* a = [NSMutableArray arrayWithCapacity:n];
		for (NSInteger i = 0; i < n && i < 2000; i++) {
			id c = nil;
			@try { c = [o accessibilityElementAtIndex:i]; } @catch (id ex) { c = nil; }
			if (c) [a addObject:c];
		}
		return a;
	}
	if ([o isKindOfClass:[UIView class]]) {
		// front-most last in subviews; keep that order (top to bottom reading order is the host's business)
		return [(UIView*)o subviews];
	}
	return @[];
}

static void emit(Walk* w, id e, int depth, NSString* container) {
	CGRect f = CGRectZero;
	@try { f = [e accessibilityFrame]; } @catch (id ex) { return; }
	if (CGRectIsNull(f) || CGRectIsInfinite(f)) return;
	BOOL on = CGRectIntersectsRect(f, w->screen) && f.size.width > 0.5 && f.size.height > 0.5;
	if (!on && !w->all) return;
	uint64_t t = 0;
	NSString *label = nil, *value = nil, *ident = nil, *hint = nil;
	@try {
		t = [e accessibilityTraits];
		label = str([e accessibilityLabel]);
		value = str([e accessibilityValue]);
		hint = str([e accessibilityHint]);
		if ([e respondsToSelector:@selector(accessibilityIdentifier)]) ident = str([e accessibilityIdentifier]);
	} @catch (id ex) {
	}
	NSString* role = role_of(e, t);
	if ([role isEqualToString:@"element"] && [NSStringFromClass([e class]) hasSuffix:@"IconView"]) role = @"icon";
	if (!label && !value && !ident && [role isEqualToString:@"element"]) return;  // nothing to say, nothing to act on
	if ([role isEqualToString:@"textfield"] || [role isEqualToString:@"searchfield"]) {
		// a field's placeholder: its label when it has none
		if (!label && [e respondsToSelector:@selector(placeholder)]) label = str([e placeholder]);
	}
	if (is(e, @"UISwitch")) value = [[e valueForKey:@"on"] boolValue] ? @"1" : @"0";
	NSMutableDictionary* d = [NSMutableDictionary dictionary];
	d[@"oid"] = hex(e);
	d[@"role"] = role;
	if (label) d[@"label"] = label.length > 400 ? [label substringToIndex:400] : label;
	if (value) d[@"value"] = value.length > 400 ? [value substringToIndex:400] : value;
	if (ident) d[@"id"] = ident;
	if (hint) d[@"hint"] = hint;
	d[@"frame"] = @[ @(round(f.origin.x * 10) / 10), @(round(f.origin.y * 10) / 10), @(round(f.size.width * 10) / 10),
		@(round(f.size.height * 10) / 10) ];
	NSArray* tn = trait_names(t);
	if (tn.count) d[@"traits"] = tn;
	if (t & UIAccessibilityTraitNotEnabled) d[@"enabled"] = @NO;
	if (t & UIAccessibilityTraitSelected) d[@"selected"] = @YES;
	BOOL focused = w->focus && (e == w->focus || ([e isKindOfClass:[UIView class]] && [w->focus isKindOfClass:[UIView class]] &&
		[(UIView*)w->focus isDescendantOfView:(UIView*)e]));
	if (focused || (t & kTraitIsEditing)) d[@"focused"] = @YES;
	if (!on) d[@"offscreen"] = @YES;
	d[@"win"] = @(w->win);
	d[@"depth"] = @(depth);
	if (container) d[@"in"] = container;
	d[@"class"] = NSStringFromClass([e class]);
	NSString* ck = cell_key(e);
	if (ck) {
		NSString* k = [ck stringByAppendingFormat:@"/%@", role];
		int n = [w->nth[k] intValue];
		w->nth[k] = @(n + 1);
		d[@"key"] = [k stringByAppendingFormat:@"%d", n];
	}
	[w->out addObject:d];
}

static void walk(Walk* w, id o, int depth, NSString* container) {
	if (!o || depth > 80 || --w->budget < 0) return;
	if ([w->seen containsObject:[NSValue valueWithPointer:(__bridge void*)o]]) return;
	[w->seen addObject:[NSValue valueWithPointer:(__bridge void*)o]];
	if ([o isKindOfClass:[UIView class]]) {
		UIView* v = o;
		if (view_hidden(v)) return;
#if SIMAX_WEB
		if ([v isKindOfClass:[WKWebView class]]) {
			CGRect f = to_screen(v, v.bounds);
			if (CGRectIntersectsRect(f, w->screen)) [w->webviews addObject:@{ @"view": v, @"win": @(w->win), @"depth": @(depth) }];
			return;   // its content comes from the DOM walk (the AX tree of a web page lives in another process)
		}
#endif
		// off-screen subtrees: skip unless all (a scroll view's content is checked element by element)
		if (!w->all && ![v isKindOfClass:[UIScrollView class]]) {
			CGRect f = to_screen(v, v.bounds);
			if (!v.clipsToBounds) f = CGRectInset(f, -2000, -2000);   // children may draw outside a non-clipping view
			if (!CGRectIntersectsRect(f, w->screen) && v.subviews.count < 50) return;
		}
	} else if ([o respondsToSelector:@selector(accessibilityElementsHidden)] && [o accessibilityElementsHidden]) {
		return;
	}
	BOOL leaf = NO;
	@try { leaf = [o isAccessibilityElement]; } @catch (id ex) { leaf = NO; }
	if (leaf) {
		emit(w, o, depth, container);
		// UIKit leaves can still host editable / web content deeper (a cell with a text field): look inside views
		if (![o isKindOfClass:[UIView class]]) return;
		BOOL deeper = NO;
		for (UIView* s in [(UIView*)o subviews])
			if (is(s, @"UITextField") || is(s, @"UISwitch")) deeper = YES;
		if (!deeper) return;
	}
	NSArray* kids = children_of(o);
	// a modal child hides its siblings (VoiceOver's rule)
	for (id c in kids) {
		@try {
			if ([c respondsToSelector:@selector(accessibilityViewIsModal)] && [c accessibilityViewIsModal] &&
			    !([c isKindOfClass:[UIView class]] && view_hidden(c))) {
				kids = @[ c ];
				break;
			}
		} @catch (id ex) {
		}
	}
	NSString* here = container;
	if (!leaf) {
		NSString* l = nil;
		@try { l = str([o accessibilityLabel]); } @catch (id ex) { l = nil; }
		if (l && l.length < 80) here = l;
	}
	for (id c in kids) walk(w, c, depth + 1, here);
}

#if SIMAX_WEB
// ---------------------------------------------------------------------------------------------------------------------
// WebKit content: a DOM walk in an isolated content world (page scripts cannot see or break it; CSP does not apply),
// in every frame of the page (iframes too, same-origin or not: WKWebView's frame tree, one evaluation per frame),
// returning the visible meaningful elements with CSS-pixel rects. A child frame's rects are moved by its <iframe>'s
// content box in the parent and clipped to it; the main frame's are converted to screen points through the web view's
// scroll view (content coordinates = page coordinates * zoomScale).
//
// Keys: each element gets a number the first time a walk sees it, kept in a WeakMap of the isolated world (the same DOM
// node keeps its number for the life of the document, wherever it scrolls), prefixed by a random tag of that world (a
// new document, a new tag): "dom:<tag>.<n>". The host keeps refs on it, so repeated text ("by", "|") never trades refs.
static NSString* const kDomWalker = @
	"(() => {"
	"const out = []; const frames = []; const vw = innerWidth, vh = innerHeight; const all = %@;"
	"if (!window.__simax) window.__simax = { tag: Math.random().toString(36).slice(2, 8), ids: new WeakMap(), n: 0 };"
	"const S = window.__simax; const key = el => { let k = S.ids.get(el); if (k === undefined) { k = ++S.n; S.ids.set(el, k); } return 'dom:' + S.tag + '.' + k; };"
	"const role = el => { const r = el.getAttribute('role'); if (r) return r; const t = el.tagName.toLowerCase();"
	"  if (t === 'a' && el.hasAttribute('href')) return 'link'; if (t === 'button' || t === 'summary') return 'button';"
	"  if (t === 'input') { const ty = (el.type || 'text').toLowerCase();"
	"    if (['button','submit','reset','image'].includes(ty)) return 'button'; if (ty === 'checkbox') return 'checkbox';"
	"    if (ty === 'radio') return 'radio'; if (ty === 'range') return 'adjustable'; if (ty === 'hidden') return null;"
	"    return ty === 'search' ? 'searchfield' : 'textfield'; }"
	"  if (t === 'textarea' || el.isContentEditable) return 'textfield'; if (t === 'select') return 'popup';"
	"  if (/^h[1-6]$/.test(t)) return 'heading'; if (t === 'img') return el.alt ? 'image' : null; return null; };"
	"const shown = el => { const s = getComputedStyle(el); return s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity > 0.01; };"
	"const visible = (el, r) => { if (r.width < 1 || r.height < 1) return false;"
	"  if (!all && (r.bottom < 0 || r.right < 0 || r.top > vh || r.left > vw)) return false; return shown(el); };"
	"const name = el => { const l = el.getAttribute('aria-label'); if (l) return l;"
	"  const lb = el.getAttribute('aria-labelledby'); if (lb) { const n = document.getElementById(lb); if (n) return n.innerText; }"
	"  if (el.labels && el.labels.length) return el.labels[0].innerText;"
	"  if (el.tagName === 'IMG') return el.alt; if (el.tagName === 'INPUT' && ['button','submit','reset'].includes(el.type)) return el.value;"
	"  if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return el.placeholder || el.name || '';"
	"  return (el.innerText || el.textContent || '').trim(); };"
	// an <iframe>: where its document's viewport sits (its content box), for the frame's own walk
	"const frame = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);"
	"  const pl = parseFloat(s.paddingLeft) || 0, pt = parseFloat(s.paddingTop) || 0, pr = parseFloat(s.paddingRight) || 0, pb = parseFloat(s.paddingBottom) || 0;"
	"  let src = ''; try { src = el.hasAttribute('srcdoc') ? 'about:srcdoc' : (el.src || 'about:blank'); } catch (e) {}"
	"  frames.push({ src, name: el.name || '', x: r.left + el.clientLeft + pl, y: r.top + el.clientTop + pt, w: Math.max(0, el.clientWidth - pl - pr),"
	"    h: Math.max(0, el.clientHeight - pt - pb), shown: r.width >= 1 && r.height >= 1 && shown(el) }); };"
	"const walk = (root) => { const it = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT); let el = it.currentNode;"
	"  while (el && out.length < 600) { let skip = false;"
	"    if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') { frame(el); skip = true; }"
	"    const r0 = skip ? null : role(el);"
	"    if (!skip && (r0 !== null || (el.childElementCount === 0 || [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim().length > 1)))) {"
	"      const r = el.getBoundingClientRect();"
	"      if (visible(el, r)) {"
	"        let rl = r0; let label = name(el);"
	"        if (!rl) { const own = [...el.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join(' ').replace(/\\s+/g, ' ').trim();"
	"          if (own.length > 1) { rl = 'text'; label = own; } }"
	"        if (rl) { const e = { role: rl, label: (label || '').replace(/\\s+/g, ' ').trim().slice(0, 300), x: r.left, y: r.top, w: r.width, h: r.height, key: key(el) };"
	"          if (el.id) e.id = el.id; if ('value' in el && rl !== 'button' && el.value !== undefined && el.value !== '') e.value = String(el.value).slice(0, 300);"
	"          if (el.disabled) e.enabled = false; if (el.checked) e.selected = true; if (document.activeElement === el) e.focused = true;"
	"          if (rl === 'link') e.href = el.href; out.push(e);"
	"          if (r0 && rl !== 'text' && rl !== 'heading') skip = true; }"
	"      } }"
	"    if (skip) { let n = it.nextSibling(); while (!n && it.parentNode()) n = it.nextSibling(); el = n; } else el = it.nextNode(); } };"
	"walk(document.body || document.documentElement);"
	"return JSON.stringify({ url: location.href, title: document.title, sx: scrollX, sy: scrollY, vw, vh, items: out, frames });"
	"})()";

// The frames of a web view, parents before children: [{info: WKFrameInfo, parent: index or -1}]
static void flatten_frames(id node, int parent, NSMutableArray* out) {
	if (!node || out.count > 40) return;
	id info = [node isKindOfClass:[WKFrameInfo class]] ? node : ([node respondsToSelector:@selector(info)] ? [node valueForKey:@"info"] : nil);
	int me = (int)out.count;
	[out addObject:@{ @"info": info ?: [NSNull null], @"parent": @(parent) }];
	id kids = [node respondsToSelector:NSSelectorFromString(@"childFrames")] ? [node valueForKey:@"childFrames"] : nil;
	for (id c in kids) flatten_frames(c, me, out);
}

static NSString* frame_url(id info) {
	if (![info isKindOfClass:[WKFrameInfo class]]) return @"";
	return ((WKFrameInfo*)info).request.URL.absoluteString ?: @"";
}

// Places every frame's items in the main frame's client coordinates and converts them to screen points.
static NSArray* web_compose(WKWebView* v, NSArray* nodes, NSArray* results, BOOL all, int win, int depth) {
	NSMutableArray* out = [NSMutableArray array];
	if (!results.count || ![results[0] isKindOfClass:[NSDictionary class]]) return out;
	NSDictionary* page = results[0];
	UIScrollView* sv = v.scrollView;
	CGFloat zoom = sv.zoomScale > 0 ? sv.zoomScale : 1;
	CGRect vis = to_screen(v, v.bounds);
	double sx = [page[@"sx"] doubleValue], sy = [page[@"sy"] doubleValue];
	NSUInteger n = nodes.count;
	CGPoint* off = calloc(n, sizeof(CGPoint));
	CGRect* clip = calloc(n, sizeof(CGRect));
	BOOL* placed = calloc(n, sizeof(BOOL));
	NSMutableArray* used = [NSMutableArray array];   // per frame: its <iframe> entries taken by a child
	for (NSUInteger i = 0; i < n; i++) [used addObject:[NSMutableIndexSet indexSet]];
	off[0] = CGPointZero;
	clip[0] = all ? CGRectInfinite : CGRectMake(0, 0, [page[@"vw"] doubleValue], [page[@"vh"] doubleValue]);
	placed[0] = YES;
	int count = 0;
	for (NSUInteger i = 0; i < n; i++) {
		NSDictionary* res = [results[i] isKindOfClass:[NSDictionary class]] ? results[i] : nil;
		int p = [nodes[i][@"parent"] intValue];
		if (i > 0) {
			// a child frame: its <iframe> in the parent, by URL, else the parent's next unclaimed one (document order)
			NSDictionary* pres = (p >= 0 && placed[p] && [results[p] isKindOfClass:[NSDictionary class]]) ? results[p] : nil;
			NSArray* fr = pres[@"frames"];
			NSString* u1 = res[@"url"] ?: @"", *u2 = frame_url(nodes[i][@"info"]);
			NSInteger hit = NSNotFound;
			for (NSUInteger k = 0; k < fr.count && hit == NSNotFound; k++)
				if (![used[p] containsIndex:k] && ([fr[k][@"src"] isEqual:u1] || [fr[k][@"src"] isEqual:u2])) hit = k;
			for (NSUInteger k = 0; k < fr.count && hit == NSNotFound; k++)
				if (![used[p] containsIndex:k]) hit = k;
			if (hit == NSNotFound || ![fr[hit][@"shown"] boolValue]) {
				if (hit != NSNotFound) [used[p] addIndex:hit];
				alog("web: frame %lu (%s) not placed", (unsigned long)i, u1.UTF8String);
				continue;
			}
			[used[p] addIndex:hit];
			NSDictionary* f = fr[hit];
			off[i] = CGPointMake(off[p].x + [f[@"x"] doubleValue], off[p].y + [f[@"y"] doubleValue]);
			CGRect box = CGRectMake(off[i].x, off[i].y, [f[@"w"] doubleValue], [f[@"h"] doubleValue]);
			clip[i] = CGRectIntersection(clip[p], box);
			placed[i] = YES;
		}
		if (!res) continue;
		for (NSDictionary* it in res[@"items"]) {
			CGRect c = CGRectMake([it[@"x"] doubleValue] + off[i].x, [it[@"y"] doubleValue] + off[i].y, [it[@"w"] doubleValue], [it[@"h"] doubleValue]);
			// an item a frame's box cuts off: not visible (its part inside is what shows)
			BOOL inside = CGRectIntersectsRect(c, clip[i]);
			if (!inside && (i > 0 || !all)) continue;
			if (i > 0) c = CGRectIntersection(c, clip[i]);
			// client rect -> page coordinates -> the scroll view's content coordinates -> screen
			CGPoint pc = CGPointMake((c.origin.x + sx) * zoom, (c.origin.y + sy) * zoom);
			CGPoint s = to_screen(sv, CGRectMake(pc.x, pc.y, 0, 0)).origin;
			CGRect f = CGRectMake(s.x, s.y, c.size.width * zoom, c.size.height * zoom);
			BOOL on = CGRectIntersectsRect(f, vis);
			if (!on && !all) continue;
			NSMutableDictionary* d = [NSMutableDictionary dictionary];
			for (NSString* k in @[ @"role", @"label", @"value", @"id", @"enabled", @"selected", @"focused", @"href", @"key" ])
				if (it[k]) d[k] = it[k];
			d[@"oid"] = [NSString stringWithFormat:@"%@#%@", hex(v), it[@"key"] ?: @(count)];
			count++;
			d[@"frame"] = @[ @(round(f.origin.x * 10) / 10), @(round(f.origin.y * 10) / 10), @(round(f.size.width * 10) / 10),
				@(round(f.size.height * 10) / 10) ];
			d[@"win"] = @(win);
			d[@"depth"] = @(depth + 1);
			d[@"web"] = @YES;
			if (i > 0) d[@"frame_url"] = res[@"url"] ?: @"";
			if (!on) d[@"offscreen"] = @YES;
			[out addObject:d];
		}
	}
	free(off);
	free(clip);
	free(placed);
	[out addObject:@{ @"role": @"webview", @"oid": hex(v), @"label": page[@"title"] ?: @"", @"value": page[@"url"] ?: @"",
		@"frame": @[ @(vis.origin.x), @(vis.origin.y), @(vis.size.width), @(vis.size.height) ], @"win": @(win), @"depth": @(depth),
		@"web": @YES, @"meta": @YES }];
	return out;
}

// Reads one web view: every frame's DOM, then done(items, pending) exactly once, on the main queue: when every frame
// answered, or at `deadline` seconds with the frames that did (pending: how many did not; a busy WebContent process
// must not cost the whole snapshot)
static void walk_web(NSDictionary* wv, BOOL all, double deadline, void (^done)(NSArray* items, int pending)) {
	WKWebView* v = wv[@"view"];
	int win = [wv[@"win"] intValue], depth = [wv[@"depth"] intValue];
	NSString* js = [NSString stringWithFormat:kDomWalker, all ? @"true" : @"false"];
	__block BOOL finished = NO;
	__block NSArray* nodes = @[ @{ @"info": [NSNull null], @"parent": @(-1) } ];
	NSMutableArray* results = [NSMutableArray arrayWithObject:[NSNull null]];
	__block int waiting = 1;
	void (^finish)(void) = ^{
		if (finished) return;
		finished = YES;
		done(web_compose(v, nodes, results, all, win, depth), waiting);
	};
	void (^eval)(id, NSUInteger) = ^(id info, NSUInteger i) {
		void (^got)(id, NSError*) = ^(id res, NSError* err) {
			if (finished) return;
			if (!err && [res isKindOfClass:[NSString class]]) {
				id page = [NSJSONSerialization JSONObjectWithData:[res dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
				if ([page isKindOfClass:[NSDictionary class]]) results[i] = page;
			} else {
				alog("web frame %lu: %s", (unsigned long)i, err.description.UTF8String ?: "no result");
			}
			if (--waiting == 0) finish();
		};
		if (@available(iOS 14.0, *))
			[v evaluateJavaScript:js inFrame:[info isKindOfClass:[WKFrameInfo class]] ? info : nil inContentWorld:[WKContentWorld defaultClientWorld]
				completionHandler:got];
		else
			[v evaluateJavaScript:js completionHandler:got];
	};
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(); });
	// WebKit's frame tree (SPI, iOS 15+): every frame, iframes of other origins included
	SEL fs = NSSelectorFromString(@"_frames:");
	if (![v respondsToSelector:fs]) {
		eval(nil, 0);
		return;
	}
	((void (*)(id, SEL, id))objc_msgSend)(v, fs, ^(id root) {
		if (finished) return;
		NSMutableArray* fl = [NSMutableArray array];
		flatten_frames(root, -1, fl);
		if (fl.count < 2) {
			eval(nil, 0);
			return;
		}
		nodes = fl;
		while (results.count < fl.count) [results addObject:[NSNull null]];
		waiting = (int)fl.count;
		// the main frame through nil (its WKFrameInfo is the same frame)
		for (NSUInteger i = 0; i < fl.count; i++) eval(i == 0 ? nil : fl[i][@"info"], i);
	});
}

#endif

// ---------------------------------------------------------------------------------------------------------------------
static UIResponder* first_responder(void) {
	UIApplication* app = UIApplication.sharedApplication;
	for (UIScene* sc in app.connectedScenes) {
		if (![sc isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow* win in ((UIWindowScene*)sc).windows) {
			if (![win respondsToSelector:@selector(firstResponder)]) continue;
			UIResponder* r = ((id(*)(id, SEL))objc_msgSend)(win, @selector(firstResponder));
			if (r) return r;
		}
	}
	return nil;
}

static NSArray<UIWindow*>* visible_windows(void) {
	NSMutableArray* a = [NSMutableArray array];
	UIApplication* app = UIApplication.sharedApplication;
	for (UIScene* sc in app.connectedScenes) {
		if (![sc isKindOfClass:[UIWindowScene class]]) continue;
		if (sc.activationState == UISceneActivationStateBackground || sc.activationState == UISceneActivationStateUnattached) continue;
		for (UIWindow* win in ((UIWindowScene*)sc).windows) {
			if (win.hidden || win.alpha < 0.01 || win.bounds.size.width < 1) continue;
			[a addObject:win];
		}
	}
	// the software keyboard: UIKit's keyboard window (UIRemoteKeyboardWindow) is not one of a scene's windows; its keys
	// are what an agent reads while the keyboard is up (Toggle Software Keyboard, a disconnected hardware keyboard)
	SEL all = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
	if ([UIWindow respondsToSelector:all]) {
		NSArray* every = ((NSArray * (*)(id, SEL, BOOL, BOOL)) objc_msgSend)([UIWindow class], all, YES, YES);
		for (UIWindow* win in every) {
			if (![win isKindOfClass:[UIWindow class]] || [a containsObject:win]) continue;
			if (![NSStringFromClass([win class]) containsString:@"Keyboard"]) continue;
			if (win.hidden || win.alpha < 0.01 || win.bounds.size.width < 1) continue;
			[a addObject:win];
		}
	}
	// back to front
	[a sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(UIWindow* x, UIWindow* y) {
		return x.windowLevel < y.windowLevel ? NSOrderedAscending : x.windowLevel > y.windowLevel ? NSOrderedDescending : NSOrderedSame;
	}];
	return a;
}

// A one-shot Core Animation animation still running in the window (a push, a sheet, an alert coming up): the host
// waits for it before it reports "the screen after" an action. Looping ones (spinners, the caret) do not count.
static NSString* g_anim_what;   // the animation animating_layer found (for X86SIM_AX_LOG and the answer)
static BOOL animating_layer(CALayer* l, int* budget) {
	if (--*budget < 0 || l.hidden) return NO;
	for (NSString* k in l.animationKeys) {
		CAAnimation* a = [l animationForKey:k];
		if (a.repeatCount > 1 || a.repeatDuration > 0 || a.duration > 3 || a.autoreverses) continue;
		// one that has run its course but stays (removedOnCompletion = NO, a fill mode keeping its end state): done
		CFTimeInterval now = [l convertTime:CACurrentMediaTime() fromLayer:nil];
		if (!a.removedOnCompletion && a.beginTime > 0 && now > a.beginTime + a.duration * MAX(1.0f, a.repeatCount) + 0.1) continue;
		g_anim_what = [NSString stringWithFormat:@"%@ %@ %@ %.2fs%@", NSStringFromClass([l.delegate class] ?: [l class]), k,
			NSStringFromClass([a class]), a.duration, a.removedOnCompletion ? @"" : @" (kept)"];
		return YES;
	}
	for (CALayer* c in l.sublayers)
		if (animating_layer(c, budget)) return YES;
	return NO;
}

// the screen in points: UIScreen where the platform has one (visionOS has none: the key window's bounds)
static CGRect screen_bounds(void) {
	id scr = ((id(*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIScreen"), NSSelectorFromString(@"mainScreen"));
	if (scr) return ((CGRect(*)(id, SEL))objc_msgSend)(scr, @selector(bounds));
	for (UIWindow* w in visible_windows()) return to_screen(w, w.bounds);
	return CGRectMake(0, 0, 1, 1);
}
static double screen_scale(void) {
	id scr = ((id(*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIScreen"), NSSelectorFromString(@"mainScreen"));
	if (scr) return ((CGFloat(*)(id, SEL))objc_msgSend)(scr, NSSelectorFromString(@"scale"));
	return 2;
}

// The bounds of the screen a window is on (its coordinates are that screen's: UIAccessibilityConvertFrameToScreenCoordinates)
static CGRect window_screen(UIWindow* w) {
	id scr = w.windowScene ? [w.windowScene valueForKey:@"screen"] : nil;
	if (scr) return ((CGRect(*)(id, SEL))objc_msgSend)(scr, @selector(bounds));
	return screen_bounds();
}

// A screen's display (simfb names them x86Sim-main-display, x86Sim-display-<id>) and how its coordinate space (which
// turns with the interface) sits in its fixed one (the screen's own, whatever the interface does): where the unit x
// vector goes, and the fixed bounds. The host turns touches by that, so it needs no table of orientation names.
static void screen_geometry(id scr, NSMutableDictionary* d) {
	if (!scr) return;
	@try { id did = [scr valueForKey:@"_displayID"]; if (did) d[@"display"] = [did description]; } @catch (id ex) {}
	@try {
		id cs = [scr valueForKey:@"coordinateSpace"], fs = [scr valueForKey:@"fixedCoordinateSpace"];
		if (cs && fs) {
			SEL conv = NSSelectorFromString(@"convertPoint:toCoordinateSpace:");
			CGPoint o = ((CGPoint(*)(id, SEL, CGPoint, id))objc_msgSend)(cs, conv, CGPointMake(0, 0), fs);
			CGPoint x = ((CGPoint(*)(id, SEL, CGPoint, id))objc_msgSend)(cs, conv, CGPointMake(100, 0), fs);
			CGRect fb = ((CGRect(*)(id, SEL))objc_msgSend)(fs, @selector(bounds));
			d[@"fixed"] = @[ @(round((x.x - o.x) / 100)), @(round((x.y - o.y) / 100)) ];
			d[@"fixed_size"] = @[ @(fb.size.width), @(fb.size.height) ];
		}
	} @catch (id ex) {}
}

// UIWindowScene.interfaceOrientation (by name: tvOS / watchOS headers mark it unavailable)
static NSNumber* orient_of(UIWindowScene* sc) {
	@try { id o = [sc valueForKey:@"interfaceOrientation"]; return [o isKindOfClass:[NSNumber class]] ? o : @0; } @catch (id ex) { return @0; }
}

static NSMutableDictionary* info(void) {
	UIApplication* app = UIApplication.sharedApplication;
	NSMutableDictionary* d = [NSMutableDictionary dictionary];
	d[@"pid"] = @(getpid());
	d[@"bundle"] = NSBundle.mainBundle.bundleIdentifier ?: [NSString stringWithUTF8String:getprogname()];
	d[@"process"] = [NSString stringWithUTF8String:getprogname()];
	if (!app) {
		d[@"state"] = @"none";
		return d;
	}
	UIApplicationState st = app.applicationState;
	d[@"state"] = st == UIApplicationStateActive ? @"active" : st == UIApplicationStateInactive ? @"inactive" : @"background";
	CGRect b = screen_bounds();
	d[@"screen"] = @[ @(b.size.width), @(b.size.height), @(screen_scale()) ];
	NSMutableArray* ws = [NSMutableArray array];
	NSArray* vw = visible_windows();
	UIWindow* primary = nil;
	for (UIWindow* w in vw) {
		CGRect f = to_screen(w, w.bounds);
		NSMutableDictionary* wd = [@{ @"class": NSStringFromClass([w class]), @"level": @(w.windowLevel), @"key": @(w.isKeyWindow),
			@"frame": @[ @(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height) ] } mutableCopy];
		UIWindowScene* sc = w.windowScene;
		if (sc) wd[@"orient"] = orient_of(sc);
		id scr = sc ? [sc valueForKey:@"screen"] : nil;
		if (scr) {
			CGRect sb = ((CGRect(*)(id, SEL))objc_msgSend)(scr, @selector(bounds));
			wd[@"screen"] = @[ @(sb.size.width), @(sb.size.height) ];
			screen_geometry(scr, wd);
		}
		[ws addObject:wd];
		// the window that says how this process sees the screen: its key window, else its largest
		CGFloat area = w.bounds.size.width * w.bounds.size.height, parea = primary.bounds.size.width * primary.bounds.size.height;
		if (!primary || (w.isKeyWindow && !primary.isKeyWindow) || (!primary.isKeyWindow && area > parea)) primary = w;
	}
	d[@"windows"] = ws;
	// the interface orientation (UIInterfaceOrientation: 1 portrait, 2 upside down, 3 landscape left, 4 landscape right)
	// and the screen of the primary window: frames are in that screen's coordinate space, which turns with the interface
	// (a portrait-only app on a phone held landscape stays portrait); on a two-screen phone, the screen it is on
	if (primary.windowScene) {
		d[@"orient"] = orient_of(primary.windowScene);
		id scr = [primary.windowScene valueForKey:@"screen"];
		if (scr) {
			CGRect sb = ((CGRect(*)(id, SEL))objc_msgSend)(scr, @selector(bounds));
			d[@"screen"] = @[ @(sb.size.width), @(sb.size.height), @(((CGFloat(*)(id, SEL))objc_msgSend)(scr, NSSelectorFromString(@"scale"))) ];
			id main = ((id(*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIScreen"), NSSelectorFromString(@"mainScreen"));
			d[@"main_screen"] = @(scr == main);
			screen_geometry(scr, d);
		}
	}
	d[@"ax"] = @(atomic_load(&g_ax_loaded));
	return d;
}

static void tree(NSDictionary* req, void (^reply)(NSDictionary*)) {
	NSMutableDictionary* d = info();
	// fg: only a process on screen walks (a background app answers its state and nothing else, and loads nothing)
	if ([req[@"fg"] boolValue] && ![d[@"state"] isEqualToString:@"active"] && ![d[@"state"] isEqualToString:@"inactive"]) {
		reply(d);
		return;
	}
	if (![req[@"noax"] boolValue] && load_ax()) d[@"ax_fresh"] = @YES;
	if (!UIApplication.sharedApplication) {
		reply(d);
		return;
	}
	Walk w = { 0 };
	w.out = [NSMutableArray array];
	w.webviews = [NSMutableArray array];
	w.seen = [NSMutableSet set];
	w.nth = [NSMutableDictionary dictionary];
	w.screen = screen_bounds();
	w.all = [req[@"all"] boolValue];
	w.focus = first_responder();
	w.budget = 20000;
	NSArray* wins = visible_windows();
	// front to back: a modal window on top (an alert) hides the windows below it from VoiceOver too, but they are still
	// on screen; the host decides (it knows every process's windows)
	for (int i = 0; i < (int)wins.count; i++) {
		w.win = i;
		w.screen = window_screen(wins[i]);
		walk(&w, wins[i], 0, nil);
	}
	if (w.focus) d[@"focus"] = hex(w.focus);
	int budget = 5000;
	for (UIWindow* win in wins)
		if (animating_layer(win.layer, &budget)) {
			d[@"animating"] = @YES;
			if (g_anim_what) d[@"animating_what"] = g_anim_what;
			break;
		}
	if (!w.webviews.count) {
		d[@"elements"] = w.out;
		reply(d);
		return;
	}
#if SIMAX_WEB
	// the JS answers arrive on the main queue: wait for them there, not by blocking it. Web content gets most of the
	// request's time; what a busy WebContent process did not answer by then is left out and said (web_pending)
	NSMutableArray* out = w.out;
	__block int left = (int)w.webviews.count, pending = 0;
	double t = req[@"timeout"] ? [req[@"timeout"] doubleValue] : 5.0;
	double deadline = MIN(3.0, MAX(0.3, t * 0.8 - 0.2));
	for (NSDictionary* wv in w.webviews)
		walk_web(wv, w.all, deadline, ^(NSArray* items, int pend) {
			[out addObjectsFromArray:items];
			pending += pend;
			if (--left) return;
			d[@"elements"] = out;
			if (pending) d[@"web_pending"] = @(pending);
			reply(d);
		});
#else
	d[@"elements"] = w.out;
	reply(d);
#endif
}

static id find_oid(NSString* oid) {
	// an element the last tree reported: walk again to find it by address (never dereference a stale pointer)
	Walk w = { 0 };
	w.out = [NSMutableArray array];
	w.webviews = [NSMutableArray array];
	w.seen = [NSMutableSet set];
	w.nth = [NSMutableDictionary dictionary];
	w.screen = screen_bounds();
	w.all = YES;
	w.budget = 20000;
	NSArray* wins = visible_windows();
	for (int i = 0; i < (int)wins.count; i++) {
		w.screen = window_screen(wins[i]);
		walk(&w, wins[i], 0, nil);
	}
	for (NSValue* v in w.seen)
		if ([hex((__bridge id)v.pointerValue) isEqualToString:oid]) return (__bridge id)v.pointerValue;
	return nil;
}

static NSDictionary* type_text(NSDictionary* req) {
	UIResponder* r = first_responder();
	if (!r || ![r conformsToProtocol:@protocol(UIKeyInput)]) return @{ @"error": @"no focused text field (tap one first)" };
	id<UIKeyInput> k = (id<UIKeyInput>)r;
	if ([req[@"clear"] boolValue]) {
		if (is(r, @"UITextField")) {
			[r setValue:@"" forKey:@"text"];
			((void (*)(id, SEL, NSUInteger))objc_msgSend)(r, NSSelectorFromString(@"sendActionsForControlEvents:"), 1 << 17);  // EditingChanged
		} else if (is(r, @"UITextView")) {
			[r setValue:@"" forKey:@"text"];
		} else {
			if ([r respondsToSelector:@selector(selectAll:)]) [r selectAll:nil];
			[k deleteBackward];
		}
	}
	NSString* t = req[@"text"] ?: @"";
	if (t.length) [k insertText:t];
	if ([req[@"submit"] boolValue]) [k insertText:@"\n"];
	NSMutableDictionary* d = [NSMutableDictionary dictionaryWithDictionary:@{ @"typed": @(t.length), @"field": NSStringFromClass([r class]) }];
	if (is(r, @"UITextField") && [r valueForKey:@"text"]) d[@"value"] = [r valueForKey:@"text"];
	return d;
}

static void handle(NSDictionary* req, void (^reply)(NSDictionary*)) {
	NSString* op = req[@"op"];
	if ([op isEqualToString:@"tree"]) { tree(req, reply); return; }
	if ([op isEqualToString:@"info"]) { reply(info()); return; }
	if ([op isEqualToString:@"ax"]) { load_ax(); reply(@{ @"ax": @YES }); return; }
	if ([op isEqualToString:@"type"]) { reply(type_text(req)); return; }
	if ([op isEqualToString:@"scroll"] || [op isEqualToString:@"activate"]) {
		NSString* oid = req[@"oid"];
		NSRange hash = [oid rangeOfString:@"#"];
		id e = find_oid(hash.location == NSNotFound ? oid : [oid substringToIndex:hash.location]);
		if (!e) { reply(@{ @"error": @"element gone" }); return; }
		BOOL ok = NO;
		if ([op isEqualToString:@"activate"]) ok = [e accessibilityActivate];
		else {
			SEL s = NSSelectorFromString(@"accessibilityScrollToVisible");
			if ([e respondsToSelector:s]) ok = ((BOOL(*)(id, SEL))objc_msgSend)(e, s);
			if (!ok && [e isKindOfClass:[UIView class]]) {
				// the nearest scroll view brings the view's frame into its bounds
				UIView* v = e;
				for (UIView* p = v.superview; p; p = p.superview)
					if ([p isKindOfClass:[UIScrollView class]]) {
						[(UIScrollView*)p scrollRectToVisible:[v convertRect:v.bounds toView:p] animated:NO];
						ok = YES;
						break;
					}
			}
		}
		reply(@{ @"ok": @(ok) });
		return;
	}
	reply(@{ @"error": [NSString stringWithFormat:@"unknown op %@", op] });
}

// ---------------------------------------------------------------------------------------------------------------------
static bool write_all(int fd, const char* p, size_t n) {
	while (n) {
		ssize_t w = write(fd, p, n);
		if (w < 0 && errno == EINTR) continue;
		if (w <= 0) return false;
		p += w;
		n -= w;
	}
	return true;
}

static void serve(int fd) {
	NSMutableData* buf = [NSMutableData data];
	char tmp[4096];
	for (;;) {
		ssize_t n = read(fd, tmp, sizeof(tmp));
		if (n < 0 && errno == EINTR) continue;
		if (n <= 0) break;
		[buf appendBytes:tmp length:n];
		for (;;) {
			const char* b = buf.bytes;
			const char* nl = memchr(b, '\n', buf.length);
			if (!nl) break;
			NSData* line = [NSData dataWithBytes:b length:nl - b];
			[buf replaceBytesInRange:NSMakeRange(0, nl - b + 1) withBytes:NULL length:0];
			@autoreleasepool {
				NSDictionary* req = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
				if (![req isKindOfClass:[NSDictionary class]]) req = @{ @"op": @"info" };
				double timeout = req[@"timeout"] ? [req[@"timeout"] doubleValue] : 5.0;
				__block NSData* answer = nil;
				dispatch_semaphore_t sem = dispatch_semaphore_create(0);
				uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
				dispatch_async(dispatch_get_main_queue(), ^{
					uint64_t t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
					@try {
						handle(req, ^(NSDictionary* r) {
							NSMutableDictionary* m = [r mutableCopy];
							m[@"wait_ms"] = @((t1 - t0) / 1000000);
							m[@"ms"] = @((clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1000000);
							answer = [NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
							dispatch_semaphore_signal(sem);
						});
					} @catch (NSException* ex) {
						answer = [NSJSONSerialization dataWithJSONObject:@{ @"error": ex.reason ?: ex.name } options:0 error:nil];
						dispatch_semaphore_signal(sem);
					}
				});
				if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0)
					answer = [NSJSONSerialization dataWithJSONObject:@{ @"error": @"busy: the main thread did not answer in time",
						@"pid": @(getpid()), @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"" } options:0 error:nil];
				if (!write_all(fd, answer.bytes, answer.length) || !write_all(fd, "\n", 1)) goto out;
			}
		}
	}
out:
	close(fd);
}

static void* listen_thread(void* arg) {
	struct sockaddr_un a = { 0 };
	int s = socket(AF_UNIX, SOCK_STREAM, 0);
	a.sun_family = AF_UNIX;
	strlcpy(a.sun_path, g_path, sizeof(a.sun_path));
	unlink(g_path);
	if (bind(s, (struct sockaddr*)&a, sizeof(a)) != 0 || listen(s, 4) != 0) {
		alog("cannot listen on %s: errno %d", g_path, errno);
		close(s);
		return NULL;
	}
	alog("listening on %s", g_path);
	for (;;) {
		// Darling's accept() needs an address buffer (simhid listen_thread)
		struct sockaddr_un peer;
		socklen_t plen = sizeof(peer);
		int c = accept(s, (struct sockaddr*)&peer, &plen);
		if (c < 0) {
			if (errno == EINTR) continue;
			usleep(100000);
			continue;
		}
		// one client at a time on this thread: the host asks each process once per snapshot, and a thread per
		// connection crashed apps when it exited (arm64jit's pthread_exit thunk, Preferences under the translator)
		struct timeval tv = { 30, 0 };
		setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		@autoreleasepool { serve(c); }
	}
	return NULL;
}

// <socket>.fg exists while the process is on screen (an application in the foreground, or inactive under an alert;
// SpringBoard always): the host only talks to those, so a suspended app (whose threads never answer) costs nothing
static char g_fg[260];
static void set_fg(bool on) {
	static int cur = -1;
	if (cur == (int)on) return;
	cur = on;
	if (on) {
		int fd = open(g_fg, O_CREAT | O_WRONLY | O_TRUNC, 0644);
		if (fd >= 0) {
			const char* b = NSBundle.mainBundle.bundleIdentifier.UTF8String ?: getprogname();
			write_all(fd, b, strlen(b));
			close(fd);
		}
	} else {
		unlink(g_fg);
	}
}

static void cleanup(void) {
	unlink(g_path);
	unlink(g_fg);
}

static void start(void) {
	atexit(cleanup);
	pthread_t t;
	pthread_create(&t, NULL, listen_thread, NULL);
	pthread_detach(t);
	NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
	for (NSString* n in @[ UIApplicationWillEnterForegroundNotification, UIApplicationDidBecomeActiveNotification ])
		[nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification* note) { set_fg(true); }];
	[nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification* note) {
		set_fg(false);
	}];
	[nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification* note) {
		cleanup();
	}];
	set_fg(UIApplication.sharedApplication.applicationState != UIApplicationStateBackground);
}

__attribute__((constructor)) static void simax_init(void) {
	if (getenv("X86SIM_AX_OFF")) return;
	const char* udid = getenv("SIMULATOR_UDID");
	const char* ring = getenv("SIMFB_RING");
	const char* slash = ring ? strrchr(ring, '/') : NULL;
	char dir[200];
	if (slash && !strncmp(ring, kSystemRoot, sizeof(kSystemRoot) - 1)) snprintf(dir, sizeof(dir), "%.*s", (int)(slash - ring), ring);
	else snprintf(dir, sizeof(dir), "%s/run/user/%u", kSystemRoot, (unsigned)getuid());
	int n = snprintf(g_path, sizeof(g_path), "%s/x86sim-ax-%s-%d.sock", dir, udid && *udid ? udid : "phone", getpid());
	if (n <= 0 || n >= (int)sizeof(((struct sockaddr_un*)0)->sun_path)) return;
	snprintf(g_fg, sizeof(g_fg), "%s/x86sim-ax-%s-%d.fg", dir, udid && *udid ? udid : "phone", getpid());
	// only an application listens: many daemons link UIKit (sharingd, mobileassetd, ...) and never launch one
	static id obs;
	obs = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
		queue:nil usingBlock:^(NSNotification* note) {
			[NSNotificationCenter.defaultCenter removeObserver:obs];
			obs = nil;
			start();
		}];
}
