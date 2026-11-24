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
//   tree full                    the inspector's view (Accessibility Inspector): per element also "more" (language,
//                                custom actions, rotors, input labels, respondsToUserInteraction, view / controller
//                                class, container path, text font / color / truncation) and "hidden" (interactive
//                                views VoiceOver cannot reach), for the audit (host: core/src/axaudit.rs)
//   action oid name [dir|custom] perform an accessibility action: activate, increment, decrement, scroll, escape,
//                                magic_tap, custom (by name)
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
#include <mach/mach_time.h>

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
	CGRect clip;                 // the window's part of the screen (screen coordinates): beyond it is off screen
	CGPoint off;                 // the window's origin on the display (window_origin)
	long rot;                    // a window that does not rotate (SpringBoard's switcher window) under a landscape
	                             // interface: its interface orientation (3, 4), its frames turned into the screen's
	CGSize portrait;             // the display in points, portrait
	BOOL all;
	int win;                     // index of the window being walked
	id focus;                    // the first responder
	id focus_item;               // the focus engine's focused item (tvOS: what the remote's select acts on; iPad: keyboard focus)
	CGRect focus_frame;          // its rect on the screen (CGRectNull: none or unknown)
	int budget;                  // max nodes visited
	// full (the inspector): the containers above the element being walked, the views inside an element (covered) or
	// holding one (holds): what is left of the interactive views is out of VoiceOver's reach
	BOOL full;
	NSMutableArray* path;
	NSMutableSet* covered;
	NSMutableSet* holds;
} Walk;

static void more_of(Walk* w, id e, uint64_t t, NSMutableDictionary* d);

// a frame in a window's coordinates -> the screen's (as the agent sees the display)
static CGRect place(Walk* w, CGRect f) {
	if (w->rot == 3) f = CGRectMake(f.origin.y, w->portrait.width - (f.origin.x + f.size.width), f.size.height, f.size.width);
	else if (w->rot == 4) f = CGRectMake(w->portrait.height - (f.origin.y + f.size.height), f.origin.x, f.size.height, f.size.width);
	return CGRectOffset(f, w->off.x, w->off.y);
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
	f = place(w, f);
	BOOL on = CGRectIntersectsRect(f, w->clip) && f.size.width > 0.5 && f.size.height > 0.5;
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
	// the focus engine's item (tvOS): the element itself, a view inside it, or the view it stands for
	id fi = w->focus_item;
	if (fi && !focused) {
		if (e == fi) focused = YES;
		else if ([fi isKindOfClass:[UIView class]] && [e isKindOfClass:[UIView class]] && [(UIView*)fi isDescendantOfView:(UIView*)e]) focused = YES;
		else if (!CGRectIsNull(w->focus_frame)) {
			// an element standing for the focused view (a table cell's UITableViewCellAccessibilityElement, a SwiftUI
			// node): nearly the same rect
			CGRect i = CGRectIntersection(f, w->focus_frame);
			double ai = CGRectIsNull(i) ? 0 : i.size.width * i.size.height;
			double au = f.size.width * f.size.height + w->focus_frame.size.width * w->focus_frame.size.height - ai;
			focused = au > 0 && ai / au > 0.6;
		}
	}
	if (focused || (t & kTraitIsEditing)) d[@"focused"] = @YES;
	if (!on) d[@"offscreen"] = @YES;
	d[@"win"] = @(w->win);
	d[@"depth"] = @(depth);
	if (container) d[@"in"] = container;
	d[@"class"] = NSStringFromClass([e class]);
	if (w->full) more_of(w, e, t, d);
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
			CGRect f = place(w, to_screen(v, v.bounds));
			if (CGRectIntersectsRect(f, w->clip)) [w->webviews addObject:@{ @"view": v, @"win": @(w->win), @"depth": @(depth),
				@"off": [NSValue valueWithCGPoint:w->off], @"clip": [NSValue valueWithCGRect:w->clip] }];
			return;   // its content comes from the DOM walk (the AX tree of a web page lives in another process)
		}
#endif
		// off-screen subtrees: skip unless all (a scroll view's content is checked element by element)
		if (!w->all && ![v isKindOfClass:[UIScrollView class]]) {
			CGRect f = place(w, to_screen(v, v.bounds));
			if (!v.clipsToBounds) f = CGRectInset(f, -2000, -2000);   // children may draw outside a non-clipping view
			if (!CGRectIntersectsRect(f, w->clip) && v.subviews.count < 50) return;
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
	NSString* step = nil;
	if (!leaf) {
		NSString* l = nil;
		@try { l = str([o accessibilityLabel]); } @catch (id ex) { l = nil; }
		if (l && l.length < 80) here = l;
		if (w->full) {
			// the inspector's hierarchy: the levels VoiceOver sees (not every plain UIView between them)
			NSString* cls = NSStringFromClass([o class]);
			NSString* ident = nil;
			@try { ident = [o respondsToSelector:@selector(accessibilityIdentifier)] ? str([o accessibilityIdentifier]) : nil; } @catch (id ex) { ident = nil; }
			if (l || ident || ![o isKindOfClass:[UIView class]] || [o isKindOfClass:[UIScrollView class]] || [o isKindOfClass:[UIWindow class]] ||
			    (![cls isEqualToString:@"UIView"] && ![cls hasPrefix:@"_UI"] && ![cls hasSuffix:@"ContainerView"] && ![cls hasSuffix:@"WrapperView"])) {
				step = cls;
				if (l) step = [step stringByAppendingFormat:@" \"%@\"", l.length > 40 ? [l substringToIndex:40] : l];
				if (ident) step = [step stringByAppendingFormat:@" #%@", ident];
			}
		}
	}
	if (step) [w->path addObject:step];
	for (id c in kids) walk(w, c, depth + 1, here);
	if (step) [w->path removeLastObject];
}

#if SIMAX_WEB
// ---------------------------------------------------------------------------------------------------------------------
// WebKit content: a DOM walk in an isolated content world (page scripts cannot see or break it; CSP does not apply),
// returning the visible meaningful elements with CSS-pixel rects; converted to screen points through the web view's
// scroll view (content coordinates = page coordinates * zoomScale).
static NSString* const kDomWalker = @
	"(() => {"
	"const out = []; const vw = innerWidth, vh = innerHeight; const all = %@;"
	"const role = el => { const r = el.getAttribute('role'); if (r) return r; const t = el.tagName.toLowerCase();"
	"  if (t === 'a' && el.hasAttribute('href')) return 'link'; if (t === 'button' || t === 'summary') return 'button';"
	"  if (t === 'input') { const ty = (el.type || 'text').toLowerCase();"
	"    if (['button','submit','reset','image'].includes(ty)) return 'button'; if (ty === 'checkbox') return 'checkbox';"
	"    if (ty === 'radio') return 'radio'; if (ty === 'range') return 'adjustable'; if (ty === 'hidden') return null;"
	"    return ty === 'search' ? 'searchfield' : 'textfield'; }"
	"  if (t === 'textarea' || el.isContentEditable) return 'textfield'; if (t === 'select') return 'popup';"
	"  if (/^h[1-6]$/.test(t)) return 'heading'; if (t === 'img') return el.alt ? 'image' : null; return null; };"
	"const visible = (el, r) => { if (r.width < 1 || r.height < 1) return false;"
	"  if (!all && (r.bottom < 0 || r.right < 0 || r.top > vh || r.left > vw)) return false;"
	"  const s = getComputedStyle(el); return s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity > 0.01; };"
	"const name = el => { const l = el.getAttribute('aria-label'); if (l) return l;"
	"  const lb = el.getAttribute('aria-labelledby'); if (lb) { const n = document.getElementById(lb); if (n) return n.innerText; }"
	"  if (el.labels && el.labels.length) return el.labels[0].innerText;"
	"  if (el.tagName === 'IMG') return el.alt; if (el.tagName === 'INPUT' && ['button','submit','reset'].includes(el.type)) return el.value;"
	"  if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return el.placeholder || el.name || '';"
	"  return (el.innerText || el.textContent || '').trim(); };"
	"const walk = (root) => { const it = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT); let el = it.currentNode;"
	"  while (el && out.length < 600) { let skip = false; const r0 = role(el);"
	"    if (r0 !== null || (el.childElementCount === 0 || [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim().length > 1))) {"
	"      const r = el.getBoundingClientRect();"
	"      if (visible(el, r)) {"
	"        let rl = r0; let label = name(el);"
	"        if (!rl) { const own = [...el.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join(' ').replace(/\\s+/g, ' ').trim();"
	"          if (own.length > 1) { rl = 'text'; label = own; } }"
	"        if (rl) { const e = { role: rl, label: (label || '').replace(/\\s+/g, ' ').trim().slice(0, 300), x: r.left, y: r.top, w: r.width, h: r.height };"
	"          if (el.id) e.id = el.id; if ('value' in el && rl !== 'button' && el.value !== undefined && el.value !== '') e.value = String(el.value).slice(0, 300);"
	"          if (el.disabled) e.enabled = false; if (el.checked) e.selected = true; if (document.activeElement === el) e.focused = true;"
	"          if (rl === 'link') e.href = el.href; out.push(e);"
	"          if (r0 && rl !== 'text' && rl !== 'heading') skip = true; }"
	"      } else if (r.width >= 1 && !all && (r.bottom < -vh || r.top > 2 * vh)) skip = false; }"
	"    if (skip) { let n = it.nextSibling(); while (!n && it.parentNode()) n = it.nextSibling(); el = n; } else el = it.nextNode(); } };"
	"walk(document.body || document.documentElement);"
	"return JSON.stringify({ url: location.href, title: document.title, sx: scrollX, sy: scrollY, items: out });"
	"})()";

