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
static void load_ax(void) {
	if (atomic_exchange(&g_ax_loaded, true)) return;
	void* h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY);
	void (*set_auto)(int) = h ? dlsym(h, "_AXSSetAutomationEnabled") : NULL;
	void (*set_app)(int) = h ? dlsym(h, "_AXSApplicationAccessibilitySetEnabled") : NULL;
	if (set_app) set_app(1);
	if (set_auto) set_auto(1);
	// UIKit's own initializer re-reads the settings and loads the bundles for UIKit and this process's frameworks
	void (*init)(void) = dlsym(RTLD_DEFAULT, "_UIAccessibilityInitialize");
	if (init) init();
	alog("ax: automation %p app %p init %p", set_auto, set_app, init);
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
} Walk;

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
	CGRect vis = to_screen(v, v.bounds);
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
	for (UIWindow* w in visible_windows()) {
		CGRect f = to_screen(w, w.bounds);
		[ws addObject:@{ @"class": NSStringFromClass([w class]), @"level": @(w.windowLevel), @"key": @(w.isKeyWindow),
			@"frame": @[ @(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height) ] }];
	}
	d[@"windows"] = ws;
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
	if (![req[@"noax"] boolValue]) load_ax();
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
	NSArray* wins = visible_windows();
	// front to back: a modal window on top (an alert) hides the windows below it from VoiceOver too, but they are still
	// on screen; the host decides (it knows every process's windows)
	for (int i = 0; i < (int)wins.count; i++) {
		w.win = i;
		walk(&w, wins[i], 0, nil);
	}
	if (w.focus) d[@"focus"] = hex(w.focus);
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
	for (int i = 0; i < (int)wins.count; i++) walk(&w, wins[i], 0, nil);
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
