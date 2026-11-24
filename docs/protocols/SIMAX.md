# simax: the accessibility reader

`host/simax/simax.m` (`libsimax.dylib`, arm64 per platform) shows a phone's screen to agents as accessibility
elements. The host side is `tools/launcher/core/src/ax.rs`: the MCP tools `snapshot`, `tap` and the others, and
`x86sim snapshot` / `x86sim-ax`.

## Loading

`mksimdevice.py` sets `X86SIM_AX_DYLIB` in every simulator process's environment. libsimshim's `shim_ax_init`
dlopens that dylib only when UIKitCore is among the images loaded at launch, so daemons never load it. Its
constructor waits for `UIApplicationDidFinishLaunchingNotification`, which means many daemons that link UIKit
(sharingd, mobileassetd and others) never open a socket. `X86SIM_AX_OFF=1` turns it off, and `X86SIM_AX_LOG=1`
logs to stderr.

The first `tree` request in a process loads UIKit's accessibility bundles by turning accessibility automation on,
as XCUITest does (`_AXSApplicationAccessibilitySetEnabled`, `_AXSSetAutomationEnabled`, `_UIAccessibilityInitialize`).
Without the bundles, SpringBoard icons, SwiftUI views and most system UI have no labels. The setting is stored in
the device, so apps launched later load the bundles at startup. It costs about 0.1-0.2 s on the first snapshot of a
running process.

## Endpoints

Each application listens on a Unix socket next to the phone's frame ring:

```
/run/user/<uid>/x86sim-ax-<SIMULATOR_UDID>-<pid>.sock     (in Darling: /Volumes/SystemRoot/run/user/...)
/run/user/<uid>/x86sim-ax-<SIMULATOR_UDID>-<pid>.fg       exists while the process is on screen
```

`.fg` is created when the app enters the foreground or becomes active, and removed when it enters the background
or terminates. SpringBoard keeps its own. The host only asks processes that have one. Connections are
non-blocking, because a process RunningBoard suspended (a poster extension, for example) never accepts. A process
that did not answer is given 80 ms the next time, until it answers again. `mksimdevice.py` removes the previous
boot's files, and the host removes the files of a socket that refuses connections.

One listener thread serves one client at a time. Threads that exit (`pthread_exit`) are avoided on purpose.

## Requests

The client sends one JSON object per line and gets one JSON line back for each. Requests run on the main queue. A
request that is not answered within `timeout` seconds (default 5) gets `{"error": "busy: ..."}`. Every answer
carries `pid`, `bundle`, `process`, `state` (`active`, `inactive`, `background`, `none`), `screen`
`[w, h, scale]` in points, `orient`, `windows` (`class`, `level`, `key`, `frame`, `orient`, `screen`, back to
front), `ms` and `wait_ms`.

`screen` and `orient` are those of the process's key window (else its largest): the bounds of the screen it is on
and its scene's `UIInterfaceOrientation` (1 portrait, 2 upside down, 3 landscape left, 4 landscape right). UIKit's
screen coordinates turn with the interface, not with the device: a portrait-only app on a phone held sideways keeps
portrait coordinates, so the host turns touches by the interface orientation, not by the device's. `main_screen`
says whether that screen is `UIScreen.mainScreen` and `display` gives its display id (a two-screen phone).

| op | arguments | answer |
|---|---|---|
| `info` | | the fields above |
| `tree` | `fg` (only walk when on screen), `all` (include elements scrolled out of view), `noax` | plus `elements`, `focus` (oid of the first responder), `animating`, `web_pending` |
| `type` | `text`, `clear`, `submit` | `typed`, `field` (class), `value` |
| `scroll` | `oid` | `ok` (`accessibilityScrollToVisible`, else `scrollRectToVisible` in the nearest scroll view) |
| `activate` | `oid` | `ok` (`accessibilityActivate`) |
| `ax` | | loads the accessibility bundles |