static void walk_web(Walk* w, NSDictionary* wv, NSMutableArray* out, dispatch_group_t g) {
	WKWebView* v = wv[@"view"];
	NSString* js = [NSString stringWithFormat:kDomWalker, w->all ? @"true" : @"false"];
	UIScrollView* sv = v.scrollView;
	CGFloat zoom = sv.zoomScale > 0 ? sv.zoomScale : 1;
	CGPoint off = [wv[@"off"] CGPointValue];
	CGRect vis = CGRectIntersection(CGRectOffset(to_screen(v, v.bounds), off.x, off.y), [wv[@"clip"] CGRectValue]);
	int win = [wv[@"win"] intValue], depth = [wv[@"depth"] intValue];
	dispatch_group_enter(g);
	void (^done)(id, NSError*) = ^(id res, NSError* err) {
		if (err || ![res isKindOfClass:[NSString class]]) {
			alog("web: %s", err.description.UTF8String ?: "no result");
			dispatch_group_leave(g);
			return;
		}
		NSDictionary* page = [NSJSONSerialization JSONObjectWithData:[res dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
		double sx = [page[@"sx"] doubleValue], sy = [page[@"sy"] doubleValue];
		int i = 0;
		for (NSDictionary* it in page[@"items"]) {
			// client rect -> page coordinates -> the scroll view's content coordinates -> screen
			CGPoint p = CGPointMake(([it[@"x"] doubleValue] + sx) * zoom, ([it[@"y"] doubleValue] + sy) * zoom);
			CGPoint s = to_screen(sv, CGRectMake(p.x, p.y, 0, 0)).origin;
			s.x += off.x, s.y += off.y;
			CGRect f = CGRectMake(s.x, s.y, [it[@"w"] doubleValue] * zoom, [it[@"h"] doubleValue] * zoom);
			BOOL on = CGRectIntersectsRect(f, vis);
			if (!on && !w->all) continue;
			NSMutableDictionary* d = [NSMutableDictionary dictionary];
			for (NSString* k in @[ @"role", @"label", @"value", @"id", @"enabled", @"selected", @"focused", @"href" ])
				if (it[k]) d[k] = it[k];
			d[@"oid"] = [NSString stringWithFormat:@"%@#%d", hex(v), i++];
			d[@"frame"] = @[ @(round(f.origin.x * 10) / 10), @(round(f.origin.y * 10) / 10), @(round(f.size.width * 10) / 10),
				@(round(f.size.height * 10) / 10) ];
			d[@"win"] = @(win);
			d[@"depth"] = @(depth + 1);
			d[@"web"] = @YES;
			if (!on) d[@"offscreen"] = @YES;
			[out addObject:d];
		}
		[out addObject:@{ @"role": @"webview", @"oid": hex(v), @"label": page[@"title"] ?: @"", @"value": page[@"url"] ?: @"",
			@"frame": @[ @(vis.origin.x), @(vis.origin.y), @(vis.size.width), @(vis.size.height) ], @"win": @(win), @"depth": @(depth),
			@"web": @YES, @"meta": @YES }];
		dispatch_group_leave(g);
	};
	if (@available(iOS 14.0, *))
		[v evaluateJavaScript:js inFrame:nil inContentWorld:[WKContentWorld defaultClientWorld] completionHandler:done];
	else
		[v evaluateJavaScript:js completionHandler:done];
}

#endif

// ---------------------------------------------------------------------------------------------------------------------
static NSArray<UIWindow*>* visible_windows(void);

static UIResponder* first_responder(void) {
	// the scenes' windows, a view service's hosted window (watchOS's text input sheet), front first
	for (UIWindow* win in [visible_windows() reverseObjectEnumerator]) {
		if (![win respondsToSelector:@selector(firstResponder)]) continue;
		UIResponder* r = ((id(*)(id, SEL))objc_msgSend)(win, @selector(firstResponder));
		if (r) return r;
	}
	return nil;
}

// The focus engine's focused item (UIFocusSystem of a window's scene; tvOS: what the remote acts on). Looked up by
// name: UIFocusSystem is iOS 15+ / tvOS 15+ API.
static id focused_item(NSArray* wins) {
	Class fs = NSClassFromString(@"UIFocusSystem");
	SEL forEnv = NSSelectorFromString(@"focusSystemForEnvironment:");
	if (!fs || ![fs respondsToSelector:forEnv]) return nil;
	// (no UIScreen.focusedItem fallback: watchOS throws "Accessing the focus system through UIScreen is no longer
	// supported", and the whole answer was lost)
	@try {
		for (UIWindow* w in [wins reverseObjectEnumerator]) {
			id sys = ((id(*)(id, SEL, id))objc_msgSend)(fs, forEnv, w);
			id it = [sys respondsToSelector:@selector(focusedItem)] ? ((id(*)(id, SEL))objc_msgSend)(sys, @selector(focusedItem)) : nil;
			if (it) return it;
		}
	} @catch (id ex) {
	}
	return nil;
}

static NSArray<UIWindow*>* hosted_windows(void) {
	NSMutableArray* a = [NSMutableArray array];
	SEL all = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
	if (![UIWindow respondsToSelector:all]) return a;
	NSArray* every = ((NSArray * (*)(id, SEL, BOOL, BOOL)) objc_msgSend)([UIWindow class], all, YES, YES);
	id scr = ((id(*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIScreen"), NSSelectorFromString(@"mainScreen"));
	CGRect sb = scr ? ((CGRect(*)(id, SEL))objc_msgSend)(scr, @selector(bounds)) : CGRectNull;
	for (UIWindow* win in every) {
		if (![win isKindOfClass:[UIWindow class]] || ![NSStringFromClass([win class]) isEqualToString:@"_UIHostedWindow"]) continue;
		if (win.hidden || win.alpha < 0.01 || !win.subviews.count || !win.rootViewController) continue;
		if (CGRectIsNull(sb) || !CGRectEqualToRect(win.bounds, sb)) continue;
		[a addObject:win];
	}
	return a;
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
	// a view service's content (watchOS's QuickboardViewService: the keyboard / Scribble sheet over an app) is in a
	// _UIHostedWindow outside the application's scenes; a full-screen one is the screen as it shows
	for (UIWindow* win in hosted_windows())
		if (![a containsObject:win]) [a addObject:win];
	// back to front
	[a sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(UIWindow* x, UIWindow* y) {
		return x.windowLevel < y.windowLevel ? NSOrderedAscending : x.windowLevel > y.windowLevel ? NSOrderedDescending : NSOrderedSame;
	}];
	return a;
}

// A one-shot Core Animation animation still running in the window (a push, a sheet, an alert coming up): the host
// waits for it before it reports "the screen after" an action. Looping ones (spinners, the caret) do not count.
static BOOL animating_layer(CALayer* l, int* budget) {
	if (--*budget < 0 || l.hidden) return NO;
	for (NSString* k in l.animationKeys) {
		CAAnimation* a = [l animationForKey:k];
		if (a.repeatCount > 1 || a.repeatDuration > 0 || a.duration > 3 || a.autoreverses) continue;
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

// Where the window's scene is on the display (iPadOS windowed apps / Stage Manager, an iPhone app on an iPad): the
// scene's FBSSceneSettings frame. UIKit's screen coordinates are the scene's own (its origin is 0,0 wherever SpringBoard
// put the window); an agent's are the display's. (0, 0) for a full-screen scene and wherever there is no such frame.
static CGRect scene_frame(UIWindow* w, long* io) {
	CGRect r = CGRectNull;
	@try {
		id sc = w.windowScene;
		SEL fs = NSSelectorFromString(@"_FBSScene");
		id fbs = [sc respondsToSelector:fs] ? ((id(*)(id, SEL))objc_msgSend)(sc, fs) : nil;
		id set = [fbs respondsToSelector:@selector(settings)] ? ((id(*)(id, SEL))objc_msgSend)(fbs, @selector(settings)) : nil;
		if (![set respondsToSelector:@selector(frame)]) return r;
		r = ((CGRect(*)(id, SEL))objc_msgSend)(set, @selector(frame));
		if (io && [set respondsToSelector:@selector(interfaceOrientation)])
			*io = ((long(*)(id, SEL))objc_msgSend)(set, @selector(interfaceOrientation));
	} @catch (id ex) {
	}
	return r;
}

static CGPoint window_origin(UIWindow* w) {
	long io = 1;
	CGRect r = scene_frame(w, &io);
	if (CGRectIsNull(r)) return CGPointZero;
	CGSize sz = w.bounds.size;
	if (fabs(r.size.width - sz.width) < 1 && fabs(r.size.height - sz.height) < 1) return r.origin;
	// a rotated interface: the scene's frame is in the display's own (portrait) coordinates; the window's origin is
	// the corner that is its top left in the interface's orientation
	if (fabs(r.size.width - sz.height) < 1 && fabs(r.size.height - sz.width) < 1) {
		CGRect d = ((CGRect(*)(id, SEL))objc_msgSend)(((id(*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIScreen"),
			NSSelectorFromString(@"mainScreen")), NSSelectorFromString(@"nativeBounds"));
		double scale = screen_scale();
		double W = d.size.width / scale, H = d.size.height / scale;   // the display, portrait, points
		if (io == 4)   // UIInterfaceOrientationLandscapeLeft: home button on the left; interface x = H - (y + h)
			return CGPointMake(H - (r.origin.y + r.size.height), r.origin.x);
		if (io == 3)   // LandscapeRight
			return CGPointMake(r.origin.y, W - (r.origin.x + r.size.width));
	}
	return CGPointZero;
}

// A window that keeps the display's portrait coordinates while the interface is landscape (SpringBoard's
// SBMainSwitcherWindow: window controls, resize grabbers): the interface orientation its frames are turned by, else 0
static long window_rot(UIWindow* win, CGSize screen, CGSize* portrait) {
	CGSize b = win.bounds.size;
	*portrait = CGSizeMake(MIN(screen.width, screen.height), MAX(screen.width, screen.height));
	if (screen.width <= screen.height || fabs(b.width - screen.height) > 1 || fabs(b.height - screen.width) > 1) return 0;
	// the interface's orientation: a scene that turned with it (UIWindowScene.interfaceOrientation of a landscape window)
	for (UIScene* sc in UIApplication.sharedApplication.connectedScenes) {
		if (![sc isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow* o in ((UIWindowScene*)sc).windows)
			if (o.bounds.size.width > o.bounds.size.height) {
				long io = ((long(*)(id, SEL))objc_msgSend)(sc, NSSelectorFromString(@"interfaceOrientation"));
				if (io == 3 || io == 4) return io;
			}
	}
	return 0;
}

// The process's state on screen: the application's, or a foreground scene's when the application says background (a
// view service such as watchOS's QuickboardViewService, the keyboard over an app, stays "background" while its
// hosted scene is up)
static NSString* app_state(void) {
	UIApplication* app = UIApplication.sharedApplication;
	UIApplicationState st = app.applicationState;
	if (st == UIApplicationStateActive) return @"active";
	NSString* best = st == UIApplicationStateInactive ? @"inactive" : @"background";
	if (hosted_windows().count) return @"active";
	for (UIScene* sc in app.connectedScenes) {
		if (sc.activationState == UISceneActivationStateForegroundActive) return @"active";
		if (sc.activationState == UISceneActivationStateForegroundInactive) best = @"inactive";
	}
	return best;
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
	d[@"state"] = app_state();
	CGRect b = screen_bounds();
	d[@"screen"] = @[ @(b.size.width), @(b.size.height), @(screen_scale()) ];
	NSMutableArray* ws = [NSMutableArray array];
	for (UIWindow* w in visible_windows()) {
		CGRect f = to_screen(w, w.bounds);
		CGPoint wo = window_origin(w);
		f = CGRectOffset(f, wo.x, wo.y);
		NSMutableDictionary* wd = [@{ @"class": NSStringFromClass([w class]), @"level": @(w.windowLevel), @"key": @(w.isKeyWindow),
			@"frame": @[ @(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height) ] } mutableCopy];
		long io = 0;
		CGRect sf = scene_frame(w, &io);
		if (!CGRectIsNull(sf)) wd[@"scene"] = @[ @(sf.origin.x), @(sf.origin.y), @(sf.size.width), @(sf.size.height), @(io) ];
		if (wo.x || wo.y) wd[@"origin"] = @[ @(wo.x), @(wo.y) ];
		[ws addObject:wd];
	}
	d[@"windows"] = ws;
	d[@"ax"] = @(atomic_load(&g_ax_loaded));
	return d;
}


// ---------------------------------------------------------------------------------------------------------------------
// The inspector (tree full): what Xcode's Accessibility Inspector shows of an element beyond the snapshot, and what the
// audit needs (the text's font, color and truncation; interactive views VoiceOver cannot reach).

// the view an element is (or the nearest view among its containers: a table cell's element -> the cell)
static UIView* view_of(id e) {
	for (id o = e; o; ) {
		if ([o isKindOfClass:[UIView class]]) return o;
		id c = nil;
		@try { c = [o respondsToSelector:@selector(accessibilityContainer)] ? [o accessibilityContainer] : nil; } @catch (id ex) { c = nil; }
		o = c;
	}
	return nil;
}

static UIViewController* controller_of(UIView* v) {
	for (UIResponder* r = v; r; r = r.nextResponder)
		if ([r isKindOfClass:[UIViewController class]]) return (UIViewController*)r;
	return nil;
}

static NSArray* rgba(UIColor* c, UIView* v) {
	if (![c isKindOfClass:[UIColor class]]) return nil;
	@try {
		if (v && [c respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) c = [c resolvedColorWithTraitCollection:v.traitCollection];
		CGFloat r = 0, g = 0, b = 0, a = 0, wh = 0;
		if (![c getRed:&r green:&g blue:&b alpha:&a]) {
			if (![c getWhite:&wh alpha:&a]) return nil;
			r = g = b = wh;
		}
		return @[ @(lround(MIN(1, MAX(0, r)) * 255)), @(lround(MIN(1, MAX(0, g)) * 255)), @(lround(MIN(1, MAX(0, b)) * 255)), @(round(a * 100) / 100) ];
	} @catch (id ex) {
		return nil;
	}
}

static NSArray* all_trait_names(uint64_t t) {
	NSMutableArray* a = [NSMutableArray array];
	struct { uint64_t bit; const char* name; } map[] = {
		{ UIAccessibilityTraitButton, "button" }, { UIAccessibilityTraitLink, "link" }, { UIAccessibilityTraitImage, "image" },
		{ UIAccessibilityTraitSelected, "selected" }, { UIAccessibilityTraitPlaysSound, "playsSound" },
		{ UIAccessibilityTraitKeyboardKey, "keyboardKey" }, { UIAccessibilityTraitStaticText, "staticText" },
		{ UIAccessibilityTraitSummaryElement, "summaryElement" }, { UIAccessibilityTraitNotEnabled, "notEnabled" },
		{ UIAccessibilityTraitUpdatesFrequently, "updatesFrequently" }, { UIAccessibilityTraitSearchField, "searchField" },
		{ UIAccessibilityTraitStartsMediaSession, "startsMediaSession" }, { UIAccessibilityTraitAdjustable, "adjustable" },
		{ UIAccessibilityTraitAllowsDirectInteraction, "allowsDirectInteraction" }, { UIAccessibilityTraitCausesPageTurn, "causesPageTurn" },
		{ UIAccessibilityTraitTabBar, "tabBar" }, { UIAccessibilityTraitHeader, "header" }, { kTraitTextEntry, "textEntry" },
		{ kTraitIsEditing, "isEditing" },
	};
	for (size_t i = 0; i < sizeof(map) / sizeof(map[0]); i++)
		if (t & map[i].bit) [a addObject:@(map[i].name)];
	if (@available(iOS 17.0, tvOS 17.0, watchOS 10.0, *)) {
		if (t & UIAccessibilityTraitToggleButton) [a addObject:@"toggleButton"];
		if (t & UIAccessibilityTraitSupportsZoom) [a addObject:@"supportsZoom"];
	}
	return a;
}

static NSString* text_of(UIView* v) { @try { return str([v valueForKey:@"text"]); } @catch (id ex) { return nil; } }

// the labels that draw an element's text: the element itself (a label, field, text view), a button's title, else the
// visible labels inside it (a table cell's title and detail)
static NSArray<UIView*>* text_views(UIView* v) {
	if (!v) return @[];
	if (is(v, @"UILabel") || is(v, @"UITextField") || is(v, @"UITextView")) return @[ v ];
	if (is(v, @"UIButton")) {
		UIView* tl = nil;
		@try { tl = [v valueForKey:@"titleLabel"]; } @catch (id ex) { tl = nil; }
		if (tl && !tl.hidden && text_of(tl)) return @[ tl ];
	}
	NSMutableArray* found = [NSMutableArray array];
	NSMutableArray* q = [NSMutableArray arrayWithObject:v];
	for (int n = 0; q.count && n < 80 && found.count < 6; n++) {
		UIView* x = q[0];
		[q removeObjectAtIndex:0];
		if (x != v && view_hidden(x)) continue;
		if (x != v && is(x, @"UILabel") && text_of(x)) { [found addObject:x]; continue; }
		[q addObjectsFromArray:x.subviews];
	}
	return found;
}

// a label that does not show all its text (cut with an ellipsis, or lines cut off at the bottom)
static BOOL label_truncated(UIView* l) {
	if (!is(l, @"UILabel")) return NO;
	@try {
		CGSize b = l.bounds.size;
		if (b.width < 1 || !text_of(l)) return NO;
		SEL tr = @selector(textRectForBounds:limitedToNumberOfLines:);
		CGRect (*rect)(id, SEL, CGRect, NSInteger) = (CGRect(*)(id, SEL, CGRect, NSInteger))objc_msgSend;
		NSInteger lines = [[l valueForKey:@"numberOfLines"] integerValue];
		if (lines == 1) {
			if ([[l valueForKey:@"adjustsFontSizeToFitWidth"] boolValue]) return NO;
			CGRect one = rect(l, tr, CGRectMake(0, 0, CGFLOAT_MAX, CGFLOAT_MAX), 1);
			return one.size.width > b.width + 1;
		}
		CGRect need = rect(l, tr, CGRectMake(0, 0, b.width, CGFLOAT_MAX), 0);
		return need.size.height > b.height + 1;
	} @catch (id ex) {
		return NO;
	}
}

static BOOL gesture_tap(UIView* v) {
	for (UIGestureRecognizer* g in v.gestureRecognizers) {
		if (!g.enabled) continue;
		NSString* c = NSStringFromClass([g class]);
		if ([c hasPrefix:@"_"]) continue;
		if ([g isKindOfClass:[UITapGestureRecognizer class]] || [g isKindOfClass:[UILongPressGestureRecognizer class]]) return YES;
	}
	return NO;
}

static NSString* names_of(id o) {
	@try {
		if ([o respondsToSelector:@selector(name)]) return str([o name]);
	} @catch (id ex) {
	}
	return nil;
}

static void more_of(Walk* w, id e, uint64_t t, NSMutableDictionary* d) {
	NSMutableDictionary* m = [NSMutableDictionary dictionary];
	@try {
		m[@"class"] = NSStringFromClass([e class]);
		m[@"traits_raw"] = @(t);
		m[@"traits_all"] = all_trait_names(t);
		NSString* lang = [e respondsToSelector:@selector(accessibilityLanguage)] ? str([e accessibilityLanguage]) : nil;
		if (lang) m[@"lang"] = lang;
		NSArray* ca = [e respondsToSelector:@selector(accessibilityCustomActions)] ? [e accessibilityCustomActions] : nil;
		NSMutableArray* cn = [NSMutableArray array];
		for (id a in ca) { NSString* n = names_of(a); if (n) [cn addObject:n]; }
		if (cn.count) m[@"custom_actions"] = cn;
		NSArray* ro = [e respondsToSelector:@selector(accessibilityCustomRotors)] ? [e accessibilityCustomRotors] : nil;
		NSMutableArray* rn = [NSMutableArray array];
		for (id r in ro) {
			NSString* n = names_of(r);
			if (!n && [r respondsToSelector:@selector(systemRotorType)]) n = [NSString stringWithFormat:@"system rotor %ld", (long)[r systemRotorType]];
			if (n) [rn addObject:n];
		}
		if (rn.count) m[@"rotors"] = rn;
		SEL uil = NSSelectorFromString(@"accessibilityUserInputLabels");
		if ([e respondsToSelector:uil]) {
			NSArray* ul = ((id(*)(id, SEL))objc_msgSend)(e, uil);
			if ([ul isKindOfClass:[NSArray class]] && ul.count) m[@"input_labels"] = [ul subarrayWithRange:NSMakeRange(0, MIN(ul.count, 8))];
		}
		SEL rui = NSSelectorFromString(@"accessibilityRespondsToUserInteraction");
		if ([e respondsToSelector:rui]) m[@"interactive"] = @(((BOOL(*)(id, SEL))objc_msgSend)(e, rui));
		CGPoint ap = [e accessibilityActivationPoint];
		CGRect apr = place(w, CGRectMake(ap.x, ap.y, 0, 0));
		m[@"activation"] = @[ @(round(apr.origin.x * 10) / 10), @(round(apr.origin.y * 10) / 10) ];
		if ([e respondsToSelector:@selector(accessibilityViewIsModal)] && [e accessibilityViewIsModal]) m[@"modal"] = @YES;
		if ([e respondsToSelector:@selector(accessibilityNavigationStyle)] && [e accessibilityNavigationStyle] != UIAccessibilityNavigationStyleAutomatic)
			m[@"navigation_style"] = @([e accessibilityNavigationStyle]);
		UIView* v = view_of(e);
		if (v) {
			m[@"view"] = NSStringFromClass([v class]);
			UIViewController* vc = controller_of(v);
			if (vc) m[@"controller"] = NSStringFromClass([vc class]);
			// what the hidden-interactive scan leaves alone: the element's view and what holds it
			if (e == v) [w->covered addObject:[NSValue valueWithPointer:(__bridge void*)v]];
			for (UIView* x = v; x; x = x.superview) {
				NSValue* k = [NSValue valueWithPointer:(__bridge void*)x];
				if ([w->holds containsObject:k]) break;
				[w->holds addObject:k];
			}
		}
		if (w->path.count) m[@"path"] = w->path.count > 12 ? [w->path subarrayWithRange:NSMakeRange(w->path.count - 12, 12)] : [w->path copy];
		if ([e isKindOfClass:[UIView class]]) {
			UIView* ev = e;
			if ([ev isKindOfClass:[UIControl class]]) m[@"tap"] = @"control";
			else if (gesture_tap(ev)) m[@"tap"] = @"gesture";
		}
		// the text it draws: font, color, Dynamic Type, cut off
		UIView* tv0 = [e isKindOfClass:[UIView class]] ? e : ([NSStringFromClass([v class]) containsString:@"Cell"] ? v : nil);
		NSArray* tvs = text_views(tv0);
		if (tvs.count) {
			UIView* tv = tvs[0];
			UIFont* f = [tv valueForKey:@"font"];
			if ([f isKindOfClass:[UIFont class]]) {
				BOOL bold = (f.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) != 0;
				m[@"font"] = @{ @"size": @(round(f.pointSize * 10) / 10), @"bold": @(bold), @"name": f.fontName ?: @"" };
			}
			if ([tv respondsToSelector:@selector(adjustsFontForContentSizeCategory)])
				m[@"dynamic_type"] = @([[tv valueForKey:@"adjustsFontForContentSizeCategory"] boolValue]);
			NSArray* fg = rgba([tv valueForKey:@"textColor"], tv);
			if (fg) m[@"fg"] = fg;
			for (UIView* l in tvs)
				if (label_truncated(l)) {
					m[@"truncated"] = text_of(l) ?: @"";
					break;
				}
			m[@"text_class"] = NSStringFromClass([tv class]);
		}
	} @catch (id ex) {
		m[@"error"] = [ex description] ?: @"?";
	}
	d[@"more"] = m;
}

// Interactive views VoiceOver cannot reach: a control or a view with a tap / long press recognizer that is not an
// element, not inside one and holds none (accessibilityElementsHidden above it, isAccessibilityElement NO with nothing
// inside). Full-window views (a tap to dismiss the keyboard) and UIKit's own private views are left out.
static void hidden_scan(Walk* w, NSArray* wins, NSMutableArray* out) {
	for (int i = 0; i < (int)wins.count; i++) {
		UIWindow* win = wins[i];
		if ([NSStringFromClass([win class]) containsString:@"Keyboard"]) continue;
		w->off = window_origin(win);
		w->rot = window_rot(win, w->screen.size, &w->portrait);
		CGRect clip = CGRectIntersection(w->screen, place(w, to_screen(win, win.bounds)));
		double warea = win.bounds.size.width * win.bounds.size.height;
		NSMutableArray* stack = [NSMutableArray arrayWithObject:win];
		int budget = 8000;
		while (stack.count && budget-- > 0 && out.count < 60) {
			UIView* v = stack.lastObject;
			[stack removeLastObject];
			if (v.hidden || v.alpha < 0.01) continue;
			NSValue* k = [NSValue valueWithPointer:(__bridge void*)v];
			if ([w->covered containsObject:k]) continue;   // an element: what is inside it is its business
			NSString* cls = NSStringFromClass([v class]);
			BOOL control = [v isKindOfClass:[UIControl class]] && [(UIControl*)v isEnabled];
			BOOL tap = !control && gesture_tap(v);
			if ((control || tap) && v.userInteractionEnabled && ![w->holds containsObject:k] && ![v isKindOfClass:[UIWindow class]] &&
			    ![v isKindOfClass:[UIScrollView class]] && ![cls hasPrefix:@"_"] && v.bounds.size.width * v.bounds.size.height < warea * 0.5) {
				CGRect f = place(w, to_screen(v, v.bounds));
				if (CGRectIntersectsRect(f, clip) && f.size.width >= 4 && f.size.height >= 4) {
					NSString* why = nil;
					for (UIView* x = v; x; x = x.superview)
						if (x.accessibilityElementsHidden) {
							why = x == v ? @"accessibilityElementsHidden is set on it" : [NSString stringWithFormat:@"accessibilityElementsHidden on its ancestor %@", NSStringFromClass([x class])];
							break;
						}
					if (!why) why = @"not an accessibility element (isAccessibilityElement NO) and holds none: VoiceOver skips it";
					NSMutableDictionary* h = [NSMutableDictionary dictionary];
					h[@"class"] = cls;
					h[@"kind"] = control ? @"control" : @"gesture";
					h[@"frame"] = @[ @(round(f.origin.x * 10) / 10), @(round(f.origin.y * 10) / 10), @(round(f.size.width * 10) / 10), @(round(f.size.height * 10) / 10) ];
					h[@"why"] = why;
					h[@"win"] = @(i);
					h[@"oid"] = hex(v);
					NSString* l = str(v.accessibilityLabel);
					if (l) h[@"label"] = l;
					UIViewController* vc = controller_of(v);
					if (vc) h[@"controller"] = NSStringFromClass([vc class]);
					[out addObject:h];
					continue;
				}
			}
			[stack addObjectsFromArray:v.subviews];
		}
	}
}

// the focused item's rect on the screen (CGRectNull: unknown)
static CGRect focus_frame_of(id item) {
	CGRect ff = CGRectNull;
	if (!item) return ff;
		@try {
			if ([item isKindOfClass:[UIView class]]) {
				UIView* fv = item;
				CGPoint o = fv.window ? window_origin(fv.window) : CGPointZero;
				ff = CGRectOffset(to_screen(fv, fv.bounds), o.x, o.y);
			}
			else if ([item respondsToSelector:@selector(frame)] && [item respondsToSelector:@selector(coordinateSpace)]) {
				CGRect r = ((CGRect(*)(id, SEL))objc_msgSend)(item, @selector(frame));
				id<UICoordinateSpace> cs = ((id(*)(id, SEL))objc_msgSend)(item, @selector(coordinateSpace));
				id scr = ((id(*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIScreen"), NSSelectorFromString(@"mainScreen"));
				id<UICoordinateSpace> to = scr ? ((id(*)(id, SEL))objc_msgSend)(scr, NSSelectorFromString(@"coordinateSpace")) : nil;
				ff = to ? [cs convertRect:r toCoordinateSpace:to] : r;
			}
		} @catch (id ex) {
		}
	return ff;
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
	w.screen = screen_bounds();
	w.all = [req[@"all"] boolValue];
	w.focus = first_responder();
	w.budget = 20000;
	if ([req[@"full"] boolValue]) {
		w.full = YES;
		w.path = [NSMutableArray array];
		w.covered = [NSMutableSet set];
		w.holds = [NSMutableSet set];
	}
	NSArray* wins = visible_windows();
	w.focus_item = focused_item(wins);
	w.focus_frame = focus_frame_of(w.focus_item);
	// front to back: a modal window on top (an alert) hides the windows below it from VoiceOver too, but they are still
	// on screen; the host decides (it knows every process's windows)
	for (int i = 0; i < (int)wins.count; i++) {
		w.win = i;
		w.off = window_origin(wins[i]);
		w.rot = window_rot(wins[i], w.screen.size, &w.portrait);
		w.clip = CGRectIntersection(w.screen, place(&w, to_screen(wins[i], [wins[i] bounds])));
		walk(&w, wins[i], 0, nil);
	}
	if (w.focus) d[@"focus"] = hex(w.focus);
	if (w.focus_item) {
		CGRect ff = w.focus_frame;
		NSMutableDictionary* fd = [NSMutableDictionary dictionaryWithDictionary:@{ @"oid": hex(w.focus_item), @"class": NSStringFromClass([w.focus_item class]) }];
		if (!CGRectIsNull(ff)) fd[@"frame"] = @[ @(round(ff.origin.x * 10) / 10), @(round(ff.origin.y * 10) / 10), @(round(ff.size.width * 10) / 10), @(round(ff.size.height * 10) / 10) ];
		NSString* fl = nil;
		@try { fl = str([w.focus_item accessibilityLabel]); } @catch (id ex) { fl = nil; }
		if (fl) fd[@"label"] = fl;
		d[@"focus_item"] = fd;
	}
	if (w.full) {
		NSMutableArray* hidden = [NSMutableArray array];
		hidden_scan(&w, wins, hidden);
		if (hidden.count) d[@"hidden"] = hidden;
	}
	int budget = 5000;
	for (UIWindow* win in wins)
		if (animating_layer(win.layer, &budget)) { d[@"animating"] = @YES; break; }
	if (!w.webviews.count) {
		d[@"elements"] = w.out;
		reply(d);
		return;
	}
	dispatch_group_t g = dispatch_group_create();
	NSMutableArray* web = [NSMutableArray array];
#if SIMAX_WEB
	Walk* wp = &w;
	for (NSDictionary* wv in w.webviews) walk_web(wp, wv, web, g);
#endif
	NSMutableArray* out = w.out;
	// the JS answers arrive on the main queue: wait for them there, not by blocking it
	dispatch_group_notify(g, dispatch_get_main_queue(), ^{
		[out addObjectsFromArray:web];
		d[@"elements"] = out;
		reply(d);
	});
}

static id find_oid(NSString* oid) {
	// an element the last tree reported: walk again to find it by address (never dereference a stale pointer)
	Walk w = { 0 };
	w.out = [NSMutableArray array];
	w.webviews = [NSMutableArray array];
	w.seen = [NSMutableSet set];
	w.screen = screen_bounds();
	w.all = YES;
	w.budget = 20000;
	NSArray* wins = visible_windows();
	for (int i = 0; i < (int)wins.count; i++) {
		w.off = window_origin(wins[i]);
		w.rot = window_rot(wins[i], w.screen.size, &w.portrait);
		w.clip = w.screen;
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

// ---------------------------------------------------------------------------------------------------------------------
// A tap made inside the process (visionOS: the host cannot place a touch on a window floating in the room). The way
// in-process UI test tools (KIF) do it: a UITouch at a point of the window, with an IOHIDEvent digitizer event behind
// it, through UIApplication sendEvent: (gesture recognizers, SwiftUI buttons and links see an ordinary tap).
typedef struct __IOHIDEvent* SimaxHIDEventRef;

static SimaxHIDEventRef hid_touch_event(CGPoint p, BOOL down) {
	static SimaxHIDEventRef (*hand)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double,
		double, double, Boolean, Boolean, uint32_t);
	static SimaxHIDEventRef (*finger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, double,
		double, double, double, double, Boolean, Boolean, uint32_t);
	static void (*append)(SimaxHIDEventRef, SimaxHIDEventRef, uint32_t);
	static void (*setint)(SimaxHIDEventRef, uint32_t, long);
	if (!hand) {
		hand = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
		finger = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEventWithQuality");
		append = dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
		setint = dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
	}
	if (!hand || !finger || !append || !setint) return NULL;
	uint64_t t = mach_absolute_time();
	// a hand (transducer 3) with one finger: range + touch while down, then lifted
	SimaxHIDEventRef h = hand(kCFAllocatorDefault, t, 3, 0, 0, 2 /* touch */, 0, 0, 0, 0, 0, 0, false, down, 0);
	setint(h, 0xB0019 /* DigitizerIsDisplayIntegrated */, 1);
	SimaxHIDEventRef f = finger(kCFAllocatorDefault, t, 1, 2, 3 /* range | touch */, p.x, p.y, 0, 0, 0, 5, 5, 1, 1, 1, down, down, 0);
	append(h, f, 0);
	CFRelease(f);
	return h;
}

static BOOL send_touch(UITouch* touch, UITouchPhase phase, CGPoint p) {
	UIApplication* app = UIApplication.sharedApplication;
	SEL te = NSSelectorFromString(@"_touchesEvent");
	if (![app respondsToSelector:te]) return NO;
	UIEvent* ev = ((id(*)(id, SEL))objc_msgSend)(app, te);
	SimaxHIDEventRef hid = hid_touch_event(p, phase != UITouchPhaseEnded);
	if (!hid) return NO;
	((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, NSSelectorFromString(@"setPhase:"), phase);
	((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(touch, NSSelectorFromString(@"setTimestamp:"), NSProcessInfo.processInfo.systemUptime);
	if ([touch respondsToSelector:NSSelectorFromString(@"_setHidEvent:")])
		((void (*)(id, SEL, void*))objc_msgSend)(touch, NSSelectorFromString(@"_setHidEvent:"), hid);
	((void (*)(id, SEL))objc_msgSend)(ev, NSSelectorFromString(@"_clearTouches"));
	((void (*)(id, SEL, void*))objc_msgSend)(ev, NSSelectorFromString(@"_setHIDEvent:"), hid);
	((void (*)(id, SEL, id, BOOL))objc_msgSend)(ev, NSSelectorFromString(@"_addTouch:forDelayedDelivery:"), touch, NO);
	[app sendEvent:ev];
	CFRelease(hid);
	return YES;
}

// a tap at a point of a window (its own points)
static BOOL synth_tap(UIWindow* win, CGPoint p) {
	for (NSString* sel in @[ @"_touchesEvent" ])
		if (![UIApplication.sharedApplication respondsToSelector:NSSelectorFromString(sel)]) return NO;
	UIView* hit = [win hitTest:p withEvent:nil];
	if (!hit) return NO;
	UITouch* t = [[UITouch alloc] init];
	@try {
		((void (*)(id, SEL, id))objc_msgSend)(t, NSSelectorFromString(@"setWindow:"), win);
		((void (*)(id, SEL, id))objc_msgSend)(t, NSSelectorFromString(@"setView:"), hit);
		((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(t, NSSelectorFromString(@"_setLocationInWindow:resetPrevious:"), p, YES);
		if ([t respondsToSelector:NSSelectorFromString(@"_setIsFirstTouchForView:")])
			((void (*)(id, SEL, BOOL))objc_msgSend)(t, NSSelectorFromString(@"_setIsFirstTouchForView:"), YES);
		if ([t respondsToSelector:NSSelectorFromString(@"setIsTap:")]) ((void (*)(id, SEL, BOOL))objc_msgSend)(t, NSSelectorFromString(@"setIsTap:"), YES);
		if ([t respondsToSelector:NSSelectorFromString(@"setTapCount:")]) ((void (*)(id, SEL, NSUInteger))objc_msgSend)(t, NSSelectorFromString(@"setTapCount:"), 1);
		if ([t respondsToSelector:NSSelectorFromString(@"setGestureView:")]) ((void (*)(id, SEL, id))objc_msgSend)(t, NSSelectorFromString(@"setGestureView:"), hit);
		if (!send_touch(t, UITouchPhaseBegan, p)) return NO;
		// the lift comes a moment later on the main queue, as a finger's would (recognizers see a press, then an end)
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
			@try { send_touch(t, UITouchPhaseEnded, p); } @catch (id ex) { alog("touch end: %s", [[ex description] UTF8String]); }
		});
	} @catch (id ex) {
		alog("synth tap: %s", [[ex description] UTF8String]);
		return NO;
	}
	return YES;
}

// the window an accessibility element is in (its view's, or its containers' up to a view)
static UIWindow* window_of(id e) {
	for (id o = e; o; ) {
		if ([o isKindOfClass:[UIView class]]) return ((UIView*)o).window;
		id c = nil;
		@try { c = [o respondsToSelector:@selector(accessibilityContainer)] ? [o accessibilityContainer] : nil; } @catch (id ex) { c = nil; }
		o = c;
	}
	return nil;
}


// ---------------------------------------------------------------------------------------------------------------------
// action: what VoiceOver does to an element (Accessibility Inspector's actions): activate, increment / decrement (an
// adjustable), scroll (accessibilityScroll: up its containers, as a three-finger swipe), escape (accessibilityPerformEscape
// up the responder chain, as the two-finger Z), magic_tap (the two-finger double tap, up to the app delegate), custom
// (one of accessibilityCustomActions by name).

// the next object up: an element's container, a view's next responder (its controller, superview, the window, the
// application, its delegate)
static id up_of(id o) {
	id c = nil;
	if (![o isKindOfClass:[UIResponder class]]) {
		@try { c = [o respondsToSelector:@selector(accessibilityContainer)] ? [o accessibilityContainer] : nil; } @catch (id ex) { c = nil; }
		return c;
	}
	c = [(UIResponder*)o nextResponder];
	if (!c && o == UIApplication.sharedApplication) c = UIApplication.sharedApplication.delegate;
	return c;
}

static NSDictionary* perform_action(NSDictionary* req) {
	NSString* name = req[@"name"] ?: @"activate";
	NSString* oid = req[@"oid"];
	id e = nil;
	if (oid.length) {
		NSRange hash = [oid rangeOfString:@"#"];
		if (hash.location != NSNotFound) return @{ @"error": @"web content: no accessibility actions through the DOM (tap it)" };
		e = find_oid(oid);
		if (!e) return @{ @"error": @"element gone" };
	}
	BOOL chain = [name isEqualToString:@"escape"] || [name isEqualToString:@"magic_tap"];
	if (!e && chain) {
		e = first_responder();
		if (!e) e = visible_windows().lastObject.rootViewController.view ?: visible_windows().lastObject;
	}
	if (!e) return @{ @"error": @"no element (oid)" };
	NSMutableDictionary* r = [NSMutableDictionary dictionaryWithDictionary:@{ @"name": name }];
	BOOL ok = NO;
	NSString* by = nil;
	if ([name isEqualToString:@"activate"]) {
		ok = [e accessibilityActivate];
		by = NSStringFromClass([e class]);
	} else if ([name isEqualToString:@"increment"] || [name isEqualToString:@"decrement"]) {
		if (!([e accessibilityTraits] & UIAccessibilityTraitAdjustable)) r[@"note"] = @"not adjustable (no adjustable trait): VoiceOver would not offer it";
		NSString* before = str([e accessibilityValue]);
		if ([name isEqualToString:@"increment"]) [e accessibilityIncrement];
		else [e accessibilityDecrement];
		NSString* after = str([e accessibilityValue]);
		ok = !(before == after || [before isEqualToString:after]);
		by = NSStringFromClass([e class]);
	} else if ([name isEqualToString:@"scroll"]) {
		NSDictionary* dirs = @{ @"up": @(UIAccessibilityScrollDirectionUp), @"down": @(UIAccessibilityScrollDirectionDown),
			@"left": @(UIAccessibilityScrollDirectionLeft), @"right": @(UIAccessibilityScrollDirectionRight),
			@"next": @(UIAccessibilityScrollDirectionNext), @"previous": @(UIAccessibilityScrollDirectionPrevious) };
		NSNumber* dn = dirs[req[@"dir"] ?: @"down"];
		if (!dn) return @{ @"error": @"dir: up, down, left, right, next or previous" };
		int n = 0;
		for (id o = e; o && n < 60 && !ok; o = up_of(o), n++) {
			if (![o respondsToSelector:@selector(accessibilityScroll:)]) continue;
			@try { ok = [o accessibilityScroll:(UIAccessibilityScrollDirection)dn.integerValue]; } @catch (id ex) { ok = NO; }
			if (ok) by = NSStringFromClass([o class]);
		}
		// no container takes it (UIKit's scroll views do once the accessibility bundles are in): the nearest scroll view
		// moves a page, as VoiceOver's fallback
		if (!ok) {
			for (UIView* p = view_of(e); p; p = p.superview) {
				if (![p isKindOfClass:[UIScrollView class]]) continue;
				UIScrollView* sv = (UIScrollView*)p;
				CGPoint o = sv.contentOffset;
				CGSize b = sv.bounds.size, c = sv.contentSize;
				UIEdgeInsets in = sv.adjustedContentInset;
				switch (dn.integerValue) {
				// VoiceOver's directions are the swipe's: up shows what is below
				case UIAccessibilityScrollDirectionUp: case UIAccessibilityScrollDirectionNext: o.y = MIN(o.y + b.height * 0.8, c.height - b.height + in.bottom); break;
				case UIAccessibilityScrollDirectionDown: case UIAccessibilityScrollDirectionPrevious: o.y = MAX(o.y - b.height * 0.8, -in.top); break;
				case UIAccessibilityScrollDirectionLeft: o.x = MIN(o.x + b.width * 0.8, c.width - b.width + in.right); break;
				default: o.x = MAX(o.x - b.width * 0.8, -in.left); break;
				}
				if (CGPointEqualToPoint(o, sv.contentOffset)) continue;
				[sv setContentOffset:o animated:YES];
				ok = YES;
				by = [NSStringFromClass([sv class]) stringByAppendingString:@" (content offset)"];
				break;
			}
		}
	} else if (chain) {
		BOOL esc = [name isEqualToString:@"escape"];
		SEL s = esc ? @selector(accessibilityPerformEscape) : @selector(accessibilityPerformMagicTap);
		int n = 0;
		for (id o = e; o && n < 80 && !ok; o = up_of(o), n++) {
			if (![o respondsToSelector:s]) continue;
			@try { ok = ((BOOL(*)(id, SEL))objc_msgSend)(o, s); } @catch (id ex) { ok = NO; }
			if (ok) by = NSStringFromClass([o class]);
		}
		// escape on a navigation stack nobody answered for: what UIKit's own handler does (pop, else dismiss). Without a
		// focused element (SwiftUI's NavigationStack): the front window's deepest navigation controller that can go back
		if (!ok && esc && !oid.length) {
			UIViewController* best = nil;
			NSMutableArray* q = [NSMutableArray array];
			UIViewController* root = visible_windows().lastObject.rootViewController;
			if (root) [q addObject:root];
			for (int n = 0; q.count && n < 400; n++) {
				UIViewController* c = q[0];
				[q removeObjectAtIndex:0];
				if (c.presentedViewController) [q addObject:c.presentedViewController];
				[q addObjectsFromArray:c.childViewControllers];
				if ([c isKindOfClass:[UINavigationController class]] && ((UINavigationController*)c).viewControllers.count > 1 && c.viewIfLoaded.window)
					best = c;
			}
			if (best) {
				[(UINavigationController*)best popViewControllerAnimated:YES];
				ok = YES;
				by = [NSStringFromClass([best class]) stringByAppendingString:@" (pop)"];
			}
		}
		if (!ok && esc) {
			UIViewController* vc = controller_of(view_of(e));
			UINavigationController* nav = vc.navigationController ?: ([vc isKindOfClass:[UINavigationController class]] ? (UINavigationController*)vc : nil);
			if (vc.presentedViewController == nil && nav && nav.viewControllers.count > 1) {
				[nav popViewControllerAnimated:YES];
				ok = YES;
				by = @"UINavigationController (pop)";
			} else if (vc.presentingViewController) {
				[vc dismissViewControllerAnimated:YES completion:nil];
				ok = YES;
				by = @"UIViewController (dismiss)";
			}
		}
	} else if ([name isEqualToString:@"custom"]) {
		NSString* want = req[@"custom"] ?: @"";
		NSArray* ca = [e respondsToSelector:@selector(accessibilityCustomActions)] ? [e accessibilityCustomActions] : nil;
		UIAccessibilityCustomAction* hit = nil;
		for (int pass = 0; pass < 2 && !hit; pass++)
			for (UIAccessibilityCustomAction* a in ca) {
				NSString* n = names_of(a) ?: @"";
				if (pass == 0 ? [n caseInsensitiveCompare:want] == NSOrderedSame : [n.lowercaseString containsString:want.lowercaseString]) { hit = a; break; }
			}
		NSMutableArray* names = [NSMutableArray array];
		for (id a in ca) { NSString* n = names_of(a); if (n) [names addObject:n]; }
		if (!hit) return @{ @"error": [NSString stringWithFormat:@"no custom action \"%@\" (it has: %@)", want, names.count ? [names componentsJoinedByString:@", "] : @"none"] };
		@try {
			if ([hit respondsToSelector:@selector(actionHandler)] && hit.actionHandler) ok = hit.actionHandler(hit);
			else if (hit.target && hit.selector) {
				NSMethodSignature* sig = [hit.target methodSignatureForSelector:hit.selector];
				if (sig.numberOfArguments > 2) ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(hit.target, hit.selector, hit);
				else ok = ((BOOL(*)(id, SEL))objc_msgSend)(hit.target, hit.selector);
			}
		} @catch (id ex) {
			return @{ @"error": [NSString stringWithFormat:@"the custom action threw: %@", ex] };
		}
		by = names_of(hit);
	} else {
		return @{ @"error": @"name: activate, increment, decrement, scroll, escape, magic_tap or custom" };
	}
	r[@"ok"] = @(ok);
	if (by) r[@"by"] = by;
	@try {
		NSString* v = str([e accessibilityValue]);
		if (v) r[@"value"] = v;
	} @catch (id ex) {
	}
	return r;
}

static void handle(NSDictionary* req, void (^reply)(NSDictionary*)) {
	NSString* op = req[@"op"];
	if ([op isEqualToString:@"tree"]) { tree(req, reply); return; }
	if ([op isEqualToString:@"info"]) { reply(info()); return; }
	if ([op isEqualToString:@"probe"]) {
		// debugging: every scene and window of the process, visible or not
		NSMutableArray* scs = [NSMutableArray array];
		for (UIScene* sc in UIApplication.sharedApplication.connectedScenes)
			[scs addObject:@{ @"class": NSStringFromClass([sc class]), @"state": @(sc.activationState), @"id": sc.session.persistentIdentifier ?: @"" }];
		NSMutableArray* ws = [NSMutableArray array];
		SEL all = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
		NSArray* every = [UIWindow respondsToSelector:all] ? ((NSArray * (*)(id, SEL, BOOL, BOOL)) objc_msgSend)([UIWindow class], all, YES, NO) : @[];
		for (UIWindow* w in every)
			[ws addObject:@{ @"class": NSStringFromClass([w class]), @"hidden": @(w.hidden), @"alpha": @(w.alpha), @"level": @(w.windowLevel),
				@"scene": w.windowScene ? NSStringFromClass([w.windowScene class]) : @"", @"frame": NSStringFromCGRect(w.frame) }];
		reply(@{ @"scenes": scs, @"windows": ws, @"state": app_state() });
		return;
	}
	if ([op isEqualToString:@"ax"]) { load_ax(); reply(@{ @"ax": @YES }); return; }
	if ([op isEqualToString:@"type"]) { reply(type_text(req)); return; }
	if ([op isEqualToString:@"action"]) { reply(perform_action(req)); return; }
	if ([op isEqualToString:@"scrollby"]) {
		// scroll the largest visible scroll view by a part of its height / width (visionOS: no touches reach a window
		// from the host; the content moves as a scroll gesture would move it, without momentum)
		NSString* dir = req[@"dir"] ?: @"down";
		double amount = req[@"amount"] ? [req[@"amount"] doubleValue] : 0.5;
		UIScrollView* best = nil;
		double area = 0;
		NSMutableArray* stack = [NSMutableArray arrayWithArray:visible_windows()];
		while (stack.count) {
			UIView* v = stack.lastObject;
			[stack removeLastObject];
			if (view_hidden(v)) continue;
			if ([v isKindOfClass:[UIScrollView class]] && v.window) {
				UIScrollView* sv = (UIScrollView*)v;
				BOOL can = [dir isEqualToString:@"down"] || [dir isEqualToString:@"up"] ? sv.contentSize.height > sv.bounds.size.height + 1
					: sv.contentSize.width > sv.bounds.size.width + 1;
				double a = sv.bounds.size.width * sv.bounds.size.height;
				if (can && sv.scrollEnabled && a > area) { best = sv; area = a; }
			}
			[stack addObjectsFromArray:v.subviews];
		}
		if (!best) { reply(@{ @"error": @"no scroll view that scrolls that way" }); return; }
		CGPoint o = best.contentOffset;
		UIEdgeInsets in = best.adjustedContentInset;
		CGSize b = best.bounds.size, c = best.contentSize;
		if ([dir isEqualToString:@"down"]) o.y = MIN(o.y + b.height * amount, c.height - b.height + in.bottom);
		else if ([dir isEqualToString:@"up"]) o.y = MAX(o.y - b.height * amount, -in.top);
		else if ([dir isEqualToString:@"right"]) o.x = MIN(o.x + b.width * amount, c.width - b.width + in.right);
		else o.x = MAX(o.x - b.width * amount, -in.left);
		BOOL moved = !CGPointEqualToPoint(o, best.contentOffset);
		[best setContentOffset:o animated:NO];
		reply(@{ @"ok": @YES, @"moved": @(moved), @"view": NSStringFromClass([best class]) });
		return;
	}
	if ([op isEqualToString:@"scroll"] || [op isEqualToString:@"activate"]) {
		NSString* oid = req[@"oid"];
		NSRange hash = [oid rangeOfString:@"#"];
		id e = find_oid(hash.location == NSNotFound ? oid : [oid substringToIndex:hash.location]);
		if (!e) { reply(@{ @"error": @"element gone" }); return; }
		BOOL ok = NO;
		if ([op isEqualToString:@"activate"]) {
			ok = [e accessibilityActivate];
			// what VoiceOver does when an element does not activate itself: a tap at its activation point (SwiftUI's
			// list rows / links). "tap": do that in the process
			if (!ok && [req[@"tap"] boolValue]) {
				UIWindow* win = window_of(e);
				CGPoint sp = [e accessibilityActivationPoint];
				CGPoint wp = sp;
				if (win.windowScene) wp = [win convertPoint:sp fromCoordinateSpace:win.windowScene.coordinateSpace];
				BOOL tapped = win && synth_tap(win, wp);
				reply(@{ @"ok": @(tapped), @"tapped": @(tapped), @"at": @[ @(wp.x), @(wp.y) ] });
				return;
			}
		}
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
		// a request is one JSON line: past 4 MB without a newline the connection is dropped
		if (buf.length > (4u << 20) && !memchr(buf.bytes, '\n', buf.length)) break;
		for (;;) {
			const char* b = buf.bytes;
			const char* nl = memchr(b, '\n', buf.length);
			if (!nl) break;
			NSData* line = [NSData dataWithBytes:b length:nl - b];
			[buf replaceBytesInRange:NSMakeRange(0, nl - b + 1) withBytes:NULL length:0];
			@autoreleasepool {
				NSDictionary* req = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
				if (![req isKindOfClass:[NSDictionary class]]) req = @{ @"op": @"info" };
				// this runs outside the @try below: a timeout that is no number ("timeout": []) must not raise here
				id tv = req[@"timeout"];
				double timeout = [tv isKindOfClass:[NSNumber class]] ? [tv doubleValue] : 5.0;
				if (!(timeout >= 0.1)) timeout = 0.1;
				if (timeout > 600) timeout = 600;
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
		set_fg(![app_state() isEqualToString:@"background"]);
	}];
	// a view service's scene / hosted window comes and goes without the application's notifications
	for (NSString* n in @[ UISceneWillEnterForegroundNotification, UISceneDidActivateNotification, UISceneDidEnterBackgroundNotification,
		     UISceneDidDisconnectNotification, UIWindowDidBecomeVisibleNotification, UIWindowDidBecomeHiddenNotification ])
		[nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification* note) {
			// after UIKit updated the scene's state
			dispatch_async(dispatch_get_main_queue(), ^{ set_fg(![app_state() isEqualToString:@"background"]); });
		}];
	[nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification* note) {
		cleanup();
	}];
	set_fg(![app_state() isEqualToString:@"background"]);
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
