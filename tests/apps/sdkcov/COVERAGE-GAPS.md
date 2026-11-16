# sdkcov coverage gaps: towards complete SDK coverage

Goal: every public framework of each platform SDK (manifest-<plat>.json = the Xcode 27.2 simulator SDK framework list, incl. sdks/XRSimulator-xcode.sdk for visionOS) has functional checks exercising its main public API with real assertions, matching Apple's simulator (the bar, not hardware). Machine-readable: `coverage-gaps.json` (`{platform: {framework: {status, existing_checks, gaps, package, rejudged, used_inside?, apple_sim_na?, apple_sim_na_done?, api_unavailable?, sdk_availability?, note?}}}`).

Refreshed 2026-11-16 (first pass: commit 4dfb0f4, 2026-11-15). Inputs: 729 distinct framework check ids in checks/*.swift (was 381; +348 from P1..P8, the gaps/FSEvents/FoundationModels rounds and More2 on all platforms); which ids run on which platform and their x86Sim + Apple-reference results = every sdkcov result under ~/scratch since 2026-11-15 (results.txt / sdkcov-N.err of the comb2, P-round, gaps, fse, fm and *-ref-* runs: ios 618, tvos 389, watchos 280, xros 500 ids). Every framework whose check set changed was re-judged from the check bodies (`rejudged: true`); the rest keep their first-pass judgement. Libraries (usr/lib) are out of scope.

Status: **covered** = real assertions on the main API and its main areas; **thin** = real checks but main areas untested; **trivial** = only existence / availability / authorization status / construction, or values reported but not asserted; **none** = no check on that platform; **apple-sim-na** = the main API cannot work in Apple's simulator (hardware, entitlement, missing service): the check must assert the simulator answer (*done* when such an asserting check passes on Apple, *open* otherwise); **api-unavailable** = the SDK marks the whole public API unavailable on that platform (Swift `@available(<os>, unavailable)` / `API_UNAVAILABLE(<os>)` on every declaration; visionOS inherits iOS unavailability): only loading is possible, the load check covers it; **excluded** = headers-only / re-export-only / not in the runtime.

Gap tags: **[a]** doable as a check; **[b: ...]** blocked by an x86Sim bug (named); **[c]** Apple's simulator can't do it - assert its answer; **[run]** no new check needed, a run is missing or stale.

## Counts per platform

| platform | frameworks | covered | thin | trivial | none | apple-sim-na (done / open) | api-unavailable | excluded |
|---|---|---|---|---|---|---|---|---|
| iOS/iPadOS | 285 | 187 | 13 | 12 | 0 | 66 (66 / 0) | 0 | 7 |
| tvOS | 167 | 129 | 4 | 2 | 0 | 16 (16 / 0) | 10 | 6 |
| watchOS | 140 | 104 | 6 | 3 | 0 | 13 (13 / 0) | 11 | 3 |
| visionOS | 230 | 164 | 11 | 4 | 0 | 35 (34 / 1) | 9 | 7 |

First pass (2026-11-15) for comparison:

| platform | covered | thin | trivial | none | apple-sim-na | excluded |
|---|---|---|---|---|---|---|
| iOS/iPadOS | 81 | 24 | 47 | 98 | 29 | 6 |
| tvOS | 80 | 22 | 23 | 30 | 6 | 6 |
| watchOS | 46 | 15 | 14 | 52 | 10 | 3 |
| visionOS | 69 | 27 | 35 | 77 | 16 | 6 |

Not counted (Swift runtime modules, not SDK frameworks, all covered): Swift, Dispatch, Observation, Distributed, os.

## Remaining actionable work, by area

Entries = framework [platforms] with status thin / trivial / none / apple-sim-na *open*. Full gap text in the tables below.

### P1 Media & AV

MusicKit NSAppleMusicUsageDescription on watchOS/visionOS + ApplicationMusicPlayer state, MediaPlayer on watchOS (library query after a media-library grant, remote-command config). VideoSubscriberAccount answers asserted (P9). Everything else in P1 is covered.

- **thin**: MediaPlayer [W], MusicKit [WV]
- **trivial**: AssetsLibrary [I]

### P2 Graphics, 3D, AR & games

_GameController_SwiftUI iOS done in P10 (GCVirtualController press reaches GameController); visionOS has no GCVirtualController. GameSave .error state asserted and SceneKit watchOS ported (P9); OpenGLES on visionOS is api-unavailable.

- **trivial**: _GameController_SwiftUI [V]

### P3 App extensions, system services, communication & parental controls

P10 added the extensions (ext/, build.sh): notification content + service, File Provider UI action, App Clip, app migration, translation, Home, accessory transport, device discovery, SMS filter / reporting UI; their Apple answers are asserted (registered; system-UI-only or host-entitlement refusals; no service extension for a simulated push). Left: AlarmKit schedule flow (system prompt), App Clip activation (_XCAppClipURL), AccessoryLiveActivities, BrowserEngineCore BEAudioSession, MetricKit signposts in the log, ExtensionFoundation watchOS on an Apple point, WidgetKit visionOS timelines (needs a placed widget).

- **thin**: AlarmKit [I], AppClip [I], BrowserEngineCore [I], BrowserEngineKit [TV], ExtensionFoundation [W], FileProviderUI [IV], UserNotifications [T], UserNotificationsUI [IV], WidgetKit [V]
- **trivial**: AccessoryLiveActivities [I], BrowserEngineCore [V], ManagedSettingsUI [I], NotificationCenter [I], _DeviceActivity_SwiftUI [I]

### P4 Data, cloud, contacts/calendars & commerce

watchOS Contacts/EventKit answers with access, ATT request flow after a pre-grant/deny. ContactProvider, AdAttributionKit, MarketplaceKit, _SwiftData_SwiftUI done in P9; SharedWithYouCore on tvOS is api-unavailable.

- **thin**: AppTrackingTransparency [ITV], Contacts [W], _MarketplaceKit_UIKit [I]
- **trivial**: AddressBookUI [I], EventKit [W]

### P5 Health, home, location, sensors & accessories

P10: Matter MTRDeviceController offline start/shutdown (all four), SafetyKit exception (objc/SDKCovCatch.m), HomeExtensions / AccessoryTransportExtension / DeviceDiscoveryExtension appex refusals asserted. Left: NearbyInteraction two-peer run (nisimhost) + single-peer answer; DeviceDiscoveryUI with NSApplicationServices; AccessoryNotifications forwarding (data-provider appex); _WorkoutKit_SwiftUI presented on watchOS.

- **thin**: AccessoryNotifications [I], DeviceDiscoveryExtension [V], NearbyInteraction [IW], _WorkoutKit_SwiftUI [W]
- **trivial**: DeviceDiscoveryUI [IT]

### P6 UI frameworks depth & platform UI

Done except _DataDetection_SwiftUI on watchOS (needs the Text on screen and its detected links read back: ImageRenderer draws before detection).

- **trivial**: _DataDetection_SwiftUI [W]

### P7 ML, Apple Intelligence, App Intents/Siri, vision, speech & language

FoundationModels visionOS 1026 refusal asserted when the model is available (not re-verified: Apple model not ready in the P9 runs); x86 bug SensitiveContentAnalysisML 15 on visionOS. _CoreSpotlight_FoundationModels SpotlightSearchTool.call without the model, _FoundationModels_UIKit image segment, _AppIntents_SwiftUI tvOS/watchOS sizes. TranslationUIProvider extension done in P10 (host refused, asserted).

- **thin**: SuggestedActions [IV]
- **trivial**: _AppIntents_SwiftUI [TW], _CoreSpotlight_FoundationModels [IV], _FoundationModels_UIKit [IV]
- **apple-sim-na open**: FoundationModels [V]

### P8 Foundation, networking, security, identity & device management

P10: IdentityLookupUI / IdentityLookup extensions registered (reporting UI system-only), ClassKitUI unassigned-document views asserted. Left: _SecureElementCredential overlays answers, AutomatedDeviceEnrollment presented UI (ref-mac.sh first), _ManagedAppDistribution_SwiftUI label/offer.

- **thin**: AuthenticationServices [T], AutomatedDeviceEnrollment [I], ClassKitUI [IV], IdentityLookupUI [IV], _ManagedAppDistribution_SwiftUI [V]
- **trivial**: Twitter [I], _SecureElementCredential_SwiftUI [I], _SecureElementCredential_UIKit [I]

## Remaining x86Sim-only differences (vs Apple's 27.2 simulator)

Open x86Sim bugs / missing pieces:

- **FileProvider replicated domain** (`FileProvider.replicated-extension-domain`, iOS x86 FAIL "root lists []", Apple PASS on a fresh device; visionOS x86 not run): fileproviderd's `-[FPFSVolume setupForPath:]` needs VOL_CAP_FMT_DOCUMENT_ID | WRITE_GENERATION_COUNT and VOL_CAP_INT_CLONE | RENAME_EXCL from the Darling volume (else ENODEV, domain disabled; patch ~/scratch/fse/darling-volcaps.patch, reverted); with it the next blocker is the missing dataless-materialization upcall (kernel namespace resolver), so the extension is never launched. (The FSEvents half was fixed by the host/fseventsd stand-in.)
- **FoundationModels on visionOS** (relay on): `system-model-availability` FAILs with SensitiveContentAnalysisML error 15 (local sanitizer, OnDeviceInferenceAssetRepository 2); the check now asserts Apple's ModelManagerError 1026 refusal once the model is available.
- **FoundationModels without a Mac**: x86 answers modelNotReady (iOS respond/guided/tools/stream SKIP, Apple PASS via its host Mac) unless X86SIM_FM_RELAY points at a Mac with Apple Intelligence; with the relay the iPad results equal Apple's. Configuration, not a bug.
- **fseventsd stand-in**: kFSEventStreamCreateFlagIgnoreSelf / MarkSelf not implemented (inotify does not say which process made a change), nor hard-link flags or extended data / document ids beyond what the client fills in. `CoreServices.fsevents-stream-file-events` has only an iOS x86 result in the harvested runs (no Apple result, no tvOS/watchOS/visionOS run).
- **BrowserEngineCore JIT witness**: `kevent-jit-restrict` / `bememory-symbols` report "JIT witness supported" 0 on x86 vs 1 on Apple (a CPU feature of the host); not asserted (0 or 1 accepted).
- **VideoSubscriberAccount** (`access-status-user-accounts`, P9 assertion): Apple's VSUserAccountManager update / query fail NSCocoaErrorDomain 4097 (videosubscriptionsd exists and its connection is interrupted); x86 fails 4099 "lookup error 3" (no com.apple.VideoSubscriberAccount.videosubscriptionsd job): x86 FAILs the new assertion until the job is there.
- **MarketplaceKit** (`distributor-requirements`, P9 assertion): x86 answers AppDistributor.current at once ("error Unknown") and eligibilityRegion nil; Apple never answers for a simctl-installed app in 15 s, now asserted: x86 FAILs until it stops answering.
- **PushKit VoIP token**: x86 has no apsd APNs-sandbox courier, so never a token; Apple's fresh devices get none (watchOS, visionOS, one iOS run) or an 80-byte one within 5 s (another iOS run, 2026-11-16): `voip-credentials` accepts both (no token and none cached, or a cached token).

Unasserted value differences (both PASS; decide whether to assert):

- NaturalLanguage `embeddings-assets` iOS/visionOS: x86 has a sentence embedding and contextual-embedding assets true (mobileassetd downloads mBERT after the boot-a64 LinguisticData link); Apple's fresh devices: no sentence embedding, assets false.
- StoreKit `products-storefront` tvOS: x86 storefront none vs Apple USA (x86 run 2026-11-15 15:30, probably before amsaccountsd joined the tvOS job list in the P8 round: rerun).
- _PassKit_SwiftUI `wallet-pay-buttons` iOS: x86 pay button box 0% ink (wallet 65%); Apple's run hung, no comparison yet.

Stale x86 results (the failing run predates the fix or the check change; rerun):

- AppIntents `donations` tvOS: FAIL NSCocoaErrorDomain 4099 (com.apple.linkd.transcript) at 2026-11-15 20:04, before com.apple.linkd joined boot-a64.sh's tvOS list.
- HomeKit `home-manager-add-remove-home` and _RelevanceKit_MapKit `poi-category-contexts` watchOS: FAIL texts belong to older assertions.
- AppTrackingTransparency `status` tvOS: 1 (restricted) vs Apple 0 in the last x86 run; check comment says fixed (ManagedConfiguration profiled).

Runs missing (checks only Apple ran): tvOS 18; watchOS 31; visionOS 16 (tvOS: the P4 data checks; watchOS: P7 + a few P2; visionOS: P3). P9 round (2026-11-16): every new or changed check (p9 entries in coverage-gaps.json) passed on Apple's simulator only; the x86Sim runs are pending (device work paused). P10 round (2026-11-16): the p10 checks passed on Apple (all four) and on x86Sim iOS (App Clip: Apple only); tvOS / watchOS / visionOS x86 runs pending.

Fixed since the first pass (now = Apple): guest signal handlers (`libSystem.B.signals-sigaction-mask-itimer` PASS), MultipeerConnectivity two-peer (iOS/tvOS), NearbyInteraction discovery token (host/nisimhost), visionOS location (managedassetsd), visionOS ARKit addAnchor error text (stub ARKitCore bundle), MetricKit finishExtendedLaunchMeasurement 4 (simshim signpost id), Bonjour on device, TLS-to-loopback race, guest thread stack size. Host config (not x86Sim): ufw on the build host drops inbound multicast, so NWConnectionGroup loopback receive cannot be asserted on x86.

## api-unavailable (whole public API marked unavailable in the SDK)

Evidence from the Xcode 27.2 simulator SDK swiftinterface / headers (scan: ~/scratch/covgap/v2/unav2.py + header reading). Load checks (load:<Framework>) still run.

| framework | platform | SDK evidence |
|---|---|---|
| BrowserEngineCore | tvOS | BEMemory/BEkevent/BEAudioSession all API_UNAVAILABLE(tvos) |
| CoreSpotlight | tvOS | 242/242 Swift decls @available(tvOS, unavailable); every ObjC class API_UNAVAILABLE(tvos, watchos) |
| EnergyKit | tvOS | 255/255 Swift decls @available(tvOS, unavailable) |
| FoundationModels | tvOS | 838/838 Swift decls @available(tvOS, unavailable) |
| MatterSupport | tvOS | 104/104 Swift decls @available(tvOS, unavailable) |
| MetricKit | tvOS | 567/567 Swift decls + all 34 ObjC classes API_UNAVAILABLE(tvos, watchos) |
| SharedWithYouCore | tvOS | every class API_AVAILABLE(ios, macos) only: none imported for tvOS (Swift: cannot find SWCollaborationMetadata) |
| UserNotificationsUI | tvOS | UNNotificationContentExtension and its NSExtensionContext category API_UNAVAILABLE(watchos, tvos) |
| _AppIntents_HealthKit | tvOS | the module imports HealthKit, which the tvOS SDK lacks (not importable); dlopen of the runtime overlay wedges the app in Apple's tvOS simulator |
| _GameController_SwiftUI | tvOS | its 3 Swift decls @available(tvOS, unavailable) |
| BackgroundTasks | watchOS | every BGTaskScheduler / BGTaskRequest declaration API_UNAVAILABLE(watchos) |
| BrowserEngineCore | watchOS | BEMemory/BEkevent/BEAudioSession all API_UNAVAILABLE(watchos) |
| BrowserEngineKit | watchOS | processes @available(watchOS, unavailable); BETextSuggestion / text input / accessibility API_UNAVAILABLE(watchos) |
| BrowserKit | watchOS | BEAvailability, BEBrowserContentFilter, BEBrowserDataExport/ImportManager all API_UNAVAILABLE(watchos) |
| DeviceActivity | watchOS | 55/55 Swift decls @available(watchOS, unavailable) |
| EnergyKit | watchOS | 255/255 Swift decls @available(watchOS, unavailable) |
| FamilyControls | watchOS | 29/29 Swift decls @available(watchOS, unavailable) |
| FinanceKit | watchOS | 211/211 Swift decls @available(watchOS, unavailable) |
| ManagedSettings | watchOS | 166/166 Swift decls @available(watchOS, unavailable) |
| MatterSupport | watchOS | 104/104 Swift decls @available(watchOS, unavailable) |
| UserNotificationsUI | watchOS | UNNotificationContentExtension and its NSExtensionContext category API_UNAVAILABLE(watchos, tvos) |
| AutomaticAssessmentConfiguration | visionOS | all 6 ObjC classes API_UNAVAILABLE(visionos) or (ios) (visionOS inherits iOS), 6/6 Swift decls unavailable |
| BrowserKit | visionOS | both ObjC classes (BEAvailability...) API_UNAVAILABLE(..., visionos) |
| EnergyKit | visionOS | 255/255 Swift decls @available(visionOS, unavailable) |
| LockedCameraCapture | visionOS | 17/17 Swift decls @available(visionOS, unavailable) |
| OpenGLES | visionOS | OPENGLES_DEPRECATED = API_UNAVAILABLE(visionos) on every EAGL / GL declaration |
| TouchController | visionOS | all 17 ObjC classes API_UNAVAILABLE(macCatalyst, visionos) |
| TrustInsights | visionOS | 92/92 Swift decls @available(visionOS, unavailable) |
| WiFiAware | visionOS | 235/235 Swift decls @available(visionOS, unavailable) |
| _Translation_SwiftUI | visionOS | translationPresentation / translationTask @available(visionOS, unavailable) |

Partly available (not api-unavailable; the gap names what is left):

- Translation on tvOS (covered): only AttributeScopes.TranslationAttributes (skipsTranslation) is available; TranslationSession/LanguageAvailability are @available(..., unavailable)
- QuartzCore on watchOS (covered): only CATransform3D functions and CACurrentMediaTime are available (every CA class API_UNAVAILABLE(watchos))
- Translation on watchOS (covered): only AttributeScopes.TranslationAttributes (skipsTranslation) is available; TranslationSession/LanguageAvailability are @available(..., unavailable)
- BrowserEngineCore on visionOS (trivial): only BEMemory (be_memory_inline_jit_restrict_*) is available; be_kevent and BEAudioSession are API_UNAVAILABLE(visionos)
- Translation on visionOS (covered): only AttributeScopes.TranslationAttributes (skipsTranslation) is available; TranslationSession/LanguageAvailability are @available(..., unavailable)
- NetworkExtension on watchOS: NEVPNManager / NERelayManager are API_UNAVAILABLE(watchos); the hotspot API is checked.

Platform letters: I = iOS/iPadOS, T = tvOS, W = watchOS, V = visionOS. A gap prefixed "X:" applies to that platform only.

## No check on the platform (0 frameworks)

Most are ports: the framework is checked on another platform; usually widen the `#if`.

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|

## Trivial checks only (17 frameworks)

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| AccessoryLiveActivities | I | feature-results | [c] Live Activity forwarding to an accessory needs a paired AccessorySetupKit accessory: assert the simulator answer of the forwarding authorization request | P3 |
| AddressBookUI | I | people-picker-view | [a] deprecated: keep | P4 |
| AssetsLibrary | I | authorization-status | [a] deprecated (unavailable to Swift): keep runtime authorizationStatus call | P1 |
| BrowserEngineCore | V | bememory-symbols | [c] BEMemory is C-only inline asm (__SWIFT_UNAVAILABLE): from Swift only the exported _impl / _supported symbols; be_kevent / BEAudioSession are unavailable on visionOS | P3 |
| DeviceDiscoveryUI | IT | device-picker, device-picker-ios | [a] add NSApplicationServices to Info.plist so DDDevicePickerViewController's view loads; assert isSupported (Apple: iOS true, tvOS false) and the picker view on screen (today values reported only) | P5 |
| EventKit | W | authorization-event-recurrence, watch-read-access | [a] assert calendars/events(matching:) answers with access (watch-read-access reports counts only) | P4 |
| ManagedSettingsUI | I | shield-configuration | [c] shield rendering needs a ShieldConfiguration extension + Family Controls authorization: assert the simulator answer | P3 |
| NotificationCenter | I | widget-controller | [a] deprecated (Today widgets): NCWidgetProviding - keep minimal | P3 |
| Twitter | I | compose-can-send | [a] deprecated (no Swift module): keep runtime call | P8 |
| _AppIntents_SwiftUI | TW | siri-tip-view, siri-tip-view-shortcuts-link | T: [a] assert siri-tip-view hosted size/subviews (only reported); W: [a] render SiriTipView (e.g. ImageRenderer) and assert size (only built) | P7 |
| _CoreSpotlight_FoundationModels | IV | spotlight-search-tool | [a] SpotlightSearchTool.call(arguments:) directly over an indexed CSSearchableItem (no model needed); session use needs the model (x86: FM relay) | P7 |
| _DataDetection_SwiftUI | W | text-data-detection | [a] host the Text on screen and assert detected links (ImageRenderer draws before async detection; check only asserts ink) | P6 |
| _DeviceActivity_SwiftUI | I | report-view-hosted | [c] report content needs a DeviceActivityReport extension + authorization: assert the simulator answer | P3 |
| _FoundationModels_UIKit | IV | uiimage-attachment-prompt | [a] assert the Prompt carries an image segment; respond(to:) with it where the model is available (x86 iOS: FM relay) | P7 |
| _GameController_SwiftUI | V | handles-game-controller-events-modifier | [c] GCVirtualController is API_UNAVAILABLE(visionos): no injectable gamepad | P2 |
| _SecureElementCredential_SwiftUI | I | transaction-task-modifier | [c] transactionTask with a real configuration needs a credential session (assert the simulator answer) | P8 |
| _SecureElementCredential_UIKit | I | window-scene-events | [c] scene connection-options credential events need an NFC presentment (assert the simulator answer) | P8 |

## Thin coverage of main areas (24 frameworks)

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| AccessoryNotifications | I | notification-model-codable | [a] NotificationsForwarding provider / forwarding session in an accessory extension (needs appex) | P5 |
| AlarmKit | I | authorization-alarms-updates, manager-state | [a] AlarmManager.requestAuthorization + schedule a countdown alarm / cancel (NSAlarmKitUsageDescription; system prompt needs auto-accept) | P3 |
| AppClip | I | activation-payload, clip-installed-with-parent | [a] launch the clip with _XCAppClipURL (host-driven, as Xcode) and call APActivationPayload.confirmAcquired(in:) | P3 |
| AppTrackingTransparency | ITV | not-determined-on-fresh-install, status | [a] requestTrackingAuthorization with a pre-granted / denied tracking privacy -> status authorized/denied; T: [a] x86 run of not-determined-on-fresh-install (last x86 tvOS status check said 1 = restricted, Apple 0) | P4 |
| AuthenticationServices | T | apple-id-request, passkey-requests-controller, web-auth-loopback-port | [a] ASAuthorizationProviderExtension / ASCredentialProviderViewController objects (AutoFill/SSO extension side) | P8 |
| AutomatedDeviceEnrollment | I | addition-modifier | [a] isPresented true on an unmanaged device: assert the system UI or refusal Apple shows (ref-mac.sh first) | P8 |
| BrowserEngineCore | I | kevent-jit-restrict | [c] JIT witness supported is a CPU feature (1 Apple silicon, 0 on x86): not assertable across hosts; [a] BEAudioSession (iOS 26) on an AVAudioSession | P3 |
| BrowserEngineKit | TV | scroll-view-text-objects | [a] BETextInput delegate / BEKeyEntry behaviour (process launches are iOS-only API: @available(tvOS/visionOS, unavailable)) | P3 |
| ClassKitUI | IV | assigned-document-views, unassigned-document-views | [c] an assigned document needs a Schoolwork class (none in the simulator): only the unassigned views | P8 |
| Contacts | W | authorization-vcard-formatter, watch-read-access | [a] assert fetch answers with access granted (watch-read-access reports counts only) | P4 |
| DeviceDiscoveryExtension | V | device-event-types | [a] DDDiscoverySession inside a DeviceDiscoveryExtension appex (appex installs only on iOS) | P5 |
| ExtensionFoundation | W | apple-extension-point-monitor | [a] monitor an Apple extension point with an app extension (today only the unknown-point error) | P3 |
| FileProviderUI | IV | action-extension-controller, action-extension-registered | [c] the action extension runs only from the Files app's action menu (system UI) | P3 |
| IdentityLookupUI | IV | classification-extension-registered, classification-view-controller | [c] the reporting UI runs only from Messages / Phone's report-junk flow (system UI) | P8 |
| MediaPlayer | W | nowplaying-remote-commands | [a] MPMediaQuery on an authorized library (auth 0 on the sim: grant media-library TCC so songs/albums queries run); [a] port remote command config (skip intervals, changePlaybackPosition) / MPNowPlayingSession | P1 |
| MusicKit | WV | authorization-status, objects-subscription-catalog-answers | [a] add NSAppleMusicUsageDescription so subscription/catalog calls assert the simulator error (today not made); [a] ApplicationMusicPlayer queue/state asserted (today reported only) | P1 |
| NearbyInteraction | IW | capabilities, unsupported-session-invalidated | [a] two-peer NISession run (Apple sim simulates distance between simulator windows; x86 via nisimhost): assert didUpdate nearby objects; I: [a] assert the single-peer run answer (invalidation / no update) instead of reporting it | P5 |
| SuggestedActions | IV | message, message-view-generate, message-view-generate-port | I: [a] assert generate result / rendered SuggestedActionsView content (subviews not asserted); V: [a] assert the rendered SuggestedActionsView content (subviews not asserted) | P7 |
| UserNotifications | T | settings-schedule-pending, tv-badge-request-model | [a] communication notifications (INSendMessageIntent update); [c] badge delivery needs authorization whose alert never dismisses unattended (add refusal asserted) | P3 |
| UserNotificationsUI | IV | content-extension-controller, content-extension-registered | [c] the content extension runs only when the user expands a notification of its category (system UI, not unattended) | P3 |
| WidgetKit | V | center, widget-extension-descriptors, widget-views-render-xros | [a] timelines reach currentConfigurations (0 configured today): assert a kind; [c] ControlCenter is unavailable on visionOS | P3 |
| _ManagedAppDistribution_SwiftUI | V | managed-content-view | [a] assert ManagedContentView label text / offerAction on tap (check asserts only offer states and laid-out height) | P8 |
| _MarketplaceKit_UIKit | I | install-metadata-display-options | [c] ActionButton init blocks the main thread on Apple outside a marketplace app | P4 |
| _WorkoutKit_SwiftUI | W | workout-preview-modifier-watch | [a] present the preview (isPresented true) and assert it shows | P5 |

## Apple-sim N/A, open (no asserting check yet) (1 frameworks)

Not to be chased beyond asserting the simulator answer.

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| FoundationModels | V | private-cloud-compute-model, schemas-content-transcript, system-model-availability, system-model-respond-guided-tools-stream | [b: SensitiveContentAnalysisML error 15] with X86SIM_FM_RELAY, system-model-availability FAILs with SensitiveContentAnalysisML 15 (local sanitizer, OnDeviceInferenceAssetRepository 2) where Apple FAILs with ModelManagerError 1026; [c] system-model-availability asserts the ModelManagerError 1026 refusal once the model is available; in the 2026-11-16 Apple runs the model stayed modelNotReady > 30 s (host Mac state), so the check SKIPped there and the refusal is not re-verified (Apple's visionOS/watchOS simulators refuse generation (ModelManagerError 1026)) | P7 |

## Apple-sim N/A, done (asserting check passes on Apple) (74 frameworks)

Remaining gaps here are optional depth.

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| ARKit | I | configurations, simulator-unsupported-answers | done (iOS: no ARKit tracking in Apple's simulator; visionOS sim supports only WorldTrackingProvider) | P2 |
| AccessorySetupKit | I | descriptors-display-items, session-activate | done (ASAccessorySession never activates in Apple's simulator (and traps without NSAccessorySetupKitSupports)) | P5 |
| AccessoryTransportExtension | I | extension-registered, message-builder | done (only Apple's host (private entitlement) runs a com.apple.accessory-transport-extension extension: the app's monitor is refused (extensionKit 16)) | P5 |
| AdAttributionKit | I | impression-postback-answers | done (AdAttributionKit is unsupported in the simulator (every call NSCocoaErrorDomain 3328)) | P4 |
| AdServices | IV | attribution-token, attribution-token-sim-error | done (attributionToken errors in the simulator) | P4 |
| AppMigrationKit | I | extension-tester, status-identifiers | done (AppMigrationTester cannot start the app's migration extension from the app: exportController throws extensionKit 2 / RBSServiceErrorDomain 1) | P3 |
| BackgroundAssets | IV | asset-pack-manager, asset-pack-status-download | [a] BADownloaderExtension: a scheduled BADownload running in the downloader extension (extension registered, seen by ExtensionFoundation monitor on tvOS/visionOS); I: [a] bundle the downloader extension on iOS too; V: [run] x86 result missing (only ref ran) (managed asset packs need App Store hosting: AssetPackManager answers each call with an error (asserted by asset-pack-status-download)) | P3 |
| BackgroundTasks | ITV | continued-processing-request, register-submit | done (BGTaskScheduler.submit -> .unavailable in Apple's simulator (asserted by register-submit)) | P3 |
| BrowserEngineKit | I | processes-without-entitlement | [a] BETextInput / BEScrollView behaviour (only a BEScrollView built) (browser process launches need the web-browser-engine entitlement + extensions) | P3 |
| BrowserKit | I | content-filter-import-answers, data-exchange-types | [c] BEAvailability.isEligible(for:) raises NSInvalidArgumentException in Apple's sim (XPC proxy lacks the selector): not assertable (BEAvailability.isEligible raises in Apple's simulator) | P3 |
| CallKit | WV | incoming-outgoing-calls, provider-observer | [a] CXCallDirectoryManager status (needs a call directory extension); [run] rerun incoming-outgoing-calls on ref (FAIL predates the error assertion; detail matches the asserted errors); V: [run] x86 result missing (Apple's watchOS/visionOS simulators: callservicesd refuses incoming (CallKit.error 0) and transactions (requesttransaction 1)) | P3 |
| CarKey | IW | remote-control-start-refused | done (needs Wallet car keys (NFC/UWB) and Apple's entitlement) | P5 |
| ContactProvider | I | manager-without-extension | done (needs a contact provider extension) | P4 |
| CoreBluetooth | ITWV | central-state, managers-unsupported-objects | done (no Bluetooth radio in the simulator) | P5 |
| CoreMotion | IWV | availability, unavailable-sensors-queries | done (no motion sensors in the simulator) | P5 |
| CoreNFC | I | reading-available, unavailable-ndef-model | done (no NFC in the simulator) | P5 |
| CoreTelephony | I | network-info, no-radio-answers | done (no cellular radios in the simulator) | P5 |
| DeclaredAgeRange | I | eligibility, request-age-range | done (isEligibleForAgeFeatures / requestAgeRange never answer in Apple's simulator) | P3 |
| DeviceActivity | I | center-activities, start-monitoring-schedule | done (startMonitoring needs Family Controls authorization (entitlement; no FamilyControlsAgent in the sim)) | P3 |
| DeviceCheck | ITWV | support, unsupported-errors | done (DCDevice / App Attest unsupported in Apple's simulator) | P8 |
| DeviceDiscoveryExtension | I | device-event-types, extension-registered | done (only Apple's host (private entitlement) runs a com.apple.discovery-extension extension: the app's monitor is refused (extensionKit 16)) | P5 |
| EnergyKit | I | venues-guidance-answers | done (no energy venues service in the simulator) | P5 |
| ExposureNotification | I | authorization-status, manager-activate-answer | done (needs Apple's Exposure Notification entitlement (deprecated)) | P5 |
| ExtensionKit | TWV | app-defined-point-refused | done (tvOS/watchOS/visionOS installd refuse an app extension on a non-Apple extension point (Apple's simulator too)) | P3 |
| ExternalAccessory | ITV | manager, no-accessories-wifi-browser | done (no MFi accessories) | P5 |
| FamilyControls | I | authorization-selection, authorization-status | [a] FamilyActivityPicker render (requestAuthorization(for: .individual) -> NSCocoaErrorDomain 4099 (no FamilyControlsAgent in Apple's simulator)) | P3 |
| FinanceKit | I | availability-authorization | done (FinanceStore authorization/queries trap without the Apple-granted FinanceKit entitlement) | P4 |
| FoundationModels | W | private-cloud-compute-model, schemas-content-transcript, watch-pcc-session-refused | done (no on-device model on watchOS; Private Cloud Compute: deviceNotEligible in the sim) | P7 |
| GameKit | ITWV | local-player-leaderboard-objects, unauthenticated-player-leaderboards-matchmaking | [a] GKTurnBasedMatch.loadMatches / GKLeaderboard.loadEntries error paths without an account (Game Center server features need a signed-in sandbox account (Apple sim: same)) | P2 |
| GameSave | IV | synced-directory-without-icloud | done (GameSaveSyncedDirectory needs an iCloud account) | P2 |
| GroupActivities | ITV | activity-metadata-prepare, activity-sessions, no-call-activation-coding, observer | [c] GroupSessionMessenger / GroupSessionJournal need a session (FaceTime call): only the no-session answer is assertable (SharePlay sessions need FaceTime) | P4 |
| HomeExtensions | I | extension-registered, settings-model | done (only Apple's host (private entitlement) runs a com.apple.Home.HomeExtension extension: the app's monitor is refused (extensionKit 16)) | P5 |
| IdentityDocumentServices | I | registration-store-requests | done (mobile ID documents need Wallet IDs (not in the simulator)) | P8 |
| IdentityDocumentServicesUI | I | web-presentment-controller | done (web presentment needs the identity-document entitlement and Wallet IDs) | P8 |
| ImageCaptureCore | IV | browser-no-devices, device-browser | done (no cameras/scanners attached) | P5 |
| ImagePlayground | IV | availability, image-creator-unavailable | done (needs Apple Intelligence image models) | P7 |
| LinkSecurity | ITWV | flag-urls, flag-urls-port | done (flagged-URL store lives in imagent, absent from simulator runtimes) | P3 |
| LockedCameraCapture | I | manager-simulator-answers | done (camera capture extension (no cameras in the simulator)) | P1 |
| ManagedAppDistribution | IV | libraries-unmanaged-device | done (ManagedAppLibrary answers unsupportedPlatform in Apple's simulator) | P8 |
| ManagedSettings | IT | store-read-write, store-write-read-clear, tv-default-store-effective | done (store writes need Family Controls authorization (unavailable in the sim)) | P3 |
| MarketplaceKit | I | distributor-requirements | [b: AppDistributor answers] x86 answers AppDistributor.current at once ("error Unknown") / eligibilityRegion nil; Apple never answers (now asserted) (marketplace install APIs need an EU marketplace install; AppLibrary/satisfiedByDevice block on Apple) | P4 |
| MatterSupport | IV | add-device-request-answer | done (system Matter setup flow not available in the simulator) | P5 |
| MediaIntelligence | ITV | face-group-analyzer | [c] FaceGroupAnalyzer ingest: Vision face networks fail in Apple sim and the framework double-resumes a continuation (abort) - unassertable; only the empty store lifecycle is checkable (face ingest needs Vision espresso inference contexts (absent in Apple sim, aborts)) | P7 |
| MessageUI | IV | can-send, simulator-answers-composers | [a] MFMailComposeViewController/MFMessageComposeViewController init + present while canSend* is false (no Mail account / Messages in the simulator) | P6 |
| MetalPerformancePrimitives | ITV | tensor-matmul-shader | done (the simulator Metal compiler has no MetalPerformancePrimitives header) | P2 |
| MetalPerformanceShadersGraph | IV | build-compile-no-device, graph-run | done (MPSGraphDevice init aborts in Apple's simulator too) | P2 |
| MetricKit | IV | log-handles-signposts-launch-task, manager | [a] assert signposts reach the log (mxSignpost / MetricManager.logHandle emitted, not checked) (no MetricKit payloads in the simulator (pastPayloads / diagnostics empty)) | P3 |
| MultipeerConnectivity | V | session, two-peer-data-stream-resource | done (Apple's visionOS simulator: the browser finds no peer in 30 s on some runs, connects on others) | P8 |
| MusicKit | IT | authorization-status, objects-subscription-catalog-answers | [a] ApplicationMusicPlayer queue/state asserted (today reported only) (catalog/subscription need a MusicKit-enabled team-signed app + Apple Music account) | P1 |
| ProximityReader | I | reader-support, readers-answers | done (Tap to Pay needs NFC hardware + entitlement) | P5 |
| PushKit | IWV | registry, voip-credentials | [a] pushType .fileProvider (no VoIP token on a fresh simulator device (apsd not connected to APNs sandbox)) | P3 |
| PushToTalk | I | channel-manager | done (Push-to-Talk API not available in the simulator (com.apple.pushtotalk.instantiation 1)) | P3 |
| ReplayKit | ITV | capture-answer-picker, recorder | [a] startRecording/stopRecording -> RPPreviewViewController (or the simulator error); I: [a] RPBroadcastActivityViewController.load (assert simulator answer) (no screen-capture sample buffers in the simulator (startCapture starts, 0 buffers in 5 s)) | P1 |
| RoomPlan | I | unsupported-model | done (needs LiDAR) | P5 |
| SafetyKit | IW | crash-detection, entitlement-gated, exception-without-entitlement | done (Apple-only entitlement) | P5 |
| SecureElementCredential | I | session-eligibility | done (needs a Secure Element (NFC)) | P8 |
| SensitiveContentAnalysis | IV | analyze-image-policy, policy, video-analysis-disabled-policy | done (needs the client entitlement and user setting (policy disabled)) | P7 |
| SensorKit | I | authorization-request-answer, reader-authorization | done (research entitlement + sensors) | P5 |
| Speech | ITV | recognize-synthesized-file, recognizer-availability, speech-analyzer-transcribe-file, speech-transcriber-assets | [a] SFSpeechAudioBufferRecognitionRequest (buffer path) asserting the same kLSRErrorDomain 300; [a] speech-analyzer-transcribe-file: assert AssetInventory status unsupported (not-installed path currently asserts nothing) (no on-device ASR / SpeechTranscriber assets in Apple's simulator (kLSRErrorDomain 300, assets unsupported)) | P7 |
| SystemExtensions | I | workspace | done (DriverKit system extensions cannot be activated in the simulator) | P3 |
| TelephonyMessagingKit | I | handles-content-codable, session-without-carrier | done (needs a carrier SIM / telephony) | P3 |
| TouchController | I | layout-render-touch, simulator-unsupported-descriptor | done (TCTouchController.isSupported is false in Apple's simulator) | P2 |
| TranslationUIProvider | I | extension-registered | done (the translation UI host entitlement is Apple-private: the app's AppExtensionPoint.Monitor is refused (extensionKit 16); only the system Translate menu runs the extension) | P7 |
| TrustInsights | I | evaluator-authorization | done (InsightEvaluator answers notAvailable in Apple's simulator) | P8 |
| VideoSubscriberAccount | ITV | access-status-user-accounts, manager | done (no TV-provider service in the simulator (checkAccessStatus -5, user account update 4099)) | P1 |
| VisionKit | V | analyzer-scanner-support, image-analyzer-live-text | done (Apple's visionOS simulator analyzes but reads no text; no camera scanners) | P7 |
| WatchConnectivity | IWV | session-activate | I: [a] assert WCSession.isSupported() == false (today SKIP); W: [a] watch-only app gets no session state; a companion-app setup would be needed for transfer APIs; V: [a] assert WCSession.isSupported() == false (today SKIP) (no paired device (iOS/visionOS); watch-only app on watchOS) | P3 |
| WeatherKit | ITWV | service-answer, service-answers | done (needs a team-signed WeatherKit entitlement; auth service absent in sim runtimes) | P5 |
| WiFiAware | I | unsupported-capabilities | done (no Wi-Fi Aware radio) | P5 |
| _AVKit_GroupActivities | V | playback-coordinator-no-session | done (needs a SharePlay session (FaceTime)) | P1 |
| _AdAttributionKit_StoreKit | I | overlay-configuration-impression | done (AdAttributionKit unsupported in the simulator) | P4 |
| _CoreHaptics_AudioToolbox | V | intended-spatial-experience | done (no haptics engine in the visionOS simulator (CHHapticEngine -4815)) | P1 |
| _TabletopKit_GroupActivities | V | coordinate-with-session-symbol | done (SharePlay needs a FaceTime call) | P2 |
| iAd | I | client-attribution-obsolete | done (iAd obsoleted: ADClient.sharedClient nil) | P4 |

## Excluded (listed, not chased)

| framework | platforms | why |
|---|---|---|
| AudioUnit | ITV | headers only (no binary): the AU API lives in AudioToolbox - covered there |
| CoreAudioTypes | ITWV | headers only: types used by AudioToolbox/AVFAudio checks (AudioStreamBasicDescription, AudioBufferList) |
| _FoundationModels_SwiftUI | IV | not in the simulator runtimes (load SKIP) |
| _GroupActivities_UIKit | T | GroupActivitySharingController (activity + lazy) builds; visionOS association interaction attached; tvOS re-export only. |
| _Intents_TipKit | ITWV | re-export only (no public declarations) |
| _LocationEssentials | ITWV | C types/functions re-exported by CoreLocation (CLLocationCoordinate2D...): used by CoreLocation/MapKit checks |
| _PhotosUI_WidgetKit | IV | swiftinterface has no public declarations (imports PhotosUI / _PhotosUI_SwiftUI only) |
| _SharedWithYou_AppIntents | ITV | re-export only (no public declarations) |

## Covered, with secondary gaps

| framework | platforms | secondary gaps |
|---|---|---|
| ARKit | V | [c] assert the simulator provider answers (world true; planes/scene/hands/images/room false) in data-providers (today reported, not asserted); [c] assert WorldTrackingProvider.addAnchor -> addWorldAnchorFailed (both simulators; today reported, not asserted) |
| AVFAudio | ITWV | [a] AVAudioRecorder / AVAudioEngine.inputNode capture (sim mic input): assert record + file length; [a] AVAudioSession interruption / route-change notifications, setPreferredSampleRate / setPreferredIOBufferDuration; [a] AVAudioSinkNode in a manual-render engine; W: [a] port source-node-time-pitch-offline / sequencer-sampler-offline where the units exist on watchOS |
| AVFoundation | ITWV | [a] AVContentKeySession (clear key) / AVAssetDownloadURLSession offline HLS; [a] chapter metadata: timed-metadata-chapters reports chapters (empty) - assert chapterMetadataGroups from a chaptered m4a/mov; [a] AVPlayerItem failed/stall notifications (AVPlayerItemPlaybackStalled, failedToPlayToEndTime); [a] AVAssetExportSession fileLengthLimit / metadata write-through on export |
| AVKit | ITWV | I: [a] AVPlayerViewControllerDelegate full-screen enter/exit transitions; T: [a] AVPlayerViewControllerDelegate full-screen enter/exit transitions; T: [a] AVPictureInPictureController.isPictureInPictureSupported + sample-buffer content source (iOS/visionOS check only); V: [a] AVPlayerViewControllerDelegate full-screen enter/exit transitions |
| AVRouting | ITV | I: [a] DeviceDiscoveryExtension appex to drive AVCustomRoutingController route events (today asserts empty routes + no delegate events); V: [a] DeviceDiscoveryExtension appex to drive AVCustomRoutingController route events (today asserts empty routes + no delegate events) |
| Accelerate | ITWV | [a] BNNS Graph compile/execute, LAPACK solve |
| Accessibility | ITWV | [a] AccessibilityNotification.Announcement post, AXBrailleMap, AXSettings queries |
| ActivityKit | I | [a] pushType .token: pushTokenUpdates answer (token or none in the sim: assert) |
| AdSupport | IT | [c] non-zero IDFA needs tracking authorized (ATT prompt answer) |
| AppIntents | ITWV | [a] ControlWidget toggles / SetValueIntent (with WidgetKit); [a] AppShortcut phrases/titles asserted (app-shortcuts-provider only checks the count); T: [run] donations: x86 FAIL 4099 (2026-11-15 20:04) predates the com.apple.linkd job in boot-a64.sh's tvOS list: rerun |
| AudioToolbox | ITV | [a] AudioQueue input (record) on the sim mic; [a] AudioComponentInstanceNew RemoteIO with a realtime render callback |
| AuthenticationServices | IWV | I: [c] ASAuthorizationController.performRequests with a passkey request: Apple's iPad sim shows its passkey sheet and the app hangs (assert the sheet without blocking); [a] ASAuthorizationProviderExtension / ASCredentialProviderViewController objects (AutoFill/SSO extension side) |
| BackgroundAssets | T | [a] BADownloaderExtension: a scheduled BADownload running in the downloader extension (extension registered, seen by ExtensionFoundation monitor on tvOS/visionOS) |
| BusinessChat | I | [a] BCChatAction.openTranscript URL (deprecated) |
| CFNetwork | ITWV | [a] HTTP/2 to loopback TLS (results show http/1.1 negotiated); [a] URLSessionConfiguration.connectionProxyDictionary through a loopback proxy; W: [a] CFHTTPMessage (stream-task check skips it there; verify SDK availability) |
| CallKit | I | [a] CXCallDirectoryManager status (needs a call directory extension) |
| CarPlay | I | [a] CPTemplateApplicationScene in CarPlay simulator window (Apple sim has I/O > External Displays > CarPlay) |
| Charts | ITWV | [a] chart selection/scroll APIs (chartXSelection, chartScrollableAxes, chartScrollPosition); [a] LineMark/AreaMark/RuleMark positions by pixels, axis labels; V: [a] Chart3D |
| ClockKit | IW | W: [a] CLKComplicationDataSource timeline (reloadTimeline/extendTimeline) - complication-server only reports a count |
| CloudKit | ITWV | [c] server ops (fetch/query/subscription/share accept) need team signing + account: only save -> CKError 8 asserted; [c] assert accountStatus answer instead of SKIP in account-status |
| CompositorServices | V | [a] LayerRenderer drawable depth/stereo views, foveation config (visionOS) |
| ComputeGraph | ITV | [a] assert the ComputeNodeGraph.Assembly result (uniform buffer size / uniforms) and evaluate an assembled graph |
| Contacts | IV | [a] limited-access (iOS 18) authorization behaviour |
| ContactsUI | IV | [a] CNContactViewController(forNewContact:) edit + delegate |
| CoreAudio | ITWV | [a] property listener actually firing on a default-device / sample-rate change |
| CoreAudioKit | IV | [a] CABTMIDILocalPeripheralViewController / CAInterAppAudio views: Apple-sim N/A (no BT), assert view loads |
| CoreData | ITWV | T: [a] x86 run of the P4 CoreData checks (ref only so far) |
| CoreGraphics | ITWV | [a] CGPDFDocument parsing/scanning (CGPDFScanner), CGImageSource-less JPEG via CGDataProvider, shading/patterns |
| CoreHaptics | ITV | [a] engine: Apple-sim N/A (pattern API covered); AHAP file parse |
| CoreImage | ITV | [a] CIRAWFilter / CIImage from HEIF/RAW, CIImageProcessorKernel, custom CIKernel (Metal) at runtime; [a] CIDetector face/text (Vision-backed: verify on Apple sim) |
| CoreLocation | ITWV | I: [c] CLMonitor events: Apple's simulator delivers none for a simulated location (reported, not asserted); I: [a] startUpdatingLocation stream / significant-change / CLVisit monitoring start-stop; I: [a] beacon ranging (CLBeaconIdentityConstraint) -> no beacons |
| CoreLocationUI | IW | [a] LocationButton tap -> one-time authorization (input) |
| CoreMIDI | ITWV | I: [c] virtual-loopback SKIPs - assert the simulator answer of MIDISourceCreate/MIDIDestinationCreate (error code) instead of skipping; I: [c] MIDICIDiscoveryManager.discover gives no answer in 8 s (reported, not asserted) - assert the simulator answer; V: [c] virtual-loopback SKIPs - assert the simulator answer of MIDISourceCreate/MIDIDestinationCreate (error code) instead of skipping; V: [c] MIDICIDiscoveryManager.discover gives no answer in 8 s (reported, not asserted) - assert the simulator answer |
| CoreML | ITWV | [a] MLState stateful models (makeState, prediction(from:using:)); W: [a] port model-asset-batch-async-compute-plan without the compile step (MLModelAsset(specification:), batch/async) |
| CoreServices | ITWV | I: [a] get a ref-mac.sh result for fsevents-stream-file-events (no Apple result in the table); [b: fseventsd stand-in lacks IgnoreSelf/MarkSelf] FSEvents IgnoreSelf / MarkSelf flags; T: [a] run fsevents-stream-file-events (only an iOS x86 result exists); W: [a] run fsevents-stream-file-events (only an iOS x86 result exists); V: [a] run fsevents-stream-file-events (only an iOS x86 result exists) |
| CoreSpotlight | IV | [a] CSUserQuery: assert responses / error (user-query reports only) |
| CoreTransferable | ITWV | [a] FileRepresentation / DataRepresentation import/export |
| CreateMLComponents | ITWV | [a] estimator/transformer pipeline composition (appending) + write/read of a fitted pipeline |
| CryptoTokenKit | ITWV | [a] TKTokenKeychainContents (needs a token extension) |
| EventKitUI | IV | [a] EKEventEditViewController save/cancel through editViewDelegate |
| ExtensionFoundation | ITV | V: [run] x86 result missing |
| FileProvider | IV | I: [b: fileproviderd volume caps DOCUMENT_ID/WRITE_GENERATION_COUNT/CLONE/RENAME_EXCL + dataless materialization upcall] replicated-extension-domain enumerate/materialize/create; [a] NSFileProviderManager evictItem / import / pending items; V: [run] x86 result missing |
| Foundation | ITWV | T: [a] user-activity saved-activity deletion (check skips it on tvOS) |
| FoundationModels | I | [b: config] respond/guided/tools/stream need X86SIM_FM_RELAY (a Mac with Apple Intelligence); without it x86 answers modelNotReady where Apple's sim (host Mac) PASSes; with the relay iPad = Apple |
| GLKit | IT | [a] GLKView/GLKBaseEffect draw (iOS/tvOS) |
| GSS | IV | [a] Kerberos auth needs a KDC (not available) |
| GameController | ITV | [a] input-gamepad: await a real button press (SDKCOV_INPUT_WAIT, run.sh input mode); [a] GCKeyboard / GCMouse input handlers (controllers-keyboard-mouse only reports counts) |
| GameplayKit | ITV | [a] GKObstacleGraph pathfinding around polygon obstacles, GKScene loaded from an .sks file |
| HealthKit | IWV | [a] authorized round trip: grant Health access (run.sh / ref-mac.sh) so save/query/statistics/delete run authorized (only the refusal path HK 4/5 is asserted today); I: [c] clinical records / HKMedication: assert supportsHealthRecords() == false (reported today) |
| HealthKitUI | IWV | W: [a] trigger change -> healthDataAccessRequest result (needs the Health sheet answered unattended) |
| HomeKit | ITWV | [c] HMHome rooms/accessories/action sets: Apple's simulator refuses addHome (HMErrorDomain 2040 / no answer); [a] HMEventTrigger / HMSignificantTimeEvent / HMCalendarEvent construction and predicates (no home needed) |
| IOSurface | ITV | [a] IOSurface sharing to Metal texture + CVPixelBuffer (partly via CoreVideo check) |
| ImmersiveMediaSupport | IV | [a] ImmersiveMediaRemotePreviewSender / VenueDescriptor |
| Intents | ITWV | [a] in-app intent handling (application(_:handlerFor:) / INExtension) for INSendMessageIntent; I: [a] INFocusStatusCenter: assert authorization status / requestAuthorization answer (check only reports); [a] assert INInteraction delete answers (tvOS: 1900 on both); W: [a] INFocusStatusCenter: assert authorization status / requestAuthorization answer (check only reports); V: [a] INFocusStatusCenter: assert authorization status / requestAuthorization answer (check only reports) |
| IntentsUI | ITV | I: [a] INUIAddVoiceShortcutViewController / INUIEditVoiceShortcutViewController presentation |
| JavaScriptCore | ITV | [a] JSExport ObjC class bridging, JSVirtualMachine across contexts |
| LinkPresentation | ITWV | [a] LPMetadataProvider remote video / iconProvider vs imageProvider split, cancel() |
| LiveCommunicationKit | IWV | [a] ConversationManager.reportNewIncomingConversation + actions |
| LocalAuthentication | ITWV | I: [a] evaluatePolicy with simulated enrolled biometry (input-biometric needs run.sh input mode); V: [a] evaluatePolicy with simulated enrolled biometry (input-biometric needs run.sh input mode) |
| LocalAuthenticationEmbeddedUI | IV | [a] LAAuthenticationView(context:) render bound to an LAContext |
| MapKit | ITWV | I: [a] MKMapView annotation views on screen (MKMarkerAnnotationView pixels); [a] MKMapItemRequest (place ID) / MKMapItem identifiers; T: [a] MKMapView annotation views on screen (MKMarkerAnnotationView pixels); V: [a] MKMapView annotation views on screen (MKMarkerAnnotationView pixels) |
| MediaAccessibility | ITV | [a] caption appearance settings-changed notification |
| MediaPlayer | ITV | [a] MPMediaQuery on an authorized library (auth 0 on the sim: grant media-library TCC so songs/albums queries run); V: [a] add NSAppleMusicUsageDescription so the queue player / library path runs (today skipped) |
| MediaToolbox | ITV | [a] MTAudioProcessingTap is the main API - fine; MTRegisterProfessionalVideoWorkflowFormatReaders |
| Messages | I | [a] MSMessagesAppViewController (needs iMessage extension) |
| Metal | ITV | [a] MTLParallelRenderCommandEncoder, stencil test, texture views / swizzle, MTLFence across encoders |
| MetalKit | ITV | [a] MTKMesh from MDLAsset with custom vertex descriptor; T: [a] port mtkview-draw-loop-on-screen (iOS-only); V: [a] port mtkview-draw-loop-on-screen (iOS-only) |
| MetalPerformanceShaders | ITV | [a] MPSImageConversion / threshold / median, MPSMatrixDecompositionCholesky / LU solve |
| ModelIO | ITV | [a] MDLMaterial / MDLScatteringFunction, MDLLight light probes, ambient occlusion baking |
| MusicUnderstanding | ITWV | [a] assert rhythm beat count / bpm ~120 (reported only; loudness is asserted) |
| NaturalLanguage | ITWV | [a] NLModel from a compiled text classifier (MLModel) via NLModel(contentsOf:) |
| Network | ITWV | [b: build-host ufw drops inbound multicast] NWConnectionGroup loopback receive (check only asserts group ready + send) |
| NetworkExtension | ITWV | V: [a] NEHotspotConfigurationManager.apply -> sim error, if available |
| OSLog | ITWV | [a] OSLogStore position filtering, signpost entries (OSLogEntrySignpost) |
| PDFKit | ITV | [a] PDFView text selection (PDFSelection, currentSelection) and find highlighting on screen; [a] outline does not survive write on Apple's simulator too (counted, not asserted); T: [c] assert PDFView init raises (UIEditMenuInteraction unavailable) instead of SKIP |
| PHASE | ITV | I: [a] port visionOS spatial-sound-event-playback (engine-only today); [a] PHASEOccluder/material, ambient mixer; T: [a] port visionOS spatial-sound-event-playback (engine-only today) |
| PassKit | IWV | I: [c] PKIdentityAuthorizationController needs the in-app identity entitlement (Apple ends the app); [a] PKAddPassesViewController with a signed test .pkpass fixture |
| PencilKit | IV | [a] PKCanvasView drawing via touch input |
| PermissionKit | IV | V: [run] x86 result missing |
| Photos | ITV | [a] PHCachingImageManager / PHLivePhoto request; [c] asset delete (PHAssetChangeRequest.deleteAssets prompts: assert simulator answer) |
| PhotosUI | ITWV | [a] iOS presents picker; tvOS/watchOS/visionOS only build views - assert selection via PhotosPickerItem loadTransferable; [a] PHPickerViewController delegate result handling |
| QuartzCore | ITWV | [a] CAGradientLayer / CATextLayer rendered pixels, CADisplayLink frame cadence; W: [a] CATransform3D math through the runtime |
| QuickLook | IV | [a] QLPreviewingController preview extension (appex); [a] QLPreviewController editing (QLPreviewItemEditingMode, didSaveEditedCopy) |
| QuickLookThumbnailing | IV | [a] thumbnails for PDF/movie/text types |
| RealityFoundation | ITV | V: [a] no RealityFoundation check id (re-exported by RealityKit; exercised in RealityKit checks) |
| RealityKit | ITV | [a] ShaderGraphMaterial, VideoMaterial; I: [a] ARView in nonAR camera mode render |
| RelevanceKit | ITWV | [a] WidgetRelevance answered by the widget extension (relevance(), WidgetCenter.invalidateRelevance) |
| SafariServices | IV | [a] SFAuthenticationSession deprecated; SSReadingList add (iOS) |
| SceneKit | ITWV | [a] SCNParticleSystem, light shadows, SCNAudioSource |
| ScreenTime | I | [a] STWebpageController hosting a page: urlIsBlocked / suppressUsageRecording behaviour; [a] STScreenTimeConfigurationObserver |
| Security | ITWV | I: [a] SecAddSharedWebCredential / SecRequestSharedWebCredential -> sim error; [a] SecAccessControl .biometryAny item read with enrolled biometry (needs run.sh input mode) |
| ShazamKit | ITWV | [a] SHLibrary.default items add/read |
| SoundAnalysis | ITWV | [a] SNClassifySoundRequest(mlModel:) with a custom sound classifier |
| SpriteKit | ITWV | W: [a] SKShader / tile map / atlas / emitter (only scene-physics-actions runs there) |
| StoreKit | ITWV | [c] purchases need a .storekit configuration (SKTestSession is Xcode-only); [a] AppStore.requestReview / SKStoreReviewController; T: [a] x86 run of P4 StoreKit checks (ref only); x86 tvOS storefront none vs Apple USA |
| SwiftData | ITWV | [a] custom DataStore; T: [a] x86 run of P4 SwiftData checks (ref only) |
| SwiftUI | ITWV | [a] Menu/contextMenu, toolbar items; [a] DocumentGroup / FileDocument; [a] drag & drop with Transferable (draggable/dropDestination); [a] List swipeActions, popover; [a] DatePicker / Picker menu style; W: [a] port controls-bindings-textfield-focus-submit (Toggle/Slider/Stepper/Picker bindings) |
| SystemConfiguration | ITV | I: [a] CNCopyCurrentNetworkInfo -> nil without the Wi-Fi info entitlement |
| TabletopKit | V | [a] TabletopInteraction gesture / dice roll handling |
| TipKit | ITWV | [a] Tips.resetDatastore / showAllTipsForTesting; T: [a] SwiftUI TipView render; W: [a] SwiftUI TipView render |
| Translation | ITWV | I: [c] TranslationSession.translate with installed assets (Apple sim: not installed -> error, asserted); I: [a] TranslationSession.translations(from:) batch / prepareTranslation |
| UIKit | ITWV | [a] scene lifecycle (background/foreground, state restoration via NSUserActivity); [a] UIContextMenuInteraction (preview + actions); [a] UITextField secure entry / autofill (textContentType) behaviour; T: [a] UIMenu / UITextField text input (menus and text-input checks run on iOS/visionOS only); V: [a] port alert-actionsheet-present, scrollview-zoom-offset, document-save-open, first-responder-text-input |
| USDKit | ITV | [a] _USDKit_RealityKit: convert a USD stage to RealityKit entities |
| UserNotifications | IWV | [a] communication notifications (INSendMessageIntent update); W: [a] UNNotificationServiceExtension mutating a delivered push (simctl push equivalent); V: [a] UNNotificationServiceExtension mutating a delivered push (simctl push equivalent) |
| VideoToolbox | ITV | [a] VTCompressionSession multi-pass, ProRes encode (verify on Apple sim); [c] VTFrameProcessor (frame-rate conversion / super-resolution) isSupported answer |
| Vision | ITWV | [a] VNGenerateOpticalFlowRequest / homographic registration; [c] faces/landmarks/body/hand/classify/saliency: Apple sim has no inference context - checks accept the error (done); W: [a] port translational-registration-horizon |
| VisionEntitlementServices | V | [a] assert licenseStatus valid (Apple's answer) and AppComputeCategory status (reported today) |
| VisionKit | I | [a] ImageAnalysisInteraction text selection / subject lifting asserted (hasActiveTextSelection only reported) |
| WebKit | IV | [a] IndexedDB / service workers; [a] WKWebExtension (iOS 18.4+); [a] WKFindInteraction UI (find bar), not just WKWebView.find |
| WidgetKit | IW | [a] timelines reach currentConfigurations (0 configured today): assert a kind; [a] ControlCenter with a placed control; I: [a] render AccessoryWidgetBackground / widget views (port watchOS accessory-background-render) |
| WorkoutKit | IW | I: [c] WorkoutScheduler.shared authorizationState / scheduledWorkouts never answer on Apple's iPhone simulator (static answers asserted only) |
| _DeviceDiscoveryUI_SwiftUI | IT | I: [a] pin DevicePicker's label (Apple's answer) instead of accepting label or fallback |
| _MusicKit_SwiftUI | ITWV | V: [a] musicSubscriptionOffer attach (iOS only today) |
| _PassKit_SwiftUI | IWV | I: [a] assert per-button ink (x86: pay box 0% ink, wallet 65%; Apple ref hung 70 s so unconfirmed) |
| _PhotosUI_SwiftUI | IWV | [a] loadTransferable of a picker-handed item (needs a selection in the out-of-process picker) |
| _RealityKit_ComputeGraph | ITV | [a] attach a ComputeGraph resource/pipeline and assert simulated output |
| _RealityKit_SwiftUI | ITV | V: [a] RealityView attachments and entity gestures |
| _SwiftData_SwiftUI | ITWV | T: [a] port query-in-hosted-view to iOS/watchOS/visionOS |
| _USDKit_RealityKit | ITV | [c] USDStageComponent.render completes only on a real GPU family (simulator answers failed, no errors - asserted) |
| _WebKit_SwiftUI | IV | [a] WebPage navigation decisions / callJavaScript arguments |

## Check -> framework map: framework use inside checks named after another

Every check id `func:<Framework>.<name>` counts for its named framework (per-platform lists: `existing_checks` in the JSON). Extra frameworks exercised inside other checks (>= 2 SDK symbols of the framework in the body; common frameworks dropped):

| framework | exercised inside |
|---|---|
| AVFAudio | AVFoundation.sample-buffer-renderers-synchronizer, AudioToolbox.auaudiounit-effects-auv3 |
| AppIntents | _AppIntents_UIKit.display-image-system-name |
| AudioToolbox | CoreMIDI.event-list-ump, CoreMIDI.ump-ci-network, CoreMIDI.virtual-loopback, UIKit.input-shake, _CoreHaptics_AudioToolbox.intended-spatial-experience |
| Contacts | ContactsUI.picker-and-contact-view-on-screen |
| CoreAudioTypes | AudioToolbox.auaudiounit-effects-auv3, AudioToolbox.audioqueue-offline-render, AudioToolbox.components-extaudiofile |
| CoreImage | AVFoundation.video-composition-compositor-ci-export, Vision.barcodes-from-coreimage-generators |
| CoreML | CreateMLComponents.logistic-classifier-export-coreml |
| CoreText | PDFKit.document-text-render |
| CryptoKit | Security.seckey-algorithms-exchange-interop |
| EventKit | EventKitUI.event-view-calendar-chooser |
| ExtensionFoundation | ExtensionKit.app-extension-process-xpc |
| GameplayKit | RealityKit.reality-file-roundtrip-usdz-load, SceneKit.animation-player-morpher-skinner, SceneKit.offscreen-render, SceneKit.scene-write-source-load-usdz, SceneKit.scnview-onscreen-continuous, SceneKit.shader-modifier-program-technique, SpriteKit.scene-physics-actions, _SceneKit_SwiftUI.scene-view-render, _SceneKit_SwiftUI.scene-view-renders |
| HealthKit | HealthKitUI.access-request-modifier, HealthKitUI.activity-ring-view |
| HomeKit | _HomeKit_SwiftUI.camera-view-hosted |
| ImageIO | LinkPresentation.loopback-fetch-og-tags-linkview, MediaAccessibility.caption-style-audible-image-caption, libAppleEXR.imageio-openexr-roundtrip |
| Network | Foundation.urlsession-websocket-loopback |
| PermissionKit | _PermissionKit_SwiftUI.communication-limits-button |
| RealityFoundation | RealityKit.ecs-system-animation-raycast, RealityKit.entities-meshes, RealityKit.lowlevel-mesh-texture-render, RealityKit.particles-audio-resource, RealityKit.physics-collision-events, RealityKit.reality-file-roundtrip-usdz-load, RealityKit.reality-renderer-offscreen, _RealityKit_SwiftUI.reality-view-in-window, _RealityKit_SwiftUI.reality-view-make, _RealityKit_SwiftUI.reality-view-make-update, _TabletopKit_RealityKit.entity-equipment-snapshot |
| SwiftData | _SwiftData_SwiftUI.query-in-hosted-view |
| TabletopKit | _TabletopKit_RealityKit.entity-equipment-snapshot, _TabletopKit_SwiftUI.tabletop-game-modifier-in-reality-view |
| UserNotifications | _UserNotifications_AppIntents.content-entity-identifiers |
| VideoToolbox | AVFoundation.assetreader-decoded-pixels-pixel-transfer |
| Vision | SwiftUI.image-renderer-layout |
| WidgetKit | RelevanceKit.contexts-widget-relevance |
| WorkoutKit | _WorkoutKit_SwiftUI.workout-preview-modifier, _WorkoutKit_SwiftUI.workout-preview-modifier-watch |
| _PhotosUI_SwiftUI | PhotosUI.photos-picker-view |

