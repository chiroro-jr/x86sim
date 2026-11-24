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
`[w, h, scale]` in points, `windows` (`class`, `level`, `key`, `frame`, back to front), `ms` and `wait_ms`.

| op | arguments | answer |
|---|---|---|
| `info` | | the fields above |
| `tree` | `fg` (only walk when on screen), `all` (include elements scrolled out of view), `noax` | plus `elements`, `focus` (oid of the first responder), `animating` |
| `type` | `text`, `clear`, `submit` | `typed`, `field` (class), `value` |
| `scroll` | `oid` | `ok` (`accessibilityScrollToVisible`, else `scrollRectToVisible` in the nearest scroll view) |
| `activate` | `oid` | `ok` (`accessibilityActivate`) |
| `ax` | | loads the accessibility bundles |

An element contains `oid` (the object's address in hex; web elements use `<webview oid>#<n>`), `role`,
`label`, `value`, `id`, `hint`, `frame` `[x, y, w, h]` in screen points, `traits`, `enabled` (only when
false), `selected`, `focused`, `offscreen`, `win` (an index into `windows`), `depth`, `in` (the label of the
enclosing container), `class` and, for web elements, `web` and `href`.

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

## Host

`ax.rs` asks every `.fg` process in parallel and merges the answers into one `Snapshot`. It assigns layers:
SpringBoard windows are `system` (alerts, banners, Control Center) or `home`, status bar elements are `status`,
and everything else is `app`. Refs are kept in `<state dir>/ax-refs.json`, keyed by the frame ring's inode and
birth time, which change with every boot. An element keeps its ref while it is the same object with the same role
and label or identifier. Failing that, it takes the ref of the only previous element of the same app with the same
role and identifier, or of the nearest one with the same role and label. After an action, the host waits for the
frame ring to go quiet (350 ms, at most 4 s) and for `animating` to clear (at most 6 s), then takes the snapshot.
