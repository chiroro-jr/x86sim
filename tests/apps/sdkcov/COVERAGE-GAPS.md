# sdkcov coverage gaps: towards complete SDK coverage

Goal: every public framework of each platform SDK (manifest-<plat>.json = the Xcode 27.2 simulator SDK framework list, incl. sdks/XRSimulator-xcode.sdk for visionOS) has functional checks exercising its main public API with real assertions, matching Apple's simulator (the bar, not hardware). Machine-readable: `coverage-gaps.json` (`{platform: {framework: {status, existing_checks, gaps, package, rejudged, used_inside?, apple_sim_na?, apple_sim_na_done?, api_unavailable?, sdk_availability?, note?}}}`).

Refreshed 2026-11-16 (first pass: commit 4dfb0f4, 2026-11-15). Inputs: 729 distinct framework check ids in checks/*.swift (was 381; +348 from P1..P8, the gaps/FSEvents/FoundationModels rounds and More2 on all platforms); which ids run on which platform and their x86Sim + Apple-reference results = every sdkcov result under ~/scratch since 2026-11-15 (results.txt / sdkcov-N.err of the comb2, P-round, gaps, fse, fm and *-ref-* runs: ios 618, tvos 389, watchos 280, xros 500 ids). Every framework whose check set changed was re-judged from the check bodies (`rejudged: true`); the rest keep their first-pass judgement. Libraries (usr/lib) are out of scope.

Status: **covered** = real assertions on the main API and its main areas; **thin** = real checks but main areas untested; **trivial** = only existence / availability / authorization status / construction, or values reported but not asserted; **none** = no check on that platform; **apple-sim-na** = the main API cannot work in Apple's simulator (hardware, entitlement, missing service): the check must assert the simulator answer (*done* when such an asserting check passes on Apple, *open* otherwise); **api-unavailable** = the SDK marks the whole public API unavailable on that platform (Swift `@available(<os>, unavailable)` / `API_UNAVAILABLE(<os>)` on every declaration; visionOS inherits iOS unavailability): only loading is possible, the load check covers it; **excluded** = headers-only / re-export-only / not in the runtime.

Gap tags: **[a]** doable as a check; **[b: ...]** blocked by an x86Sim bug (named); **[c]** Apple's simulator can't do it - assert its answer; **[run]** no new check needed, a run is missing or stale.

## Counts per platform

| platform | frameworks | covered | thin | trivial | none | apple-sim-na (done / open) | api-unavailable | excluded |
|---|---|---|---|---|---|---|---|---|
| iOS/iPadOS | 285 | 182 | 12 | 23 | 3 | 59 (41 / 18) | 0 | 6 |
| tvOS | 167 | 126 | 4 | 4 | 4 | 16 (9 / 7) | 7 | 6 |
| watchOS | 140 | 99 | 9 | 4 | 2 | 16 (8 / 8) | 7 | 3 |
| visionOS | 230 | 160 | 8 | 10 | 5 | 34 (24 / 10) | 7 | 6 |

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

Assertion upgrades: VideoSubscriberAccount exact answers (VSPrivateErrorDomain -5, 4099) + the visionOS usage string, MusicKit NSAppleMusicUsageDescription on watchOS/visionOS + ApplicationMusicPlayer state, MediaPlayer on watchOS (library query after a media-library grant, remote-command config). _PhotosUI_WidgetKit needs the widget extension. Everything else in P1 is covered.

- **thin**: MediaPlayer [W], MusicKit [WV]
- **trivial**: AssetsLibrary [I], VideoSubscriberAccount [V]
- **none**: _PhotosUI_WidgetKit [IV]
- **apple-sim-na open**: VideoSubscriberAccount [IT]

### P2 Graphics, 3D, AR & games

Small: GameSave assert the .error state without iCloud, OpenGLES port to visionOS, SceneKit watchOS ports (animation/morpher/skinner, usdz write+load), _GameController_SwiftUI with a delivered gamepad event.

- **thin**: SceneKit [W]
- **trivial**: _GameController_SwiftUI [IV]
- **none**: OpenGLES [V]
- **apple-sim-na open**: GameSave [IV]

### P3 App extensions, system services, communication & parental controls

Largest remainder. Assertion upgrades where checks only report: AlarmKit, AppMigrationKit, BrowserEngineCore be_kevent, BusinessChat, RelevanceKit (nothing asserted anywhere), MetricKit payloads/signposts, SystemExtensions, BackgroundTasks continued-processing, DeclaredAgeRange/LinkSecurity no-answer as PASS, PushKit fresh-device no-token, ManagedSettings write read-back. Ports: BackgroundTasks to watchOS, BrowserEngineKit/BrowserKit to tvOS/watchOS/visionOS where available, UserNotificationsUI to tvOS/watchOS, BrowserEngineCore BEMemory on visionOS. Extension work: UNNotificationContentExtension + FileProviderUI action appex, WidgetKit visionOS timelines/ControlCenter, ExtensionFoundation watchOS on an Apple point, App Clip target, tvOS notification service extension. Runs: visionOS x86 for 16 P3 checks (only Apple ran them).

- **thin**: AppClip [I], ExtensionFoundation [W], MetricKit [IV], UserNotifications [T], WidgetKit [V]
- **trivial**: AccessoryLiveActivities [I], AlarmKit [I], AppMigrationKit [I], BrowserEngineCore [I], BusinessChat [I], FileProviderUI [IV], ManagedSettings [T], ManagedSettingsUI [I], NotificationCenter [I], RelevanceKit [ITWV], UserNotificationsUI [IV], _DeviceActivity_SwiftUI [I]
- **none**: BrowserEngineCore [V], UserNotificationsUI [TW]
- **apple-sim-na open**: BackgroundTasks [IW], BrowserEngineKit [TWV], BrowserKit [IW], DeclaredAgeRange [I], ExtensionKit [TWV], LinkSecurity [ITWV], ManagedSettings [I], PushKit [IWV], SystemExtensions [I], TelephonyMessagingKit [I]

### P4 Data, cloud, contacts/calendars & commerce

Ports: SharedWithYouCore to tvOS, _SwiftData_SwiftUI query-in-hosted-view to iOS/watchOS/visionOS. Assertions: ContactProvider domainNotRegistered, AdAttributionKit 3328, watchOS Contacts/EventKit answers with access, ATT request flow after a pre-grant/deny. Runs: tvOS x86 for 18 P4 checks (CloudKit, CoreData, SwiftData, StoreKit, ...: only Apple ran them).

- **thin**: AppTrackingTransparency [ITV], Contacts [W], _MarketplaceKit_UIKit [I]
- **trivial**: AddressBookUI [I], ContactProvider [I], EventKit [W]
- **none**: SharedWithYouCore [T], _SwiftData_SwiftUI [IWV]
- **apple-sim-na open**: AdAttributionKit [I], GroupActivities [ITV], MarketplaceKit [I]

### P5 Health, home, location, sensors & accessories

Matter MTRDeviceController offline start/shutdown; NearbyInteraction two-peer run (nisimhost) + single-peer answer; DeviceDiscoveryUI with NSApplicationServices; appex-only frameworks (AccessoryNotifications, AccessoryTransportExtension, DeviceDiscoveryExtension, HomeExtensions); Apple-sim-N/A assertions still missing: AccessorySetupKit (no .activated), ExposureNotification -71148, SafetyKit raise (ObjC @try shim), WeatherKit on tvOS; _WorkoutKit_SwiftUI presented on watchOS.

- **thin**: AccessoryNotifications [I], AccessoryTransportExtension [I], DeviceDiscoveryExtension [IV], HomeExtensions [I], Matter [ITWV], NearbyInteraction [IW], _WorkoutKit_SwiftUI [W]
- **trivial**: DeviceDiscoveryUI [IT]
- **apple-sim-na open**: AccessorySetupKit [I], ExposureNotification [I], SafetyKit [IW], WeatherKit [T]

### P6 UI frameworks depth & platform UI

Done except _DataDetection_SwiftUI on watchOS (needs the Text on screen: ImageRenderer draws before detection).

- **trivial**: _DataDetection_SwiftUI [W]

### P7 ML, Apple Intelligence, App Intents/Siri, vision, speech & language

FoundationModels: assert the 1026 refusal on visionOS/watchOS (Apple), PCC availability reason; x86 bug SensitiveContentAnalysisML 15 on visionOS. Ports: _AppIntents_HealthKit/_Contacts_AppIntents to tvOS, _Translation_SwiftUI to visionOS, SuggestedActions message-view to visionOS. _CoreSpotlight_FoundationModels SpotlightSearchTool.call without the model, _FoundationModels_UIKit image segment, _AppIntents_SwiftUI tvOS/watchOS sizes, TranslationUIProvider extension, SCVideoStreamAnalyzer. Runs: watchOS x86 for 31 P7/P2 checks.

- **thin**: SuggestedActions [I]
- **trivial**: SuggestedActions [V], _AppIntents_SwiftUI [TW], _CoreSpotlight_FoundationModels [IV], _FoundationModels_UIKit [IV]
- **none**: TranslationUIProvider [I], _AppIntents_HealthKit [T], _Contacts_AppIntents [T], _Translation_SwiftUI [V]
- **apple-sim-na open**: FoundationModels [WV], MediaIntelligence [ITV], SensitiveContentAnalysis [IV]

### P8 Foundation, networking, security, identity & device management

AuthenticationServices on tvOS/watchOS/visionOS (port web-auth loopback callback, assert the cancel answer), ClassKitUI/IdentityLookupUI content (extension for IdentityLookupUI), MultipeerConnectivity visionOS no-peer assertion, _SecureElementCredential overlays answers, AutomatedDeviceEnrollment presented UI (ref-mac.sh first), _ManagedAppDistribution_SwiftUI label/offer.

- **thin**: AuthenticationServices [TWV], AutomatedDeviceEnrollment [I], _ManagedAppDistribution_SwiftUI [V]
- **trivial**: ClassKitUI [IV], IdentityLookupUI [IV], Twitter [I], _SecureElementCredential_SwiftUI [I], _SecureElementCredential_UIKit [I]
- **apple-sim-na open**: MultipeerConnectivity [V]

## Remaining x86Sim-only differences (vs Apple's 27.2 simulator)

Open x86Sim bugs / missing pieces:

- **FileProvider replicated domain** (`FileProvider.replicated-extension-domain`, iOS x86 FAIL "root lists []", Apple PASS on a fresh device; visionOS x86 not run): fileproviderd's `-[FPFSVolume setupForPath:]` needs VOL_CAP_FMT_DOCUMENT_ID | WRITE_GENERATION_COUNT and VOL_CAP_INT_CLONE | RENAME_EXCL from the Darling volume (else ENODEV, domain disabled; patch ~/scratch/fse/darling-volcaps.patch, reverted); with it the next blocker is the missing dataless-materialization upcall (kernel namespace resolver), so the extension is never launched. (The FSEvents half was fixed by the host/fseventsd stand-in.)
- **FoundationModels on visionOS** (relay on): `system-model-availability` FAILs with SensitiveContentAnalysisML error 15 (local sanitizer, OnDeviceInferenceAssetRepository 2) where Apple's FAILs with ModelManagerError 1026. The check should also assert Apple's 1026 refusal.
- **FoundationModels without a Mac**: x86 answers modelNotReady (iOS respond/guided/tools/stream SKIP, Apple PASS via its host Mac) unless X86SIM_FM_RELAY points at a Mac with Apple Intelligence; with the relay the iPad results equal Apple's. Configuration, not a bug.
- **fseventsd stand-in**: kFSEventStreamCreateFlagIgnoreSelf / MarkSelf not implemented (inotify does not say which process made a change), nor hard-link flags or extended data / document ids beyond what the client fills in. `CoreServices.fsevents-stream-file-events` has only an iOS x86 result in the harvested runs (no Apple result, no tvOS/watchOS/visionOS run).
- **BrowserEngineCore JIT witness**: `kevent-jit-restrict` reports "JIT witness supported" 0 on x86 vs 1 on Apple (a CPU feature of the host); not asserted.
- **PushKit VoIP token**: x86 has no apsd APNs-sandbox courier, so never a token (SKIP); Apple's long-lived reference device got an 80-byte token (ref FAIL on the cached-token assertion), a fresh Apple device gets none either.

Unasserted value differences (both PASS; decide whether to assert):

- NaturalLanguage `embeddings-assets` iOS/visionOS: x86 has a sentence embedding and contextual-embedding assets true (mobileassetd downloads mBERT after the boot-a64 LinguisticData link); Apple's fresh devices: no sentence embedding, assets false.
- StoreKit `products-storefront` tvOS: x86 storefront none vs Apple USA (x86 run 2026-11-15 15:30, probably before amsaccountsd joined the tvOS job list in the P8 round: rerun).
- MarketplaceKit `distributor-requirements` iOS: x86 answers AppDistributor.current / eligibilityRegion at once ("error Unknown", nil); Apple never answers for a simctl-installed app (15 s timeouts).
- _PassKit_SwiftUI `wallet-pay-buttons` iOS: x86 pay button box 0% ink (wallet 65%); Apple's run hung, no comparison yet.

Stale x86 results (the failing run predates the fix or the check change; rerun):

- AppIntents `donations` tvOS: FAIL NSCocoaErrorDomain 4099 (com.apple.linkd.transcript) at 2026-11-15 20:04, before com.apple.linkd joined boot-a64.sh's tvOS list.
- HomeKit `home-manager-add-remove-home` and _RelevanceKit_MapKit `poi-category-contexts` watchOS: FAIL texts belong to older assertions.
- AppTrackingTransparency `status` tvOS: 1 (restricted) vs Apple 0 in the last x86 run; check comment says fixed (ManagedConfiguration profiled).

Runs missing (checks only Apple ran): tvOS 18; watchOS 31; visionOS 16 (tvOS: the P4 data checks; watchOS: P7 + a few P2; visionOS: P3). Never run anywhere: ManagedSettings.tv-default-store-effective (tvOS).

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
| _GameController_SwiftUI | tvOS | its 3 Swift decls @available(tvOS, unavailable) |
| BrowserEngineCore | watchOS | BEMemory/BEkevent/BEAudioSession all API_UNAVAILABLE(watchos) |
| DeviceActivity | watchOS | 55/55 Swift decls @available(watchOS, unavailable) |
| EnergyKit | watchOS | 255/255 Swift decls @available(watchOS, unavailable) |
| FamilyControls | watchOS | 29/29 Swift decls @available(watchOS, unavailable) |
| FinanceKit | watchOS | 211/211 Swift decls @available(watchOS, unavailable) |
| ManagedSettings | watchOS | 166/166 Swift decls @available(watchOS, unavailable) |
| MatterSupport | watchOS | 104/104 Swift decls @available(watchOS, unavailable) |
| AutomaticAssessmentConfiguration | visionOS | all 6 ObjC classes API_UNAVAILABLE(visionos) or (ios) (visionOS inherits iOS), 6/6 Swift decls unavailable |
| BrowserKit | visionOS | both ObjC classes (BEAvailability...) API_UNAVAILABLE(..., visionos) |
| EnergyKit | visionOS | 255/255 Swift decls @available(visionOS, unavailable) |
| LockedCameraCapture | visionOS | 17/17 Swift decls @available(visionOS, unavailable) |
| TouchController | visionOS | all 17 ObjC classes API_UNAVAILABLE(macCatalyst, visionos) |
| TrustInsights | visionOS | 92/92 Swift decls @available(visionOS, unavailable) |
| WiFiAware | visionOS | 235/235 Swift decls @available(visionOS, unavailable) |

Partly available (not api-unavailable; the gap names what is left):

- Translation on tvOS (covered): only AttributeScopes.TranslationAttributes (skipsTranslation) is available; TranslationSession/LanguageAvailability are @available(..., unavailable)
- QuartzCore on watchOS (covered): only CATransform3D functions and CACurrentMediaTime are available (every CA class API_UNAVAILABLE(watchos))
- Translation on watchOS (covered): only AttributeScopes.TranslationAttributes (skipsTranslation) is available; TranslationSession/LanguageAvailability are @available(..., unavailable)
- BrowserEngineCore on visionOS (none): only BEMemory (be_memory_inline_jit_restrict_*) is available; be_kevent and BEAudioSession are API_UNAVAILABLE(visionos)
- Translation on visionOS (covered): only AttributeScopes.TranslationAttributes (skipsTranslation) is available; TranslationSession/LanguageAvailability are @available(..., unavailable)
- NetworkExtension on watchOS: NEVPNManager / NERelayManager are API_UNAVAILABLE(watchos); the hotspot API is checked.

Platform letters: I = iOS/iPadOS, T = tvOS, W = watchOS, V = visionOS. A gap prefixed "X:" applies to that platform only.

## No check on the platform (10 frameworks)

Most are ports: the framework is checked on another platform; usually widen the `#if`.

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| BrowserEngineCore | V | - | [a] BEMemory only (be_kevent/BEAudioSession are unavailable on visionOS): be_memory_inline_jit_restrict_rwx_to_rw_with_witness / _rw_to_rx_with_witness round trip on a MAP_JIT page | P3 |
| OpenGLES | V | - | [a] port existing check(s) OpenGLES.context-fbo-clear-readpixels (run on I/T) | P2 |
| SharedWithYouCore | T | - | [a] port existing check(s) SharedWithYouCore.collaboration-metadata (run on I/V) | P4 |
| TranslationUIProvider | I | - | [a] TranslationUIProviderExtension types (needs extension) | P7 |
| UserNotificationsUI | TW | - | [a] port existing check(s) UserNotificationsUI.content-extension-controller (run on I/V); [a] UNNotificationContentExtension appex receiving didReceive(_:) for a delivered notification | P3 |
| _AppIntents_HealthKit | T | - | [a] port existing check(s) _AppIntents_HealthKit.workout-audio-contexts (run on I/W/V) | P7 |
| _Contacts_AppIntents | T | - | [a] port existing check(s) _Contacts_AppIntents.postal-address-entity-type (run on I/W/V) | P7 |
| _PhotosUI_WidgetKit | IV | - | [a] widget photo picker types (needs a widget extension) - build objects | P1 |
| _SwiftData_SwiftUI | IWV | - | [a] port existing check(s) _SwiftData_SwiftUI.query-in-hosted-view (run on T) | P4 |
| _Translation_SwiftUI | V | - | [a] port existing check(s) _Translation_SwiftUI.translation-task-presentation (run on I) | P7 |

## Trivial checks only (29 frameworks)

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| AccessoryLiveActivities | I | feature-results | [c] Live Activity forwarding to an accessory needs a paired AccessorySetupKit accessory: assert the simulator answer of the forwarding authorization request | P3 |
| AddressBookUI | I | people-picker-view | [a] deprecated: keep | P4 |
| AlarmKit | I | authorization-alarms-updates, manager-state | [a] AlarmManager.requestAuthorization + schedule a countdown alarm / cancel (NSAlarmKitUsageDescription; system prompt needs auto-accept); [a] assert authorizationState notDetermined and the empty alarmUpdates answer (today only reported) | P3 |
| AppMigrationKit | I | status-identifiers | [a] assert MigrationStatus.importStatus (nil in the sim; today only reported); [a] AppMigrationExtension (needs an extension) | P3 |
| AssetsLibrary | I | authorization-status | [a] deprecated (unavailable to Swift): keep runtime authorizationStatus call | P1 |
| BrowserEngineCore | I | kevent-jit-restrict | [a] assert be_kevent -> 1 with the timer ident (today only reported); [c] JIT witness supported is a CPU feature (1 Apple silicon, 0 on x86): not assertable across hosts | P3 |
| BusinessChat | I | chat-button | [a] assert BCChatButton intrinsicContentSize (163x52) and its pixels; [a] BCChatAction.openTranscript URL (deprecated) | P3 |
| ClassKitUI | IV | assigned-document-views | [a] assert AssignedDocumentLabel status/date text and AssignedDocumentSubmissionButton state for an assigned document (check only hosts the views; nothing about their content asserted) | P8 |
| ContactProvider | I | manager-without-extension | [a] assert ContactProviderManager() throws domainNotRegistered (today returned, not asserted) | P4 |
| DeviceDiscoveryUI | IT | device-picker, device-picker-ios | [a] add NSApplicationServices to Info.plist so DDDevicePickerViewController's view loads; assert isSupported (Apple: iOS true, tvOS false) and the picker view on screen (today values reported only) | P5 |
| EventKit | W | authorization-event-recurrence, watch-read-access | [a] assert calendars/events(matching:) answers with access (watch-read-access reports counts only) | P4 |
| FileProviderUI | IV | action-extension-controller | [a] FPUIActionExtensionViewController in a real action appex with an extensionContext (completeRequest / cancelRequest) | P3 |
| IdentityLookupUI | IV | classification-view-controller | I: [a] ILClassificationUIExtensionViewController inside a real classification extension (prepare(for:), classificationResponse(for:)) | P8 |
| ManagedSettings | T | store-read-write, tv-default-store-effective | [a] run tv-default-store-effective (never run; asserts effective values nil/false) | P3 |
| ManagedSettingsUI | I | shield-configuration | [c] shield rendering needs a ShieldConfiguration extension + Family Controls authorization: assert the simulator answer | P3 |
| NotificationCenter | I | widget-controller | [a] deprecated (Today widgets): NCWidgetProviding - keep minimal | P3 |
| RelevanceKit | ITWV | contexts, contexts-port, contexts-widget-relevance | [a] assert RelevantContext Codable/Equatable round trip (no check asserts anything); [a] WidgetRelevance answered by the widget extension (relevance(), WidgetCenter.invalidateRelevance) | P3 |
| SuggestedActions | V | message | [a] port message-view-generate (current check only builds a message) | P7 |
| Twitter | I | compose-can-send | [a] deprecated (no Swift module): keep runtime call | P8 |
| UserNotificationsUI | IV | content-extension-controller | [a] UNNotificationContentExtension appex receiving didReceive(_:) for a delivered notification | P3 |
| VideoSubscriberAccount | V | access-status-user-accounts, manager | [c] assert the exact simulator answers (VSPrivateErrorDomain -5, VSUserAccountManager update NSCocoaErrorDomain 4099) instead of only no-hang; [a] add NSVideoSubscriberAccountUsageDescription to the visionOS app so access-status-user-accounts runs (SKIPs on both) | P1 |
| _AppIntents_SwiftUI | TW | siri-tip-view, siri-tip-view-shortcuts-link | T: [a] assert siri-tip-view hosted size/subviews (only reported); W: [a] render SiriTipView (e.g. ImageRenderer) and assert size (only built) | P7 |
| _CoreSpotlight_FoundationModels | IV | spotlight-search-tool | [a] SpotlightSearchTool.call(arguments:) directly over an indexed CSSearchableItem (no model needed); session use needs the model (x86: FM relay) | P7 |
| _DataDetection_SwiftUI | W | text-data-detection | [a] host the Text on screen and assert detected links (ImageRenderer draws before async detection; check only asserts ink) | P6 |
| _DeviceActivity_SwiftUI | I | report-view-hosted | [c] report content needs a DeviceActivityReport extension + authorization: assert the simulator answer | P3 |
| _FoundationModels_UIKit | IV | uiimage-attachment-prompt | [a] assert the Prompt carries an image segment; respond(to:) with it where the model is available (x86 iOS: FM relay) | P7 |
| _GameController_SwiftUI | IV | handles-game-controller-events-modifier | [a] deliver a GCVirtualController / injected gamepad press to the view with .handlesGameControllerEvents and assert it reaches GameController, not UIKit presses | P2 |
| _SecureElementCredential_SwiftUI | I | transaction-task-modifier | [c] transactionTask with a real configuration needs a credential session (assert the simulator answer) | P8 |
| _SecureElementCredential_UIKit | I | window-scene-events | [c] scene connection-options credential events need an NFC presentment (assert the simulator answer) | P8 |

## Thin coverage of main areas (22 frameworks)

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| AccessoryNotifications | I | notification-model-codable | [a] NotificationsForwarding provider / forwarding session in an accessory extension (needs appex) | P5 |
| AccessoryTransportExtension | I | message-builder | [a] AccessoryTransportSession inside an accessory transport extension (needs appex) | P5 |
| AppClip | I | activation-payload | [a] launch an App Clip target (_XCAppClipURL) and call APActivationPayload.confirmAcquired(in:) | P3 |
| AppTrackingTransparency | ITV | not-determined-on-fresh-install, status | [a] requestTrackingAuthorization with a pre-granted / denied tracking privacy -> status authorized/denied; T: [a] x86 run of not-determined-on-fresh-install (last x86 tvOS status check said 1 = restricted, Apple 0) | P4 |
| AuthenticationServices | TWV | apple-id-request, passkey-requests-controller, web-auth-session | T: [a] assert a controller answer beyond pending-in-25s (cancel() -> error 1001/1004 as on visionOS); [a] ASAuthorizationProviderExtension / ASCredentialProviderViewController objects (AutoFill/SSO extension side); W: [a] port web-auth-loopback-callback (ASWebAuthenticationSession start, assert callback URL; visionOS check only asserts canStart false); W: [a] assert a controller answer beyond pending-in-25s (cancel() -> error 1001/1004 as on visionOS); V: [a] port web-auth-loopback-callback (ASWebAuthenticationSession start, assert callback URL; visionOS check only asserts canStart false) | P8 |
| AutomatedDeviceEnrollment | I | addition-modifier | [a] isPresented true on an unmanaged device: assert the system UI or refusal Apple shows (ref-mac.sh first) | P8 |
| Contacts | W | authorization-vcard-formatter, watch-read-access | [a] assert fetch answers with access granted (watch-read-access reports counts only) | P4 |
| DeviceDiscoveryExtension | IV | device-event-types | [a] DDDiscoverySession inside a DeviceDiscoveryExtension appex (appex installs only on iOS) | P5 |
| ExtensionFoundation | W | apple-extension-point-monitor | [a] monitor an Apple extension point with an app extension (today only the unknown-point error) | P3 |
| HomeExtensions | I | settings-model | [a] host the accessory settings in a HomeExtensions appex | P5 |
| Matter | ITWV | certificates-fabric-tlv, setup-payload-codes | [a] MTRDeviceController (storage-based, offline) start/shutdown via MTRDeviceControllerParameters | P5 |
| MediaPlayer | W | nowplaying-remote-commands | [a] MPMediaQuery on an authorized library (auth 0 on the sim: grant media-library TCC so songs/albums queries run); [a] port remote command config (skip intervals, changePlaybackPosition) / MPNowPlayingSession | P1 |
| MetricKit | IV | log-handles-signposts-launch-task, manager | [c] payload delivery: assert pastPayloads / didReceive empty in the sim (today only reported); [a] assert signposts reach the log (mxSignpost / MetricManager.logHandle emitted, not checked) | P3 |
| MusicKit | WV | authorization-status, objects-subscription-catalog-answers | [a] add NSAppleMusicUsageDescription so subscription/catalog calls assert the simulator error (today not made); [a] ApplicationMusicPlayer queue/state asserted (today reported only) | P1 |
| NearbyInteraction | IW | capabilities, unsupported-session-invalidated | [a] two-peer NISession run (Apple sim simulates distance between simulator windows; x86 via nisimhost): assert didUpdate nearby objects; I: [a] assert the single-peer run answer (invalidation / no update) instead of reporting it | P5 |
| SceneKit | W | offscreen-render | [a] SCNParticleSystem, light shadows, SCNAudioSource; [a] port animation-player-morpher-skinner and scene-write-source-load-usdz (no SCNRenderer needed) | P2 |
| SuggestedActions | I | message-view-generate | [a] assert generate result / rendered SuggestedActionsView content (subviews not asserted) | P7 |
| UserNotifications | T | settings-schedule-pending, tv-badge-request-model | [a] UNNotificationServiceExtension mutating a delivered push (simctl push equivalent); [a] communication notifications (INSendMessageIntent update); [c] badge delivery needs authorization whose alert never dismisses unattended (add refusal asserted) | P3 |
| WidgetKit | V | center, widget-extension-descriptors | [a] timelines reach currentConfigurations (0 configured today): assert a kind; [a] ControlCenter with a placed control; [a] render AccessoryWidgetBackground / widget views (port watchOS accessory-background-render); [c] fresh Apple device's chronod does not run the extension in 60 s (ref FAIL predates the skipIf); x86 result missing | P3 |
| _ManagedAppDistribution_SwiftUI | V | managed-content-view | [a] assert ManagedContentView label text / offerAction on tap (check asserts only offer states and laid-out height) | P8 |
| _MarketplaceKit_UIKit | I | install-metadata-display-options | [c] ActionButton init blocks the main thread on Apple outside a marketplace app | P4 |
| _WorkoutKit_SwiftUI | W | workout-preview-modifier-watch | [a] present the preview (isPresented true) and assert it shows | P5 |

## Apple-sim N/A, open (no asserting check yet) (23 frameworks)

Not to be chased beyond asserting the simulator answer.

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| AccessorySetupKit | I | descriptors-display-items, session-activate | [c] add NSAccessorySetupKitSupports to Info.plist and assert ASAccessorySession.activate gives no .activated event (Apple: session never activates); session-activate SKIPs today (ASAccessorySession never activates in Apple's simulator (and traps without NSAccessorySetupKitSupports)) | P5 |
| AdAttributionKit | I | impression-postback-answers | [c] assert Postback.updateConversionValue -> NSCocoaErrorDomain 3328 (today reported, not asserted) (AdAttributionKit is unsupported in the simulator (every call NSCocoaErrorDomain 3328)) | P4 |
| BackgroundTasks | IW | continued-processing-request, register-submit | I: [c] assert BGContinuedProcessingTaskRequest submit -> BGTaskSchedulerErrorDomain 3 (today only reported); W: [c] add a check asserting the simulator answer (unsupported / proper error); W: [a] port existing check(s) BackgroundTasks.continued-processing-request, BackgroundTasks.register-submit (run on I/T/V) (BGTaskScheduler.submit -> .unavailable in Apple's simulator (asserted by register-submit)) | P3 |
| BrowserEngineKit | TWV | - | [c] add a check asserting the simulator answer (unsupported / proper error); [a] port existing check(s) BrowserEngineKit.processes-without-entitlement (run on I); [a] BETextInput / BEScrollView behaviour (only a BEScrollView built) (browser process launches need the web-browser-engine entitlement + extensions) | P3 |
| BrowserKit | IW | data-exchange-types | [c] BEAvailability.isEligible(for:) raises NSInvalidArgumentException in Apple's sim (XPC proxy lacks the selector): not assertable; [a] BEBrowserDataExportManager / ImportManager flows (entitlement): assert the refusal; W: [c] add a check asserting the simulator answer (unsupported / proper error); W: [a] port existing check(s) BrowserKit.data-exchange-types (run on I) (BEAvailability.isEligible raises in Apple's simulator) | P3 |
| DeclaredAgeRange | I | eligibility, request-age-range | [c] assert the no-answer (PASS after the timeout) for isEligibleForAgeFeatures / requestAgeRange instead of SKIP (isEligibleForAgeFeatures / requestAgeRange never answer in Apple's simulator) | P3 |
| ExposureNotification | I | authorization-status, manager-activate-answer | [c] pin the activate error (NSOSStatusErrorDomain -71148) instead of only asserting an answer (needs Apple's Exposure Notification entitlement (deprecated)) | P5 |
| ExtensionKit | TWV | - | [c] installd refuses an appex on an app-defined extension point (ExtensionKit appex works on iOS only): assert AppExtensionPoint/AppExtensionIdentity lookup answers no extension (bundle-less) instead of nothing (tvOS/watchOS/visionOS installd refuse an app extension on a non-Apple extension point (Apple's simulator too)) | P3 |
| FoundationModels | WV | private-cloud-compute-model, schemas-content-transcript, system-model-availability, system-model-respond-guided-tools-stream | W: [c] port the respond check asserting the simulator answer (1026 refusal); [a] PrivateCloudComputeLanguageModel: assert availability/reason (check only reports it); V: [c] system-model-availability FAILs on Apple (available, then ModelManagerError 1026): assert the 1026 refusal instead; V: [b: SensitiveContentAnalysisML error 15] with X86SIM_FM_RELAY, system-model-availability FAILs with SensitiveContentAnalysisML 15 (local sanitizer, OnDeviceInferenceAssetRepository 2) where Apple FAILs with ModelManagerError 1026 (Apple's visionOS/watchOS simulators refuse generation (ModelManagerError 1026)) | P7 |
| GameSave | IV | synced-directory-without-icloud | [c] assert openDirectory state == .error without iCloud (today only close is asserted; state is reported) (GameSaveSyncedDirectory needs an iCloud account) | P2 |
| GroupActivities | ITV | activity-metadata-prepare, activity-sessions, no-call-activation-coding, observer | [c] GroupSessionMessenger / GroupSessionJournal need a session (FaceTime call) (SharePlay sessions need FaceTime) | P4 |
| LinkSecurity | ITWV | flag-urls, flag-urls-port | [c] assert the no-answer (PASS after timeout) instead of SKIP (flagged-URL store lives in imagent, absent from simulator runtimes) | P3 |
| ManagedSettings | I | store-write-read-clear | [c] assert written shield/denyAppRemoval values read back nil (store ignores writes without authorization; today only clear asserted) (store writes need Family Controls authorization (unavailable in the sim)) | P3 |
| MarketplaceKit | I | distributor-requirements | [c] AppDistributor.current / eligibilityRegion: Apple never answers for a simctl install (x86 answers at once, not asserted) (marketplace install APIs need an EU marketplace install; AppLibrary/satisfiedByDevice block on Apple) | P4 |
| MediaIntelligence | ITV | face-group-analyzer | [c] FaceGroupAnalyzer ingest: Vision face networks fail in Apple sim and the framework double-resumes a continuation (abort) - unassertable; only the empty store lifecycle is checkable (face ingest needs Vision espresso inference contexts (absent in Apple sim, aborts)) | P7 |
| MultipeerConnectivity | V | session, two-peer-data-stream-resource | [c] assert the simulator answer (Apple's browser finds no peer in 30 s, no error) instead of SKIP (visionOS: Apple's visionOS simulator browser finds no peer) | P8 |
| PushKit | IWV | registry, voip-credentials | [c] VoIP token needs apsd's APNs sandbox connection: assert no token on a fresh device (today SKIP; iOS ref FAIL to investigate); [a] pushType .fileProvider (no VoIP token on a fresh simulator device (apsd not connected to APNs sandbox)) | P3 |
| SafetyKit | IW | crash-detection, entitlement-gated | [c] assert isAvailable raises NSException without com.apple.developer.safety-kit (needs an ObjC @try shim); watchOS crash-detection SKIPs today (Apple-only entitlement) | P5 |
| SensitiveContentAnalysis | IV | analyze-image-policy, policy | [c] SCVideoStreamAnalyzer / analyzeVideo(at:): assert the same disabled-policy error (needs the client entitlement and user setting (policy disabled)) | P7 |
| SystemExtensions | I | workspace | [c] assert OSSystemExtensionsWorkspace error OSSystemExtensionErrorDomain 1 (today only reported) (DriverKit system extensions cannot be activated in the simulator) | P3 |
| TelephonyMessagingKit | I | handles-content-codable | [c] carrier messaging service: assert the simulator answer (unavailable) (needs a carrier SIM / telephony) | P3 |
| VideoSubscriberAccount | IT | access-status-user-accounts, manager | [c] assert the exact simulator answers (VSPrivateErrorDomain -5, VSUserAccountManager update NSCocoaErrorDomain 4099) instead of only no-hang (no TV-provider service in the simulator (checkAccessStatus -5, user account update 4099)) | P1 |
| WeatherKit | T | service-answers | [c] assert the xpcConnectionFailed (com.apple.weatherkit.authservice) answer instead of SKIP, as the iOS/watchOS/visionOS check does (needs a team-signed WeatherKit entitlement; auth service absent in sim runtimes) | P5 |

## Apple-sim N/A, done (asserting check passes on Apple) (47 frameworks)

Remaining gaps here are optional depth.

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| ARKit | I | configurations, simulator-unsupported-answers | done (iOS: no ARKit tracking in Apple's simulator; visionOS sim supports only WorldTrackingProvider) | P2 |
| AdServices | IV | attribution-token, attribution-token-sim-error | done (attributionToken errors in the simulator) | P4 |
| BackgroundAssets | IV | asset-pack-manager, asset-pack-status-download | [a] BADownloaderExtension: a scheduled BADownload running in the downloader extension (extension registered, seen by ExtensionFoundation monitor on tvOS/visionOS); I: [a] bundle the downloader extension on iOS too; V: [run] x86 result missing (only ref ran) (managed asset packs need App Store hosting: AssetPackManager answers each call with an error (asserted by asset-pack-status-download)) | P3 |
| BackgroundTasks | TV | register-submit | done (BGTaskScheduler.submit -> .unavailable in Apple's simulator (asserted by register-submit)) | P3 |
| BrowserEngineKit | I | processes-without-entitlement | [a] BETextInput / BEScrollView behaviour (only a BEScrollView built) (browser process launches need the web-browser-engine entitlement + extensions) | P3 |
| CallKit | WV | incoming-outgoing-calls, provider-observer | [a] CXCallDirectoryManager status (needs a call directory extension); [run] rerun incoming-outgoing-calls on ref (FAIL predates the error assertion; detail matches the asserted errors); V: [run] x86 result missing (Apple's watchOS/visionOS simulators: callservicesd refuses incoming (CallKit.error 0) and transactions (requesttransaction 1)) | P3 |
| CarKey | IW | remote-control-start-refused | done (needs Wallet car keys (NFC/UWB) and Apple's entitlement) | P5 |
| CoreBluetooth | ITWV | central-state, managers-unsupported-objects | done (no Bluetooth radio in the simulator) | P5 |
| CoreMotion | IWV | availability, unavailable-sensors-queries | done (no motion sensors in the simulator) | P5 |
| CoreNFC | I | reading-available, unavailable-ndef-model | done (no NFC in the simulator) | P5 |
| CoreTelephony | I | network-info, no-radio-answers | done (no cellular radios in the simulator) | P5 |
| DeviceActivity | I | center-activities, start-monitoring-schedule | done (startMonitoring needs Family Controls authorization (entitlement; no FamilyControlsAgent in the sim)) | P3 |
| DeviceCheck | ITWV | support, unsupported-errors | done (DCDevice / App Attest unsupported in Apple's simulator) | P8 |
| EnergyKit | I | venues-guidance-answers | done (no energy venues service in the simulator) | P5 |
| ExternalAccessory | ITV | manager, no-accessories-wifi-browser | done (no MFi accessories) | P5 |
| FamilyControls | I | authorization-selection, authorization-status | [a] FamilyActivityPicker render (requestAuthorization(for: .individual) -> NSCocoaErrorDomain 4099 (no FamilyControlsAgent in Apple's simulator)) | P3 |
| FinanceKit | I | availability-authorization | done (FinanceStore authorization/queries trap without the Apple-granted FinanceKit entitlement) | P4 |
| GameKit | ITWV | local-player-leaderboard-objects, unauthenticated-player-leaderboards-matchmaking | [a] GKTurnBasedMatch.loadMatches / GKLeaderboard.loadEntries error paths without an account (Game Center server features need a signed-in sandbox account (Apple sim: same)) | P2 |
| IdentityDocumentServices | I | registration-store-requests | done (mobile ID documents need Wallet IDs (not in the simulator)) | P8 |
| IdentityDocumentServicesUI | I | web-presentment-controller | done (web presentment needs the identity-document entitlement and Wallet IDs) | P8 |
| ImageCaptureCore | IV | browser-no-devices, device-browser | done (no cameras/scanners attached) | P5 |
| ImagePlayground | IV | availability, image-creator-unavailable | done (needs Apple Intelligence image models) | P7 |
| LockedCameraCapture | I | manager-simulator-answers | done (camera capture extension (no cameras in the simulator)) | P1 |
| ManagedAppDistribution | IV | libraries-unmanaged-device | done (ManagedAppLibrary answers unsupportedPlatform in Apple's simulator) | P8 |
| MatterSupport | IV | add-device-request-answer | done (system Matter setup flow not available in the simulator) | P5 |
| MessageUI | IV | can-send, simulator-answers-composers | [a] MFMailComposeViewController/MFMessageComposeViewController init + present while canSend* is false (no Mail account / Messages in the simulator) | P6 |
| MetalPerformancePrimitives | ITV | tensor-matmul-shader | done (the simulator Metal compiler has no MetalPerformancePrimitives header) | P2 |
| MetalPerformanceShadersGraph | IV | build-compile-no-device, graph-run | done (MPSGraphDevice init aborts in Apple's simulator too) | P2 |
| MusicKit | IT | authorization-status, objects-subscription-catalog-answers | [a] ApplicationMusicPlayer queue/state asserted (today reported only) (catalog/subscription need a MusicKit-enabled team-signed app + Apple Music account) | P1 |
| ProximityReader | I | reader-support, readers-answers | done (Tap to Pay needs NFC hardware + entitlement) | P5 |
| PushToTalk | I | channel-manager | done (Push-to-Talk API not available in the simulator (com.apple.pushtotalk.instantiation 1)) | P3 |
| ReplayKit | ITV | capture-answer-picker, recorder | [a] startRecording/stopRecording -> RPPreviewViewController (or the simulator error); I: [a] RPBroadcastActivityViewController.load (assert simulator answer) (no screen-capture sample buffers in the simulator (startCapture starts, 0 buffers in 5 s)) | P1 |
| RoomPlan | I | unsupported-model | done (needs LiDAR) | P5 |
| SecureElementCredential | I | session-eligibility | done (needs a Secure Element (NFC)) | P8 |
| SensorKit | I | authorization-request-answer, reader-authorization | done (research entitlement + sensors) | P5 |
| Speech | ITV | recognize-synthesized-file, recognizer-availability, speech-analyzer-transcribe-file, speech-transcriber-assets | [a] SFSpeechAudioBufferRecognitionRequest (buffer path) asserting the same kLSRErrorDomain 300; [a] speech-analyzer-transcribe-file: assert AssetInventory status unsupported (not-installed path currently asserts nothing) (no on-device ASR / SpeechTranscriber assets in Apple's simulator (kLSRErrorDomain 300, assets unsupported)) | P7 |
| TouchController | I | layout-render-touch, simulator-unsupported-descriptor | done (TCTouchController.isSupported is false in Apple's simulator) | P2 |
| TrustInsights | I | evaluator-authorization | done (InsightEvaluator answers notAvailable in Apple's simulator) | P8 |
| VisionKit | V | analyzer-scanner-support, image-analyzer-live-text | done (Apple's visionOS simulator analyzes but reads no text; no camera scanners) | P7 |
| WatchConnectivity | IWV | session-activate | I: [a] assert WCSession.isSupported() == false (today SKIP); W: [a] watch-only app gets no session state; a companion-app setup would be needed for transfer APIs; V: [a] assert WCSession.isSupported() == false (today SKIP) (no paired device (iOS/visionOS); watch-only app on watchOS) | P3 |
| WeatherKit | IWV | service-answer | done (needs a team-signed WeatherKit entitlement; auth service absent in sim runtimes) | P5 |
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
| AuthenticationServices | I | [c] ASAuthorizationController.performRequests with a passkey request: Apple's iPad sim shows its passkey sheet and the app hangs (assert the sheet without blocking); [a] ASAuthorizationProviderExtension / ASCredentialProviderViewController objects (AutoFill/SSO extension side) |
| BackgroundAssets | T | [a] BADownloaderExtension: a scheduled BADownload running in the downloader extension (extension registered, seen by ExtensionFoundation monitor on tvOS/visionOS) |
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
| FoundationModels | I | [a] PrivateCloudComputeLanguageModel: assert availability/reason (check only reports it); [b: config] respond/guided/tools/stream need X86SIM_FM_RELAY (a Mac with Apple Intelligence); without it x86 answers modelNotReady where Apple's sim (host Mac) PASSes; with the relay iPad = Apple |
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
| SafariServices | IV | [a] SFAuthenticationSession deprecated; SSReadingList add (iOS) |
| SceneKit | ITV | [a] SCNParticleSystem, light shadows, SCNAudioSource |
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
| UserNotifications | IWV | [a] UNNotificationServiceExtension mutating a delivered push (simctl push equivalent); [a] communication notifications (INSendMessageIntent update) |
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
| _SwiftData_SwiftUI | T | [a] port query-in-hosted-view to iOS/watchOS/visionOS |
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