An element contains `oid` (the object's address in hex; web elements use `<webview oid>#<key>`), `role`,
`label`, `value`, `id`, `hint`, `frame` `[x, y, w, h]` in screen points, `traits`, `enabled` (only when
false), `selected`, `focused`, `offscreen`, `win` (an index into `windows`), `depth`, `in` (the label of the
enclosing container), `class`, `key` and, for web elements, `web`, `href` and `frame_url` (content of an iframe).

`key` names what stays when the object does not. A table or collection view recycles its cells while it scrolls,
so the same object shows another row. An element inside a cell gets `<list oid>:<section>.<item>/<role><n>`, its
row's index path and the n-th element of that role in the cell. A web element gets `dom:<tag>.<n>`: a number the
DOM node keeps for the life of its document (a `WeakMap` in the isolated world), prefixed by a random tag of that
document.

The walk follows the containment VoiceOver uses. An accessibility element is a leaf, except that a cell holding a
text field or switch is looked into. A container provides `accessibilityElements`, or a count and an index. A
plain view provides its subviews. Hidden views and `accessibilityElementsHidden` are skipped. A child with
`accessibilityViewIsModal` hides its siblings. Off-screen elements are dropped unless `all` is set.

Roles: `textfield`, `searchfield`, `switch`, `adjustable`, `key`, `tabbar`, `link`, `button`, `heading`,
`image`, `text`, `icon` (SpringBoard), `element` (anything else with a label, value or identifier), and the web
roles below.

`animating` is true while a one-shot Core Animation animation runs in one of the process's windows, such as a push,
a sheet or an alert appearing. Looping animations, such as spinners or the caret, do not count. The host waits
for it after an action.

### WebKit

The accessibility tree of a web page lives in the WebContent process, so each `WKWebView` on screen is read through
its DOM instead. A script runs in an isolated content world (`WKContentWorld.defaultClientWorld`), so page scripts
and CSP do not affect it. It returns the visible links, buttons, form fields (with values), selects,
headings, images with alt text, ARIA roles and text blocks. Their CSS rects are converted to screen points through
the web view's scroll view (content = page coordinates times `zoomScale`). The web view itself is reported as a
`webview` element whose label is the page title and whose value is its URL.

Every frame is read, iframes of the same or another origin included: WebKit's frame tree (`-[WKWebView _frames:]`)
gives each frame's `WKFrameInfo`, and the script runs in each (`evaluateJavaScript:inFrame:inContentWorld:`). A
frame's walk also reports its `<iframe>` elements: URL, content box (border and padding excluded) and whether they
are shown. A child frame is matched to its `<iframe>` by URL, else in document order, and its elements are moved by
the content box and clipped to it. Elements of a hidden iframe, or of one that cannot be placed, are left out.

Web content gets about 80% of the request's `timeout`. Frames that have not answered by then are left out and
counted in `web_pending`, so a busy WebContent process does not cost the whole snapshot.

## Host

`ax.rs` asks every `.fg` process in parallel and merges the answers into one `Snapshot`. It assigns layers:
SpringBoard windows are `system` (alerts, banners, Control Center) or `home`, status bar elements are `status`,
and everything else is `app`. Refs are kept in `<state dir>/ax-refs.json`, keyed by the frame ring's inode and
birth time, which change with every boot. An element keeps its ref while it has the same `key` in the same process
(a cell's element also needs the same label, identifier or object, or else the rows moved), or else while it is the
same object with the same role and label or identifier. Failing that, it takes the ref of the only previous element
of the same app with the same role and identifier, or of the nearest one with the same role and label. Two keyed
elements of one process with different keys never trade refs on a shared label, such as the "by" and "|" on every
row of a web page, unless that label is unique on both sides.

Touches are given in the points of an element's window, or for a bare point in the front app's. The host turns
them by that window's interface orientation onto the panel. An unfolded iPhone Duo's touches go to its inner
screen's display (`@<id> touch`, its native turn added), and settling and screenshots use that screen's ring. A
snapshot says `· inner screen` / `· outer screen` and `· landscape` in its first line.

A process on screen that does not answer is reported in `busy` by bundle and pid the first time ("no answer in
6.0 s"). After that it gets 80 ms per snapshot and is not reported again until it answers. When no process on
screen answers at all, the snapshot fails and names them.

After an action, the host waits for the frame ring to go quiet (350 ms, at most 4 s) and for `animating` to clear
(at most 6 s), then takes the snapshot.
