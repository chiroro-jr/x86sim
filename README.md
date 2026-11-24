<div align="center">

# x86Sim

**Apple's iOS, iPadOS, tvOS, watchOS and visionOS simulators on x86-64 Linux.**

[![Latest release](https://img.shields.io/github/v/release/x86sim/x86sim?label=release)](https://github.com/x86sim/x86sim/releases/latest)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

[Download](https://github.com/x86sim/x86sim/releases/latest) · [Quick start](#quick-start) · [Usage](#usage) · [Building apps](#building-and-shipping-apps) · [Architecture](docs/ARCHITECTURE.md) · [Developing](docs/DEVELOPMENT.md)

<img src="docs/screens/launcher-devices.webp" alt="The x86Sim launcher with several simulated devices running side by side" width="100%">

</div>

## About

Apple ships its device simulators only for Macs. x86Sim runs the same arm64 simulator runtimes, unmodified, on an
ordinary x86-64 Linux PC. It downloads a runtime from Apple onto your machine, runs it on a macOS-compatible system
layer, translates its arm64 code to x86-64 and draws its Metal graphics with Vulkan.

It comes with a desktop launcher, a `simctl`-style command line and an MCP server, so devices can be used by hand,
from scripts or by an AI agent. No Mac and no Apple ID are needed.

## Features

**Devices**

- iPhone, iPad, Apple TV, Apple Watch and Apple Vision Pro: 82 device models, including the dual-screen iPhone
  Duo, whose hinge moves from closed to flat on a slider, with the poses of Xcode's DeviceHub (closed, half open in
  portrait or landscape, open).
- Several devices at once. Each runs in its own container with its own apps, data and settings; starting or stopping
  one leaves the others alone.
- The stock system apps of each runtime, such as Settings, Safari, Photos, Files, Maps and Health.

**Apps**

- Install, launch, terminate and uninstall your own apps: arm64 iOS-simulator builds, the kind Xcode produces for
  the simulator.
- Launch with arguments and environment variables, stream an app's stdout, stderr or `os_log`, or have it wait for a
  debugger.
- Find an app's bundle, data and app-group containers as ordinary Linux paths.

**Graphics and input**

- GPU rendering: Metal is translated to Vulkan for the system's render server and for apps. Software rendering is
  available as a fallback.
- Touch with the mouse: tap, swipe, edge gestures, pinch and two-finger scroll. Your keyboard types into the device,
  and Ctrl+V pastes from the Linux clipboard.
- Home, lock and volume buttons; an on-screen Siri Remote for Apple TV; a Digital Crown and side button for Apple
  Watch; look-and-pinch for Apple Vision Pro, driven by the mouse.

**Performance and memory**

- arm64 code is translated just in time and kept in a persistent cache.
- Pre-translation builds an ahead-of-time image for a runtime, once, so boots and app launches are fast. It updates
  incrementally when something changes.
- Feature sets: turn off the parts of the system a device doesn't need (Siri, Maps, Wallet, widgets, the live
  wallpaper and others), individually or with the Full, Lean and Minimal presets. Each one lists its memory cost.
- An optional memory cap per device, and a clean-up service that reclaims idle background processes.
- Live memory, CPU and per-process figures for every device.

**Developer tools**

- Simulated push notifications, simulated location (a point, a route between waypoints or one of Apple's scenarios),
  opening URLs, and adding photos and videos to the Photos library.
- Screenshots and H.264 / HEVC video recording.
- Scripted input: tap, swipe, pinch, type, hardware keys, Digital Crown.
- Per-service logs for every device, with filtering. Installed apps' `os_log` / `Logger` output is stored and can be
  read back with `OSLogStore`.

**Setup and updates**

- One AppImage. A setup page checks the computer, downloads a runtime from Apple, pre-translates it and creates the
  first device.
- No root where unprivileged user namespaces are available.
- Runtimes are managed on a Versions page: download, resume and remove iOS, tvOS, watchOS and visionOS versions.
- The AppImage updates itself, on a stable or a pre-release channel.
- The launcher follows the Omarchy theme live (or the desktop's light / dark setting), and every page can be driven
  from the keyboard: `?` lists the shortcuts.

<table>
<tr>
<td width="50%"><img src="docs/screens/launcher-iphone.webp" alt="An iPhone in the launcher, next to its memory, CPU and per-process figures"></td>
<td width="50%"><img src="docs/screens/launcher-versions.webp" alt="The Versions page, listing installed runtimes and those available from Apple"></td>
</tr>
<tr>
<td align="center"><sub>A device with its memory, CPU and processes</sub></td>
<td align="center"><sub>Runtimes, downloaded from Apple</sub></td>
</tr>
<tr>
<td width="50%"><img src="docs/screens/launcher-apple-tv.webp" alt="An Apple TV in the launcher, with its remote beside the screen"></td>
<td width="50%"><img src="docs/screens/launcher-apple-watch.webp" alt="An Apple Watch in the launcher, showing its app grid"></td>
</tr>
<tr>
<td align="center"><sub>Apple TV</sub></td>
<td align="center"><sub>Apple Watch</sub></td>
</tr>
<tr>
<td width="50%"><img src="docs/screens/launcher-vision-pro.webp" alt="An Apple Vision Pro in the launcher, showing its Home View"></td>
<td width="50%"><img src="docs/screens/launcher-keys.webp" alt="The launcher's keyboard shortcuts"></td>
</tr>
<tr>
<td align="center"><sub>Apple Vision Pro</sub></td>
<td align="center"><sub>Driven from the keyboard</sub></td>
</tr>
</table>

## Quick start

1. Download `x86sim-*-x86_64.AppImage` from the [latest release](https://github.com/x86sim/x86sim/releases/latest).
2. Make it executable and run it:
   ```sh
   chmod +x x86sim-*-x86_64.AppImage
   ./x86sim-*-x86_64.AppImage
   ```
3. Follow the **Setup** page. It checks your computer, prepares the simulator host, downloads iOS 27.2 from Apple
   (about 8 GB), pre-translates it and creates your first device.

Where unprivileged user namespaces are available, nothing is installed outside your home directory and no root is
needed. Where they are blocked (Ubuntu's default, for example), Setup asks for your password once to install the
simulator host under `/opt/x86sim`.

For an Apple TV, an Apple Watch or an Apple Vision Pro, download tvOS, watchOS or visionOS on the **Versions** page,
then choose **Add device**.

## Requirements

| | |
|---|---|
| **OS** | x86-64 Linux with glibc 2.39 or newer: Ubuntu 24.04+, Debian 13, Fedora 39+, Arch and derivatives |
| **CPU** | x86-64 with SSE4.1, POPCNT and CX16 |
| **GPU** | A Vulkan GPU and driver: NVIDIA (proprietary driver) or Mesa (RADV, ANV). Without one, rendering falls back to software |
| **Memory** | 8 GB minimum, 16 GB recommended |
| **Disk** | 45 GB free while a runtime downloads and unpacks |
| **Kernel** | overlayfs; Linux 6.11 or newer is a little faster |

Setup also looks for a few common programs (`python3`, `curl`, `openssl`, `setsid`) and tells you if one is
missing. Everything else is inside the AppImage.

FoundationModels (Apple's on-device language model) needs a Mac with Apple Intelligence, as Apple's own simulators do:
set `X86SIM_FM_RELAY` to it (see `x86sim.env.example`); without one the model reports that it isn't ready.

systemd is optional. With a systemd user manager, each phone runs in a scope with a disk IO cap and low CPU priority
(and the optional memory cap `X86SIM_MEM_MAX`), so a cold boot doesn't stall the desktop. Without one (Devuan, Void,
Gentoo/OpenRC, ...) phones run without those limits and everything else works the same.

## Supported devices and versions

| Device | Runtime | Models | Input |
|---|---|---|---|
| **iPhone** | iOS 27 | 34, from iPhone 11 to iPhone 18 Pro Max, and the iPhone Duo | Touch and gestures, keyboard, Home, lock and volume |
| **iPad** | iOS 27 (iPadOS) | 29: iPad, iPad mini, iPad Air, iPad Pro | Touch and gestures, keyboard, Home, lock and volume |
| **Apple TV** | tvOS 27 | 4: Apple TV 4K, 2nd and 3rd generation | Siri Remote on screen; arrow keys, Return and Escape |
| **Apple Watch** | watchOS 27 | 13: Series 9 to 12, SE 3, Ultra 2 to 4 | Touch, Digital Crown, side button |
| **Apple Vision Pro** | visionOS 27 | 2: at 4K, or at 1080p (the same layout, a quarter of the pixels) | Look and pinch with the mouse, Digital Crown |

Runtimes come straight from Apple's own catalogue, the one Xcode reads. Each copy is downloaded on your machine and
is never redistributed. iOS 27.2 is the default; the Versions page lists the other 27.x releases Apple offers,
with betas if you ask for them.

## Usage

### Launcher

The launcher is what the AppImage opens. Its pages:

- **Devices**: every device as a card with a live screen, running devices first. Click a card to open it; start,
  stop, restart, add, rename and remove devices, or open one in its own window. A device's page has its screen and buttons, its feature toggles, memory, CPU and
  processes, and its logs.
- **Versions**: the runtimes on this computer and those available from Apple.
- **Pre-translate**: build or update the ahead-of-time image for a runtime, and see what it takes on disk.
- **Settings**: appearance (System, Dark or Light), graphics (GPU or software), screen scaling, memory cap and
  clean-up, disk use, and updates.
- **Setup**: the first-run steps, which stay available afterwards as a check of the computer.

Arrow keys or `hjkl` move between devices and rows, Enter opens, the number keys switch pages, `?` lists every
shortcut and `q` quits. Closing the launcher leaves running devices running.

### Command line

`x86sim` follows `xcrun simctl` where there is an equivalent. From the AppImage it is
`./x86sim-*.AppImage x86sim <command>`; in a checkout it is `cli/x86sim`.

```sh
x86sim device models                          # the models a device can be
x86sim device create --model "iPhone 17 Pro" work
x86sim runtime list all                       # runtimes in Apple's catalogue

x86sim install MyApp.app                      # an arm64 iOS-simulator build
x86sim launch --console com.example.myapp -arg value
x86sim terminate com.example.myapp
x86sim listapps --json
x86sim get_app_container com.example.myapp data

x86sim openurl https://example.com
x86sim push com.example.myapp payload.json    # simulated remote notification
x86sim location set 48.8584,2.2945            # also: routes and scenarios
x86sim addmedia photo.jpg clip.mov
x86sim log stream --app com.example.myapp

x86sim tap 200 400                            # also: swipe, pinch, type, key, home, lock, crown
x86sim --phone work snapshot                  # the screen as text (see "Agents" below); --phone on any command
x86sim screenshot shot.png
x86sim io recordVideo --secs 10 out.mp4
```

`x86sim help` lists every command. A second tool, `x86sim-aot` (`./x86sim-*.AppImage aot`), starts and stops
devices, edits feature sets and builds the pre-translated image from a terminal.

### In a browser (local or remote)

`x86sim serve` puts every device in a browser tab: a dashboard with live thumbnails (start, stop, share), and a
device's live screen with its controls. The screen streams as H.264 decoded by WebCodecs (JPEG where the browser
lacks it, e.g. plain HTTP on the LAN); quality, size and frame rate are picked on the page.

- **Input**: click or drag to touch (edge swipes become Home, Control Center and Notification Center as on a
  device), real multi-touch from a touchscreen, Alt + drag to pinch or rotate, Shift + drag for a two-finger pan, the
  wheel scrolls (the Digital Crown on a watch, the remote's swipes on a TV), the hardware keyboard (Ctrl / Cmd is
  Command), Ctrl+V types the clipboard into the device, F1 to F4 Home, Lock and volume.
- **Controls per platform**: iPhone / iPad buttons (Home, Lock, volume, Siri, Action, App Switcher), rotate, shake,
  the iPhone Duo's fold poses; an Apple TV's Siri Remote; an Apple Watch's crown, side button and hand gestures.
- **Capture**: a full-size PNG screenshot, and recording the stream to a video file.
- **Links**: a control link (watch and drive) and a view-only link; more links with their own expiry, limited to
  one device or not, from the Share dialog (with a QR code) or `x86sim serve link`; revoke them there.

```sh
x86sim serve --open                 # http://127.0.0.1:7380, opened in the browser
x86sim serve --bg --tailscale       # also https://<machine>.<tailnet>.ts.net, tailnet only (tailscale serve)
x86sim serve --bg --funnel          # the same address, public (tailscale funnel)
x86sim serve --bg --cloudflared     # a public https://*.trycloudflare.com quick tunnel
x86sim serve --cloudflared --cf-tunnel NAME --cf-host phones.example.com   # a named tunnel you set up
x86sim serve --listen 0.0.0.0:7380  # the LAN, plain HTTP
x86sim serve status | stop | stop cloudflared
x86sim serve link --phone work --ttl 2h          # a view-only link; --control to drive
```

It listens on loopback unless told otherwise and has no TLS of its own: remote access goes through Tailscale or
cloudflared, which bring HTTPS. Only a browser on this machine gets in without a token; everything else, tunnels
included, needs the token in the link. `--ttl` makes the printed links expire. In the launcher, the globe button
beside a device's screen opens it in the browser, and its Share section turns tunnels on and off, copies links and
stops sharing. Tailscale must be logged in, with Serve (and Funnel) enabled for the tailnet; `x86sim serve` shows
the admin link when they are not.

### MCP server

`x86sim-mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio for AI agents and
other MCP clients. Its tools list, create, start, stop and restart devices, fold the iPhone Duo, read and change
feature sets, install, launch, list and uninstall apps, report the state of the pre-translated image, and share
devices in a browser (`share_start`, `share_stop`, `share_status`, `share_link`: they return the URLs). Agents can
also read the screen as text and act on its elements (below).

```sh
claude mcp add x86sim -- /path/to/x86sim.AppImage mcp      # AppImage
claude mcp add x86sim -- /path/to/x86sim-mcp               # built from source
```

#### Agents: reading the screen and acting on it

An agent drives a running phone through the screen as text. `snapshot` lists the accessibility elements on screen:
the app in front (UIKit and SwiftUI), web pages it shows (links, buttons, fields, headings and text from the DOM),
and SpringBoard (alerts and other system UI on top, the home screen, the status bar). Each element gets a ref, its
role, label, value, identifier, states, and the point to touch:

```
phone ram2 · 402x874 pt · front com.apple.Preferences
app com.apple.Preferences:
@e17 button "General" id=com.apple.settings.general (201,319)
@e18 button "Accessibility" id=com.apple.settings.accessibility (201,371)
@e28 searchfield "Search" (201,822)
status bar: 2:23 AM | Cellular: No signal | 100% battery power: Not charging
```

- **Refs are stable.** An element keeps its ref for as long as it is on screen, across snapshots and CLI calls,
  so an agent can act on a ref it saw a few steps back. `snapshot diff=true` shows only what changed (`+` new,
  `-` gone, `~` a label, value or state changed).
- **Actions answer with the result.** `tap`, `long_press`, `type`, `key`, `scroll`, `scroll_to`, `swipe`,
  `press`, `open_url`, `app_launch` and `app_terminate` wait until the screen has settled (no new frames and no
  transition still running) and answer with the next snapshot, or only the changes (`after: "diff"`), or nothing
  (`after: "none"`).
- **Targets**: a ref (`@e3`), an accessibility identifier (`id:com.apple.settings.general`), label text (exact,
  then prefix, then substring, with an alert over the app before the app beneath it), or `x`/`y` in points. An
  element the app has loaded but scrolled out of view is scrolled into view before it is tapped.
- **Typing** inserts text into the focused field as the software keyboard does, so any characters work (`clear`
  empties the field first, `submit` presses return). `keys=true` presses hardware keys instead.
- **`wait_for`** returns when a target appears (or, with `gone`, disappears). It checks again on every new
  frame rather than polling on a timer.
- **`screenshot`** returns the screen as an image, one pixel per point by default, so its coordinates match the
  snapshot's.

Every tool takes `phone` (a name, a folder or a path). The same commands are on the command line:

```sh
x86sim --phone ram2 snapshot [--diff] [--all] [--json]
x86sim --phone ram2 tap @e17                 # or: tap "General", tap id:com.apple.settings.general
x86sim --phone ram2 type "hello@example.com" --submit
x86sim --phone ram2 scroll-to "Privacy & Security"
x86sim --phone ram2 wait-for "Wi-Fi" --timeout 10
x86sim --phone ram2 screenshot shot.png      # points; --scale 1 for device pixels
```

Snapshots come from host/simax, a reader loaded into every process that has UIKit
([docs/protocols/SIMAX.md](docs/protocols/SIMAX.md)). On an iPhone 17, a snapshot that has settled takes about 10 ms in Settings, about 15 ms on the
home screen, and 25-35 ms for a long web page (about 130 elements). It works on iPhone and iPad, and is built for
tvOS, watchOS and visionOS too.

## Building and shipping apps

x86Sim runs and tests apps. The other half of iOS development without a Mac, building, signing, installing on a
real iPhone and publishing, is [omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev). x86Sim
carries our fork of it ([x86sim/omarchy-apple-dev](https://github.com/x86sim/omarchy-apple-dev)) in
`external/omarchy-apple-dev` and in the AppImage, and wraps it as `x86sim dev`, the launcher's **Develop** page and
the MCP server's `dev_*` tools:

```sh
x86sim dev status                     # Swift, xtool, the iOS SDK, device tools: what is ready, what to do next
x86sim dev setup                      # install what is missing (no root): Swift from swift.org if there is none,
                                      # xtool, rcodesign, ipsw, pymobiledevice3, then a test build
x86sim dev setup sdk --xip ~/Downloads/Xcode_27.xip   # the iOS SDK, from Apple's Xcode download (free Apple ID)
x86sim dev new HelloApp               # a SwiftUI app (xtool new), set up for iOS, tvOS, watchOS and visionOS
x86sim dev run HelloApp --phone QA    # build for that device's platform, install and launch: the edit-run loop
x86sim dev test HelloApp              # the same, then check it still runs and take a screenshot
x86sim dev device | ship | ship-mac | convert | auth   # real iPhones, App Store / TestFlight, Xcode projects
```

- **Build** Swift, SwiftUI, Objective-C, C and C++ apps with Swift and xtool, along with Flutter and Kotlin
  Multiplatform, as simulator builds for x86Sim (`ship.sh --simulator`) or device builds for an iPhone. Linux versions
  of `actool`, `ibtool`, `momc` and `xcstringstool` are included, and Xcode projects can be converted.
- **Run on a device**: `device-run.sh` (`x86sim dev device`) pairs an iPhone, installs and launches the app, attaches
  LLDB, streams its console and symbolicates crash reports.
- **Publish**: `ship.sh` (`x86sim dev ship`) builds a release `.ipa`, creates certificates and profiles, signs it and
  uploads it to App Store Connect and TestFlight. `ship-mac.sh` does the same for macOS apps, with Developer ID signing
  and optional notarization.

A free Apple ID is enough to download Xcode for the SDK and to install on your own device; TestFlight and the App Store
need a paid developer account. The toolchain installs into your home directory (`x86sim dev setup` passes the
installer `--user-only` and never runs sudo; when xtool's build needs system packages, `dev status` prints the
command for your distribution). `x86sim repos upstream-sync external/omarchy-apple-dev` merges upstream into the fork.

## How it works

- **[Darling](https://github.com/darlinghq/darling)** provides the macOS-compatible system layer: the Mach-O loader, XNU system
  call and Mach IPC emulation, and one container per device. x86Sim's fork extends it for what the simulator
  runtimes need.
- **[dynarmic](https://github.com/azahar-emu/dynarmic)** translates the runtime's arm64 code to x86-64, just in time
  or ahead of time into a pre-translated image. The lowest system libraries stay native x86-64 code, so system calls
  are not translated.
- **[metal2vulkan](https://github.com/steelbrain/metal2vulkan)** runs Metal on Vulkan. The runtime's own Metal
  implementation talks to a native Linux process, `mtlvk`, with buffers and textures shared rather than copied.
- **Stand-ins for the Mac host.** Everything CoreSimulator and macOS would provide around a runtime is replaced by
  small programs: `simfb` for the display, `simhid` for input, and others for cross-process surfaces, DNS, network
  state and host file services.

[ARCHITECTURE.md](docs/ARCHITECTURE.md) describes each part, [METAL.md](docs/METAL.md) the graphics path, and
[docs/protocols](docs/protocols) the wire formats.

## Building from source

```sh
git clone --recursive https://github.com/x86sim/x86sim.git
cd x86sim
cp x86sim.env.example x86sim.env

make darling-install                             # Darling; asks for sudo (bin/darling is setuid root)
make mtlvk                                       # Metal on Vulkan
linux/arm64jit/install.sh                        # the arm64 translator, installed into Darling
(cd tools/launcher && cargo build --release)     # launcher, x86sim-aot, x86sim-mcp
```

[DEVELOPMENT.md](docs/DEVELOPMENT.md) covers the build dependencies, fetching runtimes, the repository layout and
day-to-day use. The simulator-side binaries are committed, so no Mac is needed to build or run. Release AppImages
are built by `build/release/` and GitHub Actions; see [RELEASE.md](docs/RELEASE.md).

## Status and limitations

x86Sim is young software. The runtimes boot to their home screens, stock and third-party apps run, and the tools
above work. These are the known gaps:

- **Apps** must be arm64 simulator builds. Device builds, such as App Store apps, do not run on a simulator runtime.
- **Maps** shows no map tiles: the map data comes from a Mac and is not part of a release.
- **Audio** is experimental and off by default.
- **Sensors and accessories**: no rotation, shake, accelerometer, Apple Pencil or game controllers.
- **Pairing** an Apple Watch with an iPhone is not supported.
- **Networking**: ordinary DNS and sockets work; Bonjour (multicast DNS) does not.
- **Sandboxing**: simulator processes are not sandboxed.
- **System logging**: `logd` runs for installed apps only; the runtime's own processes do not log. `x86sim log stream`
  covers one app or process at a time.

[WORKAROUNDS.md](docs/WORKAROUNDS.md) lists everything that is approximated and what a faithful version would need.

## License and credits

x86Sim is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE). Bundled components
keep their own licenses; see [NOTICE](NOTICE).

x86Sim builds on:

- [Darling](https://github.com/darlinghq/darling), used through the [x86sim fork](https://github.com/x86sim/darling)
- [dynarmic](https://github.com/azahar-emu/dynarmic), used through the [x86sim fork](https://github.com/x86sim/dynarmic)
- [metal2vulkan](https://github.com/steelbrain/metal2vulkan), used through the [x86sim fork](https://github.com/x86sim/metal2vulkan)
- [ipsw](https://github.com/blacktop/ipsw), [7-Zip](https://www.7-zip.org),
  [dnspython](https://github.com/rthalley/dnspython), astcenc and lzfse

Each fork carries its changes on a branch named `x86sim`.

Apple's simulator runtimes, SDKs and Xcode are not included and are never redistributed. Apple, iPhone, iPad, iOS,
Xcode and Metal are trademarks of Apple Inc. x86Sim is not affiliated with or endorsed by Apple.
