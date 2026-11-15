# sdkcov coverage gaps: towards complete SDK coverage

Goal: every public framework of each platform SDK (manifest-<plat>.json = the Xcode 27.2 simulator SDK framework list, incl. sdks/XRSimulator-xcode.sdk for visionOS) has at least one functional check exercising its main public API with real assertions, and the checks cover its main feature areas. Machine-readable: `coverage-gaps.json` (`{platform: {framework: {status, existing_checks, gaps, package, used_inside?, apple_sim_na?, note?}}}`).

Inputs (2026-11-15): 426 distinct functional check ids parsed from checks/*.swift (incl. the uncommitted More2 edits); which ones run on which platform from the comb2 runs (`~/scratch/x86sim/apps/sdkcov-<plat>-comb2/results.txt`: iOS 320, tvOS 246, watchOS 173, visionOS 263 func results; the iPad run has the same 320 ids); framework use inside other checks from SDK header/swiftinterface symbols; Apple-simulator behaviour from SKIP reasons and the ref-mac.sh results. Libraries (usr/lib) are out of scope here (all have a check or are Xcode tools).

Status: **covered** = real assertions on the main API; **thin** = real checks but main areas of a large framework untested; **trivial** = only existence / availability / authorization status / object construction without behaviour (or no assertion); **none** = no functional check on that platform; **apple-sim-na** = cannot work in Apple's simulator (hardware, entitlement, missing service) - not to be chased, but needs a check asserting the simulator behaviour; **excluded** = headers-only / re-export-only / not in the runtime.

## Counts per platform

| platform | frameworks | functional-covered (covered + thin) | of which thin | trivial-only | no functional check | Apple-sim N/A | excluded |
|---|---|---|---|---|---|---|---|
| iOS/iPadOS | 285 | 105 | 24 | 47 | 98 | 29 | 6 |
| tvOS | 167 | 102 | 22 | 23 | 30 | 6 | 6 |
| watchOS | 140 | 61 | 15 | 14 | 52 | 10 | 3 |
| visionOS | 230 | 96 | 27 | 35 | 77 | 16 | 6 |

Not counted (Swift runtime modules, not SDK frameworks, all covered): Swift, Dispatch, Observation, Distributed, os.

## Excluded (listed, not chased)

| framework | platforms | why |
|---|---|---|
| AudioUnit | ITV | headers only (no binary): the AU API lives in AudioToolbox - covered there |
| CoreAudioTypes | ITWV | headers only: types used by AudioToolbox/AVFAudio checks (AudioStreamBasicDescription, AudioBufferList) |
| _FoundationModels_SwiftUI | IV | not in the simulator runtimes (load SKIP) |
| _GroupActivities_UIKit | T | tvOS: re-export only (no public declarations) |
| _Intents_TipKit | ITWV | re-export only (no public declarations) |
| _LocationEssentials | ITWV | C types/functions re-exported by CoreLocation (CLLocationCoordinate2D...): used by CoreLocation/MapKit checks |
| _SharedWithYou_AppIntents | ITV | re-export only (no public declarations) |

## Check -> framework map: framework use inside checks named after another

Every check id `func:<Framework>.<name>` counts for its named framework (full per-platform lists: `existing_checks` in the JSON). Notable extra frameworks exercised inside other checks (symbol-level, noise like Foundation/CoreFoundation dropped):

| framework | exercised inside |
|---|---|
| AVFAudio | CoreAudioKit.generic-au-view, PHASE.spatial-sound-event-playback |
| AVFoundation | AVKit.player-view-controller, AVKit.tv-content-proposal-display-criteria, AVKit.tv-player-transport-bar-playback, AVRouting.playback-arbiter, MediaToolbox.audio-processing-tap, MusicUnderstanding.click-track-loudness-rhythm, _AVKit_SwiftUI.video-player-hosted, _AVKit_SwiftUI.video-player-view |
| AVKit | _AVKit_SwiftUI.video-player-hosted, _AVKit_SwiftUI.video-player-view |
| ClockKit | _ClockKit_SwiftUI.graphic-view-templates |
| CoreAudioTypes | AudioToolbox.components-extaudiofile |
| CoreData | _CoreData_CloudKit.container-options-scope, _SwiftData_CoreData.managed-object-model |
| CoreImage | Vision.barcodes-from-coreimage-generators |
| CoreLocation | RelevanceKit.contexts, RelevanceKit.contexts-widget-relevance |
| CoreML | CreateMLComponents.scalers-regressor-fit |
| CoreServices | MobileCoreServices.uttype-declarations |
| CoreText | PDFKit.document-text-render |
| CoreVideo | AVFoundation.assetreader-decoded-pixels-pixel-transfer, AVFoundation.player-playback-video-output, CoreMedia.time-formats-samplebuffers, ImmersiveMediaSupport.video-frame-fade-command, VideoToolbox.h264-hevc-encode-decode |
| DeviceDiscoveryUI | _DeviceDiscoveryUI_SwiftUI.device-picker-supports |
| GameController | UIKit.ipad-key-commands, UIKit.ipad-pointer-hover |
| HealthKit | HealthKitUI.activity-ring-view |
| ImageIO | libAppleEXR.imageio-openexr-roundtrip |
| Intents | IntentsUI.voice-shortcut-button-controller |
| MapKit | _MapKit_SwiftUI.map-camera-markers |
| Metal | CoreImage.metal-vs-software-filter-chain, CoreVideo.pixelbuffer-pool-metal-cache, MetalKit.mtkview-draw-loop-on-screen, MetalKit.texture-loader-mesh, MetalPerformanceShaders.blur-matmul, MetalPerformanceShadersGraph.graph-run, RealityKit.reality-renderer-offscreen, SceneKit.offscreen-render, TouchController.layout-render-touch |
| Network | Foundation.urlsession-websocket-loopback |
| PDFKit | UIKit.attributed-html-import-print-renderer, WebKit.css-render-snapshot-createpdf |
| QuartzCore | ARKit.world-tracking-run-outside-immersive, AVFoundation.player-playback-video-output, UIKit.animation-displaylink-rate |
| RealityFoundation | RealityKit.ecs-system-animation-raycast, RealityKit.entities-meshes, RealityKit.reality-renderer-offscreen, _RealityKit_SwiftUI.reality-view-in-window, _RealityKit_SwiftUI.reality-view-make |
| RelevanceKit | _RelevanceKit_MapKit.poi-category-context |
| SharedWithYou | SharedWithYouCore.collaboration-metadata |
| SpriteKit | _SpriteKit_SwiftUI.sprite-view-runs-scene, _SpriteKit_SwiftUI.sprite-view-updates |
| SwiftData | _SwiftData_SwiftUI.query-in-hosted-view |
| SwiftUI | SecurityUI.certificate-sheet, UIKit.accessibility-elements-actions-swiftui-tree, _AVKit_SwiftUI.video-player-view, _AuthenticationServices_SwiftUI.sign-in-button, _MapKit_SwiftUI.map-camera-markers, _PassKit_SwiftUI.wallet-pay-buttons, _SceneKit_SwiftUI.scene-view-render, _SceneKit_SwiftUI.scene-view-renders, _SpriteKit_SwiftUI.sprite-view-updates, _WebKit_SwiftUI.webpage-webview-javascript |
| UIKit | AVKit.tv-player-transport-bar-playback, CarPlay.templates, PDFKit.create-annotate-search-roundtrip, PencilKit.ipad-canvas-tool-picker, SwiftUI.hosting-navigation-state-list, SwiftUI.ipad-navigation-split-view, SwiftUI.open-dismiss-immersive-space, SwiftUI.open-dismiss-window-volume, SwiftUI.tv-focus-state-default-focus, TVUIKit.digit-entry-fullscreen-layout, TVUIKit.lockups-cards-render, TVUIKit.poster-lockup, WebKit.css-render-snapshot-createpdf, WebKit.webview-load-javascript, _AppIntents_UIKit.collection-view-data-source, _MapKit_SwiftUI.map-camera-markers, _SceneKit_SwiftUI.scene-view-render, libMobileGestalt.answers |
| VideoToolbox | AVFoundation.assetreader-decoded-pixels-pixel-transfer |
| WatchKit | libMobileGestalt.answers-match-device |
| WidgetKit | RelevanceKit.contexts-widget-relevance |
| _CoreLocationUI_SwiftUI | CoreLocationUI.location-button-render |
| _PhotosUI_SwiftUI | PhotosUI.photos-picker-view |

Platform letters: I = iOS/iPadOS, T = tvOS, W = watchOS, V = visionOS.

## (a) No functional check (130 frameworks)

A "port existing check(s)" gap means the framework is already checked on another platform: usually just widen the `#if`.

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| AVKit | W | - | port existing check(s) AVKit.player-view-controller, AVKit.tv-content-proposal-display-criteria, AVKit.tv-player-transport-bar-playback (run on I/T/V); AVKit on watchOS is VideoPlayer (_AVKit_SwiftUI) + AVPlayer playback: one hosted-VideoPlayer check | P1 |
| AVRouting | I | - | port existing check(s) AVRouting.custom-routing-controller, AVRouting.playback-arbiter (run on T/V); AVCustomRoutingController/AVCustomDeviceRoute events (needs DeviceDiscoveryExtension: assert empty routes + delegate) | P1 |
| AccessoryLiveActivities | I | - | accessory Live Activity types build (iOS 27) | P3 |
| AccessoryNotifications | I | - | accessory notification forwarding types | P5 |
| AccessoryTransportExtension | I | - | transport extension types (needs extension) | P5 |
| AdAttributionKit | I | - | AppImpression(compactJWS:) parse error on bad JWS, Postback.updateConversionValue -> sim error, AdAttributionKit events | P4 |
| AppClip | I | - | APActivationPayload.confirmAcquired(in:) -> error outside an App Clip | P3 |
| AppIntentsTypeSupport | IWV | - | port existing check(s) AppIntentsTypeSupport.value-containers (run on T) | P7 |
| AppMigrationKit | I | - | AppMigrationExtension types / migration status APIs (iOS 26) | P3 |
| AutomatedDeviceEnrollment | I | - | enrollment APIs on an unmanaged device -> assert not-enrolled state | P8 |
| AutomaticAssessmentConfiguration | V | - | port existing check(s) AutomaticAssessmentConfiguration.configuration-session (run on I) | P8 |
| BackgroundAssets | V | - | port existing check(s) BackgroundAssets.asset-pack-manager, BackgroundAssets.asset-pack-manager-downloads (run on I/T); BADownloaderExtension (needs extension) | P3 |
| BrowserEngineCore | ITWV | - | be_kevent / JIT write-protect C API (BE_JIT) - assert behaviour without entitlement | P3 |
| BrowserEngineKit | ITWV | - | BEWebContentProcess/BENetworkingProcess launch -> requires browser entitlement: assert error; BETextInput / BEScrollView UI objects | P3 |
| BrowserKit | IWV | - | BrowserKit eligibility (BEAvailability) answer | P3 |
| BusinessChat | I | - | BCChatButton render + BCChatAction.openTranscript URL (deprecated) | P3 |
| ClassKit | V | - | port existing check(s) ClassKit.main-app-context (run on I); CLSActivity/CLSContext tree creation + save (sim: ClassKit needs entitlement) | P8 |
| ClassKitUI | IV | - | CLSContextTopic UI build | P8 |
| ClockKit | I | - | port existing check(s) ClockKit.complication-server, ClockKit.templates-providers-descriptors (run on W); ClockKit (CLKComplicationServer on iPhone?) minimal check | P6 |
| ComputeGraph | ITV | - | build and evaluate a small ComputeGraph (343 public decls) on CPU; _RealityKit_ComputeGraph bridging | P2 |
| ContactProvider | I | - | ContactProviderManager on an app without the extension -> error | P4 |
| CoreAudio | ITWV | - | AudioObjectGetPropertyData on kAudioObjectSystemObject (devices, default output, nominal sample rate) - sim exposes the HAL; AudioHardwareBase property listener add/remove | P1 |
| CoreMIDI | W | - | port existing check(s) CoreMIDI.event-list-ump, CoreMIDI.virtual-loopback (run on I/T/V); MIDINetworkSession (iOS) enable/contacts; MIDICIDiscoveryManager / MIDI-CI profile objects | P1 |
| CoreSpotlight | T | - | port existing check(s) CoreSpotlight.index-delete (run on I/V); CSSearchQuery finds the indexed item; CSUserQuery (iOS 18); batch indexing with client state | P4 |
| DeveloperToolsSupport | IWV | - | port existing check(s) DeveloperToolsSupport.design-time-values-library (run on T) | P6 |
| DeviceActivity | W | - | port existing check(s) DeviceActivity.center-activities (run on I); DeviceActivityCenter.startMonitoring schedule -> error without FamilyControls authorization; DeviceActivityReport view | P3 |
| DeviceDiscoveryExtension | IV | - | DDDiscoverySession types (needs extension) | P5 |
| DeviceDiscoveryUI | I | - | port existing check(s) DeviceDiscoveryUI.device-picker (run on T); add NSApplicationServices to Info.plist so DDDevicePickerViewController's view loads (today only isSupported + init) | P5 |
| EnergyKit | ITWV | - | ElectricityGuidance query for a location -> sim answer/error | P5 |
| ExtensionFoundation | IWV | - | port existing check(s) ExtensionFoundation.extension-point-monitor (run on T); AppExtensionProcess launch of an in-app appex | P3 |
| ExtensionKit | ITWV | - | bundle a minimal ExtensionKit appex: AppExtensionPoint discovery, EXHostViewController hosting it, AppExtensionProcess XPC connection | P3 |
| FamilyControls | W | - | port existing check(s) FamilyControls.authorization-status (run on I); AuthorizationCenter.requestAuthorization(for: .individual) -> entitlement error on sim; FamilyActivityPicker render | P3 |
| FileProviderUI | IV | - | FPUIActionExtensionViewController (needs extension) - build objects | P3 |
| FinanceKit | IW | - | FinanceStore.isDataAvailable(.financialData) and authorization status (Apple sim: verify); FinanceKitUI TransactionPicker | P4 |
| FinanceKitUI | I | - | TransactionPicker / AddOrderToWalletButton render | P4 |
| FoundationModels | TW | - | port existing check(s) FoundationModels.system-model-availability (run on I/V); x86sim: model .modelNotReady (Apple's iOS sim answers "Pong" via the host Mac) - x86sim gap; @Generable guided generation, Tool calling, streaming responses; availability assertion (unsupported device?) | P7 |
| GameSave | IV | - | GameSaveSyncedDirectory open/finishSyncing (needs iCloud: assert error/state on sim) | P2 |
| HealthKitUI | W | - | port existing check(s) HealthKitUI.activity-ring-view (run on I/V) | P5 |
| HomeExtensions | I | - | home extension types build | P5 |
| IdentityDocumentServicesUI | I | - | provider UI objects build | P8 |
| IdentityLookupUI | IV | - | ILClassificationUIExtensionViewController build (needs extension) | P8 |
| ImmersiveMediaSupport | I | - | port existing check(s) ImmersiveMediaSupport.video-frame-fade-command (run on V); ImmersiveMediaRemotePreviewSender/VenueDescriptor/presentation commands JSON | P1 |
| IntentsUI | T | - | port existing check(s) IntentsUI.voice-shortcut-button-controller (run on I/V) | P7 |
| LocalAuthentication | T | - | port existing check(s) LocalAuthentication.input-biometric, LocalAuthentication.policies (run on I/V/W); LAContext evaluatePolicy with simulated enrolled biometry (input-biometric needs run.sh input mode); LARight / LAPersistedRight (iOS 16+) | P8 |
| LocalAuthenticationEmbeddedUI | IV | - | LAAuthenticationView render bound to an LAContext | P8 |
| ManagedApp | I | - | port existing check(s) ManagedApp.configuration-provider (run on V) | P8 |
| ManagedAppDistribution | IV | - | ManagedAppDistribution API answer on an unmanaged device; _ManagedAppDistribution_SwiftUI | P8 |
| ManagedSettings | IW | - | port existing check(s) ManagedSettings.store-read-write (run on T); ManagedSettingsStore shield/denyAppRemoval write+read back (needs authorization) | P3 |
| ManagedSettingsUI | I | - | ShieldConfiguration objects build | P3 |
| MarketplaceKit | I | - | AppLibrary / MarketplaceExtension types; ActionButton render (_MarketplaceKit_UIKit) -> EU-only behaviour | P4 |
| MatterSupport | ITWV | - | MatterAddDeviceRequest.perform -> sim behaviour (needs extension) | P5 |
| MediaIntelligence | IV | - | port existing check(s) MediaIntelligence.face-group-analyzer (run on T) | P7 |
| MediaIntents | IW | - | port existing check(s) MediaIntents.audio-search-codable (run on T/V) | P1 |
| MetalPerformancePrimitives | ITV | - | compile a Metal shader #including <MetalPerformancePrimitives/MetalPerformancePrimitives.h> (tensor ops matmul2d) and run if the device supports tensors; else assert compile error | P2 |
| MetricKit | T | - | port existing check(s) MetricKit.manager (run on I/V); MXMetricManager.makeLogHandle + mxSignpost, extendLaunchMeasurement(forTaskID:), MXMetricPayload JSON decoding from a fixture | P3 |
| MusicUnderstanding | IWV | - | port existing check(s) MusicUnderstanding.click-track-loudness-rhythm (run on T) | P1 |
| NowPlaying | IWV | - | port existing check(s) NowPlaying.media-session-primary (run on T) | P1 |
| OpenGLES | V | - | port existing check(s) OpenGLES.context-fbo-clear-readpixels (run on I/T) | P2 |
| PermissionKit | IV | - | PermissionQuestion<CommunicationTopic> build, AskCenter.ask in a view controller -> sim behaviour (no family); _PermissionKit_SwiftUI / _PermissionKit_UIKit overlays | P3 |
| PushToTalk | I | - | PTChannelManager.channelManager(delegate:restorationDelegate:) -> needs entitlement + background mode: assert error/behaviour | P3 |
| QuartzCore | W | - | port existing check(s) QuartzCore.layers-render-animation (run on I/T/V); CAMetalLayer nextDrawable/present outside MetalKit; CAEmitterLayer, CAReplicatorLayer, CATransformLayer, CAShapeLayer strokeEnd animation sampled via presentation(); CATiledLayer, CATransaction completion blocks; CAMediaTimingFunction / CATransform3D math (watchOS QuartzCore subset) | P2 |
| RelevanceKit | I | - | port existing check(s) RelevanceKit.contexts, RelevanceKit.contexts-widget-relevance (run on T/V/W); relevance contexts have no assertion: assert Codable/Equatable round trip, WidgetRelevance in a widget extension | P3 |
| ScreenTime | I | - | STWebHistory / STWebpageController in a WKWebView host | P3 |
| SecurityUI | IWV | - | port existing check(s) SecurityUI.certificate-sheet (run on T) | P8 |
| ServicesAccountLinking | I | - | account linking request objects (iOS 27) | P8 |
| SharedWithYouCore | T | - | port existing check(s) SharedWithYouCore.collaboration-metadata (run on I/V) | P4 |
| StateReporting | I | - | port existing check(s) StateReporting.metadata-values-reporter, StateReporting.reporter-transitions (run on T/V/W) | P3 |
| SuggestedActions | I | - | port existing check(s) SuggestedActions.message (run on V) | P7 |
| SystemExtensions | I | - | OSSystemExtensionRequest on iOS (driverkit) -> error | P3 |
| TabletopKit | V | - | TableSetup/TabletopGame with equipment + actions offline; _TabletopKit_RealityKit/SwiftUI/GroupActivities overlays | P2 |
| Translation | TWV | - | port existing check(s) Translation.language-availability (run on I); LanguageAvailability.status(from:to:); TranslationSession.translate (assets: verify on Apple sim) | P7 |
| TranslationUIProvider | I | - | TranslationUIProviderExtension types (needs extension) | P7 |
| TrustInsights | IV | - | TrustInsights API answer (new): verify on Apple sim | P8 |
| UserNotificationsUI | ITWV | - | UNNotificationContentExtension (needs extension): build an NSExtension-less view controller conforming to the protocol | P3 |
| VisionEntitlementServices | V | - | enterprise entitlement queries (visionOS) answer | P5 |
| _AVKit_SwiftUI | WV | - | port existing check(s) _AVKit_SwiftUI.video-player-hosted, _AVKit_SwiftUI.video-player-view (run on I/T); VideoPlayer playback check (port iOS video-player-view) | P1 |
| _AdAttributionKit_StoreKit | I | - | SKOverlay/loadProduct with AppImpression | P4 |
| _AppIntents_HealthKit | ITWV | - | HealthKit AppIntents entities | P7 |
| _AppIntents_SwiftUI | IWV | - | port existing check(s) _AppIntents_SwiftUI.siri-tip-view (run on T) | P7 |
| _AppIntents_UIKit | IWV | - | port existing check(s) _AppIntents_UIKit.collection-view-data-source (run on T) | P7 |
| _AuthenticationServices_SwiftUI | WV | - | port existing check(s) _AuthenticationServices_SwiftUI.sign-in-button, _AuthenticationServices_SwiftUI.sign-in-with-apple-button (run on I/T); SignInWithAppleButton render (port) | P8 |
| _Contacts_AppIntents | ITWV | - | CNContact AppEntity conversions | P7 |
| _CoreData_CloudKit | IWV | - | port existing check(s) _CoreData_CloudKit.container-options-scope (run on T) | P4 |
| _CoreHaptics_AudioToolbox | V | - | CHHapticEngine.intendedSpatialExperience round trip | P1 |
| _CoreLocationUI_SwiftUI | IW | - | LocationButton SwiftUI render with assertion | P5 |
| _CoreSpotlight_FoundationModels | IV | - | CoreSpotlight tool for FoundationModels sessions (needs model) | P7 |
| _DataDetection_SwiftUI | IWV | - | dataDetection(_:) modifier on Text | P6 |
| _DeviceActivity_SwiftUI | I | - | DeviceActivityReport view build | P3 |
| _DeviceDiscoveryUI_SwiftUI | I | - | port existing check(s) _DeviceDiscoveryUI_SwiftUI.device-picker-supports (run on T) | P5 |
| _FinanceKit_AppIntents | I | - | FinanceKit AppIntents types | P7 |
| _FoundationModels_UIKit | IV | - | UIImage as PromptRepresentable in a session prompt | P7 |
| _GameController_SwiftUI | ITV | - | handlesGameControllerEvents(matching:) modifier in a hosted view | P2 |
| _GeoToolbox_AppIntents | ITWV | - | PlaceDescriptor AppEntity | P7 |
| _GroupActivities_SwiftUI | V | - | SharePlay SwiftUI modifiers build | P4 |
| _GroupActivities_UIKit | IV | - | GroupActivitySharingController build (iOS/visionOS) | P4 |
| _HomeKit_SwiftUI | ITWV | - | HomeKit SwiftUI modifiers | P5 |
| _LinkPresentation_AppIntents | ITWV | - | LPLinkMetadata AppIntents conversion | P7 |
| _ManagedAppDistribution_SwiftUI | V | - | managed app distribution SwiftUI views | P8 |
| _MapKit_SwiftUI | WV | - | port existing check(s) _MapKit_SwiftUI.map-camera-markers, _MapKit_SwiftUI.map-view-hosted (run on I/T); Map render (port) | P5 |
| _MarketplaceKit_UIKit | I | - | MarketplaceKit UIKit ActionButton build | P4 |
| _MediaIntents_AppIntents | ITWV | - | MediaIntents AppIntents types (AudioSearch as intent parameter) build | P7 |
| _MediaPlayer_AppIntents | ITWV | - | MPAppEntityIdentifier secure-coding round trip | P7 |
| _MusicKit_SwiftUI | ITWV | - | musicSubscriptionOffer modifier / ArtworkImage render (nil artwork placeholder) | P1 |
| _NowPlaying_AppIntents | ITWV | - | NowPlaying AppIntents extensions build/encode | P7 |
| _PassKit_SwiftUI | WV | - | port existing check(s) _PassKit_SwiftUI.wallet-pay-buttons (run on I) | P4 |
| _PermissionKit_SwiftUI | IV | - | CommunicationLimitsButton render | P3 |
| _PermissionKit_UIKit | IV | - | AskCenter.ask(_:in:) UIKit presentment | P3 |
| _PhotosUI_SwiftUI | IWV | - | PhotosPicker render + selection binding (watchOS has photos-picker-view under PhotosUI) | P1 |
| _PhotosUI_WidgetKit | IV | - | widget photo picker types (needs a widget extension) - build objects | P1 |
| _Photos_AppIntents | ITV | - | PHAsset AppEntity conversions | P7 |
| _QuickLook_SwiftUI | IV | - | quickLookPreview modifier present | P6 |
| _RealityKit_ComputeGraph | ITV | - | ComputeGraph-driven RealityKit component | P2 |
| _RealityKit_SwiftUI | I | - | port existing check(s) _RealityKit_SwiftUI.reality-view-in-window, _RealityKit_SwiftUI.reality-view-make (run on T/V); RealityView make/update (tvOS/visionOS covered) | P2 |
| _RelevanceKit_MapKit | IWV | - | port existing check(s) _RelevanceKit_MapKit.poi-category-context (run on T); assert RelevantContext.location(category:) non-nil (no assertion today); iOS/watchOS/visionOS: port | P5 |
| _SceneKit_SwiftUI | WV | - | port existing check(s) _SceneKit_SwiftUI.scene-view-render, _SceneKit_SwiftUI.scene-view-renders (run on I/T); SceneView render (iOS/tvOS covered) | P2 |
| _SecureElementCredential_SwiftUI | I | - | SwiftUI presentment modifier build | P8 |
| _SecureElementCredential_UIKit | I | - | UIKit presentment API build | P8 |
| _SpriteKit_SwiftUI | WV | - | port existing check(s) _SpriteKit_SwiftUI.sprite-view-runs-scene, _SpriteKit_SwiftUI.sprite-view-updates (run on I/T); SpriteView render | P2 |
| _StoreKit_SwiftUI | IWV | - | port existing check(s) _StoreKit_SwiftUI.product-store-views (run on T) | P4 |
| _SwiftData_CoreData | IWV | - | port existing check(s) _SwiftData_CoreData.managed-object-model (run on T) | P4 |
| _SwiftData_SwiftUI | IWV | - | port existing check(s) _SwiftData_SwiftUI.query-in-hosted-view (run on T) | P4 |
| _TabletopKit_GroupActivities | V | - | TabletopKit SharePlay coordination types (no FaceTime) | P2 |
| _TabletopKit_RealityKit | V | - | TabletopKit RealityKit rendering components | P2 |
| _TabletopKit_SwiftUI | V | - | TabletopKit SwiftUI views | P2 |
| _Translation_SwiftUI | IV | - | translationPresentation / translationTask modifiers | P7 |
| _USDKit_RealityKit | ITV | - | USD stage -> Entity conversion | P2 |
| _UserNotifications_AppIntents | ITWV | - | UNNotificationContent.appEntityIdentifiers | P7 |
| _WebKit_SwiftUI | V | - | port existing check(s) _WebKit_SwiftUI.webpage-webview-javascript (run on I) | P6 |
| _WorkoutKit_SwiftUI | IW | - | workoutPreview(_:isPresented:) modifier | P5 |
| iAd | I | - | deprecated stub framework: ADClient requestAttributionDetails -> error | P4 |

## (b) Trivial checks only (55 frameworks)

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| ARKit | V | data-providers, session-authorization-query, world-tracking-run-outside-immersive | run WorldTrackingProvider + PlaneDetectionProvider inside the ImmersiveSpace (Apple sim supports both): assert device anchor + plane anchors, WorldAnchor add/remove; assert hands/scene/image providers isSupported == false | P2 |
| AVKit | IV | player-view-controller | AVPlayerViewController with real playback (today only loadView; tvOS has transport-bar playback); AVPictureInPictureController: isPictureInPictureSupported, sample-buffer PiP content source (sim supports PiP on iOS); AVRoutePickerView render, AVPlayerViewControllerDelegate full-screen transitions | P1 |
| AVRouting | TV | custom-routing-controller, playback-arbiter | AVCustomRoutingController/AVCustomDeviceRoute events (needs DeviceDiscoveryExtension: assert empty routes + delegate) | P1 |
| AccessorySetupKit | I | session-activate | add NSAccessorySetupKitSupports to Info.plist: activate -> .activated event, showPicker -> sim behaviour (today SKIP: harness gap) | P5 |
| Accounts | I | store | deprecated: ACAccountType lookup + requestAccess -> denied/unsupported | P8 |
| ActivityKit | I | authorization, live-activity-lifecycle | add NSSupportsLiveActivities + a widget extension: Activity.request/update/end lifecycle (today SKIP unsupportedTarget, harness gap, Apple sim supports it); push-token updates (pushType .token) -> sim token | P3 |
| AdSupport | IT | identifier | assert zeroed IDFA when not authorized | P4 |
| AddressBookUI | I | people-picker-view | deprecated: keep | P4 |
| AlarmKit | I | manager-state | AlarmManager.requestAuthorization + schedule a countdown alarm / cancel (needs NSAlarmKitUsageDescription) | P3 |
| AppTrackingTransparency | ITV | status | requestTrackingAuthorization flow (prompt) -> status change | P4 |
| AssetsLibrary | I | authorization-status | deprecated (unavailable to Swift): keep runtime authorizationStatus call | P1 |
| AuthenticationServices | ITWV | apple-id-request, web-auth-session | ASAuthorizationController.performRequests -> sim error / sheet; passkey registration request objects (ASAuthorizationPlatformPublicKeyCredentialProvider); ASWebAuthenticationSession.start against a loopback server with callback scheme (assert callback URL); ASCredentialIdentityStore state; ASAuthorizationProviderExtension (SSO) objects | P8 |
| BackgroundAssets | I | asset-pack-manager | add BAAppGroupID/BAInitialDownloadRestrictions to Info.plist so AssetPackManager runs (today SKIP); BADownloaderExtension (needs extension) | P3 |
| CallKit | IWV | provider-observer | CXProvider reportNewIncomingCall + CXCallController request transaction (Apple sim supports CallKit UI); CXCallDirectoryManager status (extension) | P3 |
| ClassKit | I | main-app-context | CLSActivity/CLSContext tree creation + save (sim: ClassKit needs entitlement) | P8 |
| CloudKit | ITWV | account-status | local API: CKRecord/CKRecordZone/CKShare/CKQuery/CKOperation configuration, NSSecureCoding of CKRecord; CKSyncEngine state serialization round trip; server ops: Apple-sim N/A without team signing + account -> assert CKError.missingEntitlement/notAuthenticated | P4 |
| ContactsUI | IV | contact-view-controller | CNContactPickerViewController present; CNContactViewController for a contact | P4 |
| CryptoTokenKit | IT | watcher | port secure-element-tokens assertion; TKSmartCard slot manager (no readers: assert empty); TKTokenKeychainContents | P8 |
| DeviceActivity | I | center-activities | DeviceActivityCenter.startMonitoring schedule -> error without FamilyControls authorization; DeviceActivityReport view | P3 |
| DeviceDiscoveryUI | T | device-picker | add NSApplicationServices to Info.plist so DDDevicePickerViewController's view loads (today only isSupported + init) | P5 |
| EventKit | IWV | authorization-event-recurrence | requestFullAccessToEvents (grant) then save/fetch/remove EKEvent + EKReminder, predicateForEvents; EKEventStoreChanged notification | P4 |
| EventKitUI | IV | edit-view-controller | EKEventViewController / EKCalendarChooser present with an event | P4 |
| ExposureNotification | I | authorization-status | deprecated: ENManager activate -> error | P5 |
| FamilyControls | I | authorization-status | AuthorizationCenter.requestAuthorization(for: .individual) -> entitlement error on sim; FamilyActivityPicker render | P3 |
| FileProvider | IV | domains-identifiers | in-app NSFileProviderReplicatedExtension appex: add domain, enumerate, materialize; NSFileProviderManager signalEnumerator / import | P3 |
| GameKit | ITWV | local-player-leaderboard-objects | GKLocalPlayer.authenticateHandler -> sim without Game Center account: assert the sign-in VC / error; GKLeaderboard.loadLeaderboards / GKAchievement.loadAchievements error paths; GKAccessPoint show/hide; GKMatchRequest / GKMatchmakerViewController build; GKGameCenterViewController present | P2 |
| GroupActivities | ITV | activity-metadata-prepare, activity-sessions, observer | GroupSessionMessenger / GroupSessionJournal objects; SharePlay sessions Apple-sim N/A (no FaceTime): assert no session + activationDisabled | P4 |
| HomeKit | ITWV | manager | HMHomeManager homes + addHome/removeHome (Apple sim: needs iCloud?) - verify on ref-mac; HMAccessoryBrowser (no accessories); HMCharacteristic metadata objects | P5 |
| ImagePlayground | IV | availability | ImageCreator (needs Apple Intelligence) -> assert unavailable error; ImagePlaygroundViewController.isAvailable | P7 |
| Intents | ITWV | preferences-interaction | INInteraction donate/delete; INVoiceShortcutCenter getAllVoiceShortcuts; in-app intent handling (application(_:handlerFor:)) for INSendMessageIntent; INFocusStatusCenter | P7 |
| ManagedSettings | T | store-read-write | assert effective values against the defaults (tvOS has only the read-only default store; no assertion today) | P3 |
| MediaAccessibility | ITV | caption-appearance | MACaptionAppearance copy font/colors, MAAudibleMedia preferred characteristics, MAImageCaptioning set/get on an image file | P1 |
| MetricKit | IV | manager | MXMetricManager.makeLogHandle + mxSignpost, extendLaunchMeasurement(forTaskID:), MXMetricPayload JSON decoding from a fixture | P3 |
| MultipeerConnectivity | ITV | session | two MCPeerIDs in one process: advertiser + browser on loopback, invite/accept, send data/stream/resource (verify on Apple sim) | P8 |
| MusicKit | ITWV | authorization-status | MusicCatalogSearchRequest/MusicDataRequest -> sim: needs developer token/account: assert error type; ApplicationMusicPlayer queue setup, MusicSubscription.current; MusicItemID / Song codable objects | P1 |
| NetworkExtension | IWV | hotspot-helper-objects | port tvOS vpn-relay-managers-settings (NERelayManager, NETunnelProviderManager.loadAll); NEHotspotConfigurationManager.apply -> sim error; NEFilterManager / NEDNSSettingsManager load | P8 |
| NotificationCenter | I | widget-controller | deprecated (Today widgets): NCWidgetProviding - keep minimal | P3 |
| PassKit | IWV | library-payments | PKPaymentRequest build + PKPaymentAuthorizationController present (sim: Apple Pay sandbox sheet); PKAddPassesViewController with a signed test .pkpass (fixture); PKPass parsing; PKIdentityDocument requests (iOS) | P4 |
| Photos | ITV | authorization | PHPhotoLibrary.performChanges: create image/video asset, album, favorite; fetch back (sim has sample photos; authorize via TCC grant); PHImageManager.requestImage / requestAVAsset, PHAssetResourceManager; PHPhotoLibraryChangeObserver delivery | P1 |
| PushKit | IWV | registry | PKPushRegistry desiredPushTypes = [.voIP] -> token (or no token on sim: assert); pushType .fileProvider | P3 |
| QuickLook | IV | preview-controller | QLPreviewController present with a data source (PDF/image) and assert current item / remote view; QLPreviewingController extension | P6 |
| RelevanceKit | TWV | contexts, contexts-widget-relevance | relevance contexts have no assertion: assert Codable/Equatable round trip, WidgetRelevance in a widget extension | P3 |
| ReplayKit | ITV | recorder | RPScreenRecorder startCapture handler (sim: recording works on Apple sim? verify) - assert sample buffers or error; RPSystemBroadcastPickerView; RPPreviewViewController after stopRecording | P1 |
| SensitiveContentAnalysis | IV | policy | SCSensitivityAnalyzer.analyzeImage -> disabled policy answer/error | P7 |
| SharedWithYou | ITV | highlight-center | SWAttributionView render, SWHighlightCenter delegate, SWCollaborationHighlight lookup error | P4 |
| Speech | ITV | recognizer-availability, speech-transcriber-assets | SFSpeechRecognizer on-device recognition of an AVSpeechSynthesizer-generated buffer (SFSpeechAudioBufferRecognitionRequest); SpeechAnalyzer + SpeechTranscriber transcription (asset install may be Apple-sim N/A: verify) | P7 |
| SuggestedActions | V | message | assert message/participant values; iOS: no check | P7 |
| TipKit | ITWV | configure | Tip rules (#Rule with Tips.Event donation, parameters) evaluate shouldDisplay; TipView/TipUIView render, invalidate(reason:); Tips.resetDatastore / showAllTipsForTesting | P3 |
| Translation | I | language-availability | LanguageAvailability.status(from:to:); TranslationSession.translate (assets: verify on Apple sim) | P7 |
| Twitter | I | compose-can-send | deprecated (no Swift module): keep runtime call | P8 |
| VideoSubscriberAccount | ITV | manager | VSAccountManager checkAccessStatus -> sim answer; VSUserAccountManager update | P1 |
| VisionKit | IV | analyzer-scanner-support | ImageAnalyzer.analyze(text image) Live Text when supported; ImageAnalysisInteraction; DataScanner / document camera: Apple-sim N/A (assert isSupported false) | P7 |
| WidgetKit | IV | center | a widget extension in the test app: TimelineProvider timelines via WidgetCenter.currentConfigurations (assert kind present); ControlCenter controls (ControlWidget) reload; render AccessoryWidgetBackground / widget views (port watchOS accessory-background-render) | P3 |
| _RelevanceKit_MapKit | T | poi-category-context | assert RelevantContext.location(category:) non-nil (no assertion today); iOS/watchOS/visionOS: port | P5 |
| _WatchKit_SwiftUI | W | now-playing-view | NowPlayingView: no assertion - assert hosted view hierarchy | P6 |

## (c) Large frameworks with thin coverage of main areas (29 frameworks)

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| AVFoundation | ITWV | assetreader-decoded-pixels-pixel-transfer, assetwriter-asset-imagegen, audio-asset-composition, capture-devices, composition-export-session, player-playback-video-output | AVVideoComposition / custom AVVideoCompositing (CI filter per frame, layer instructions) + export; AVAssetExportSession on tvOS/visionOS (composition-export-session is iOS-only) and export presets / fileLengthLimit / metadata; AVMutableMovie / AVMovie track editing and header write; AVQueuePlayer + AVPlayerLooper, AVPlayerItem seek/rate/stall notifications; HLS from a loopback HTTP server (m3u8 + TS/fMP4 segments), AVAssetResourceLoaderDelegate custom scheme; AVPlayerItem outputs: legible (WebVTT subtitles), metadata (timed ID3), chapters/AVMetadataItem loading; AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer; AVAsset async load(.tracks/.duration/.metadata) across formats (mp4, mov, m4a, caf, wav); capture: Apple-sim N/A (no cameras) - assert AVCaptureDevice.DiscoverySession empty, AVCaptureSession start w/o input errors, authorizationStatus; only audio-asset-composition; add AVAsset/AVPlayer audio playback | P1 |
| AppIntents | ITWV | perform | AppShortcutsProvider registration + AppShortcut phrases; AppEntity/EntityQuery/EntityStringQuery resolution, IntentParameter dialogs; IntentDonationManager donate/delete; AppDependencyManager, OpenIntent / URLRepresentable; ControlWidget toggles (with WidgetKit) | P7 |
| AudioToolbox | ITV | components-extaudiofile | AudioQueue output/input (offline AudioQueueOfflineRender); AudioFileStream parsing of an MP3/AAC byte stream; AUAudioUnit: instantiate Apple effect AUs (AUDelay, AUNBandEQ) and render through AURenderBlock; AUv3 in-process registration; MusicSequence / MusicPlayer with a MIDI file; AudioServicesCreateSystemSoundID / play | P1 |
| Contacts | IWV | authorization-vcard-formatter | with authorization granted (simctl privacy grant equivalent): CNSaveRequest add/update/delete, fetch by predicate, CNChangeHistoryFetchRequest; limited-access (iOS 18) behaviour | P4 |
| CoreLocation | ITWV | manager-geometry-simulated-location | CLLocationUpdate.liveUpdates with simulated location; CLMonitor conditions (circular geographic) enter/exit; CLGeocoder reverse/forward (needs network); CLServiceSession / CLBackgroundActivitySession; heading/beacons: Apple-sim N/A - assert headingAvailable false | P5 |
| CoreMIDI | IV | virtual-loopback | port tvOS event-list-ump (UMP build/parse, MIDI 1<->2 conversion) - virtual endpoints are Apple-sim N/A; MIDINetworkSession (iOS) enable/contacts; MIDICIDiscoveryManager / MIDI-CI profile objects | P1 |
| CoreML | W | arrays-features | MLUpdateTask on-device training (updatable model); MLState stateful models, MLComputePlan; async/batch predictions, MLModelAsset from spec data; port compile-load-predict | P7 |
| CoreSpotlight | IV | index-delete | CSSearchQuery finds the indexed item; CSUserQuery (iOS 18); batch indexing with client state | P4 |
| Foundation | TWV | bundle-localization-stringsdict-plurals, calendar-timezones-locale, filehandle-locks-streams-presenter, filemanager-links-attrs-copy-enumerate, files-urls-processinfo, json-dates-formatters, kvstore-synchronize, nsxpc-anonymous-listener-roundtrip, operationqueue-progress-undo, rename-follows-id, rename-timing, runloop-timer-notification-kvo, ubiquitous-kvstore, userdefaults-appgroup, xpc-missing-service-errors | port iOS-only urlsession-websocket-loopback, urlsession-download-upload-cache, attributed-markdown-formatters, file-coordination-xattr-capacity; background URLSessionConfiguration download (nsurlsessiond); #Predicate / NSPredicate evaluation, FormatStyle breadth; Process-less XPC (covered); NSUserActivity / Handoff | P8 |
| FoundationModels | IV | system-model-availability | x86sim: model .modelNotReady (Apple's iOS sim answers "Pong" via the host Mac) - x86sim gap; @Generable guided generation, Tool calling, streaming responses | P7 |
| GameController | ITV | controllers-keyboard-mouse, input-gamepad, tv-micro-gamepad-event-vc | GCVirtualController (iOS) connect -> appears in GCController.controllers; GCEventInteraction / GCUIEventTypes; controllers-keyboard-mouse has no assertion; input-gamepad is the real check (needs run.sh input mode) | P2 |
| HealthKit | IV | store-units-samples | port watchOS healthd-queries-save (requestAuthorization, save HKQuantitySample, HKSampleQuery, HKStatisticsCollectionQuery); HKAnchoredObjectQuery / HKObserverQuery; HKWorkoutSession on iPhone (iOS 26) + HKLiveWorkoutBuilder; HKMedication / clinical records: Apple-sim N/A | P5 |
| LinkPresentation | ITWV | metadata | LPMetadataProvider fetch from a loopback HTML page (og: tags); LPLinkView render | P6 |
| MapKit | ITWV | geometry-local-objects, snapshotter | MKLocalSearch / MKLocalSearchCompleter (network); MKDirections ETA/route; MKMapView annotations/overlays render on screen (UIKit); MKGeocodingRequest / MKReverseGeocodingRequest (iOS 26); MKLookAroundSceneRequest | P5 |
| Matter | ITWV | setup-payload-codes | MTRDeviceController (storage-based, offline) start/stop; MTR TLV / cluster object model encode/decode (MTRBaseClusterOnOff paths); MTRCertificates generate root/operational certs | P5 |
| MediaPlayer | ITWV | nowplaying-remote-commands | MPMusicPlayerController.applicationQueuePlayer with a store-less queue (sim: empty library) - assert state/notifications; MPMediaLibrary authorization + MPMediaQuery (empty library on sim); MPVolumeView / MPNowPlayingSession (iOS 16+, AVPlayer-backed); MPRemoteCommandCenter skip/seek command dispatch | P1 |
| Metal | ITV | argument-buffer-function-constants-indirect, compute-runtime-compiled, instancing-vertex-descriptor-indexed, msaa-depth-test-resolve, render-to-texture-readback, shared-event-heap-completion-order, textures-mipmaps-blit-formats-srgb, threadgroup-atomics-simdgroup | Metal 4: MTL4CommandQueue/MTL4CommandBuffer/MTL4ArgumentTable/MTL4Compiler (verify Apple-sim support first); ray tracing: acceleration structures + intersection functions (supportsRaytracing on sim: verify); mesh/object shaders, tile shaders/imageblocks (GPU-family dependent); MTLBinaryArchive, dynamic libraries, function pointers / visible function tables; residency sets, MTLIO command queue (file -> buffer loads), counters/timestamps, MTLCaptureManager to file | P2 |
| MetalPerformanceShaders | ITV | blur-matmul | MPSCNN conv/pool/fully-connected inference; MPSImage histogram, Sobel, Lanczos scale, morphology; MPSNDArray matmul, MPSMatrixFindTopK/SoftMax | P2 |
| ModelIO | ITV | mesh-asset-export | MDLAsset import of OBJ/USDA and round trip; MDLNoiseTexture/MDLSkyCubeTexture/normal map generation; MDLVoxelArray, MDLSkeleton/animation, MDLMesh UV unwrapping | P2 |
| PDFKit | ITV | create-annotate-search-roundtrip, document-text-render | PDFView display/pagination/selection on screen, PDFThumbnailView; encrypted PDF unlock, outline, form-field widgets; PDFPageOverlayViewProvider | P6 |
| QuartzCore | ITV | layers-render-animation | CAMetalLayer nextDrawable/present outside MetalKit; CAEmitterLayer, CAReplicatorLayer, CATransformLayer, CAShapeLayer strokeEnd animation sampled via presentation(); CATiledLayer, CATransaction completion blocks | P2 |
| RealityKit | ITV | ecs-system-animation-raycast, entities-meshes, reality-renderer-offscreen | only entities-meshes; port visionOS reality-renderer-offscreen + ecs-system-animation-raycast; physics simulation (PhysicsBodyComponent collisions/CollisionEvents); Entity(named:/contentsOf:) USDZ load, ShaderGraphMaterial, VideoMaterial, particles; SpatialAudioComponent / AudioFileResource playback; LowLevelMesh / LowLevelTexture | P2 |
| SceneKit | ITWV | offscreen-render, scnview-onscreen-continuous | physics contact delegate + hit tests; SCNScene load from .usdz/.scn and SCNSceneSource; SCNAnimation/CAAnimation playback, morphers/skinning; SCNTechnique / shader modifiers / SCNProgram; WKInterfaceSCNScene / SceneView render (no SCNRenderer) | P2 |
| ShazamKit | ITWV | signature-generation | SHSession matching against a custom SHCustomCatalog built from the generated signature; SHLibrary items (iOS 17+); SHManagedSession | P1 |
| StoreKit | ITWV | products-storefront, storefront-sandbox | a .storekit configuration (StoreKit Test in-app via SKTestSession is macOS/Xcode-only): verify what Apple sim answers without it; Transaction.updates / currentEntitlements empty, AppStore.sync error, requestReview (SKStoreReviewController); Product.SubscriptionInfo.status, AppTransaction.shared (sim sandbox); SKAdNetwork / StoreKit external purchase APIs | P4 |
| SwiftData | ITWV | container-insert-fetch-predicate | VersionedSchema + SchemaMigrationPlan; #Index/#Unique, relationships with delete rules; HistoryDescriptor / fetchHistory; ModelActor background context, custom DataStore | P4 |
| SwiftUI | TWV | animation-timing-completion-canvas, depth-geometry3d-glass, image-renderer-layout, layout-stacks-grid-custom-layout-pixels, open-dismiss-immersive-space, open-dismiss-window-volume, tv-focus-state-default-focus, watch-gauges-crown-modifier | controls: Picker/Toggle/Slider/Stepper/DatePicker/TextField editing; presentation: sheet/fullScreenCover/popover/alert/confirmationDialog lifecycle; List swipe actions, ScrollView scrollPosition/ScrollViewReader, Lazy grids; TimelineView, Menu/contextMenu, toolbar; DocumentGroup / FileDocument; drag & drop with Transferable; navigation-state-list is iOS-only | P6 |
| UIKit | V | accessibility-elements-actions-swiftui-tree, attributed-html-import-print-renderer, input-memory-warning, input-shake, pasteboard-text-input, textkit2-vs-textkit1-layout-hit-test, views-autolayout-render-symbols, window-scene-geometry-resize, window-scene-viewcontroller | UIMenu / UIContextMenuInteraction / UIEditMenuInteraction; UISearchController, UIPageViewController, UISheetPresentationController detents; UITextField secure entry/autofill, UIFindInteraction; UIDatePicker/UIColorPickerViewController/UIFontPickerViewController; scene lifecycle (background/foreground, state restoration via NSUserActivity); UITabBarController sidebar (iOS 18 UITab), UIUpdateLink; port iOS collection/table/navigation/alert/scrollview/document/first-responder checks; printing: UIPrintInteractionController (no printers: assert) | P6 |
| UserNotifications | T | settings-schedule-pending | UNNotificationServiceExtension mutating a delivered push (simctl push equivalent); communication notifications (INSendMessageIntent update); badge-only notification delivery/removal (only settings-schedule-pending today) | P3 |

## Apple-sim N/A (verified by SKIP reasons / ref-mac.sh, or hardware-only) (30 frameworks)

Not to be chased; each needs a check asserting what Apple's simulator does (most today SKIP instead of asserting).

| framework | platforms | existing checks | gaps / check ideas | package |
|---|---|---|---|---|
| ARKit | I | configurations | assert ARWorldTrackingConfiguration.isSupported == false (today SKIP) and ARSession run -> error (iOS: no ARKit tracking in Apple's simulator) | P2 |
| AdServices | IV | attribution-token | assert AAAttribution.attributionToken error code 3 (today SKIP); add a check asserting the simulator behaviour (unsupported / proper error); port existing check(s) AdServices.attribution-token (run on I) (attributionToken errors in the simulator) | P4 |
| BackgroundTasks | ITWV | register-submit | BGContinuedProcessingTask request (iOS 26) submit -> unavailable; add a check asserting the simulator behaviour (unsupported / proper error); port existing check(s) BackgroundTasks.register-submit (run on I/T/V); register/submit check (port) (BGTaskScheduler.submit -> .unavailable in Apple's simulator (asserted by register-submit)) | P3 |
| CarKey | IW | - | add a check asserting the simulator behaviour (unsupported / proper error); car key API isSupported -> false (needs Wallet car keys (NFC/UWB)) | P5 |
| CoreBluetooth | ITWV | central-state | assert .unsupported (today SKIP); CBPeripheralManager state (no Bluetooth radio in the simulator) | P5 |
| CoreMotion | IWV | availability | assert availability false (today SKIP) + CMMotionActivityManager/CMPedometer query errors, CMHeadphoneMotionManager isDeviceMotionAvailable (no motion sensors in the simulator) | P5 |
| CoreNFC | I | reading-available | assert readingAvailable == false (today SKIP); NFCTagReaderSession.readingAvailable (no NFC in the simulator) | P5 |
| CoreTelephony | I | network-info | assert serviceSubscriberCellularProviders empty / CTCellularPlanProvisioning.supportsEmbeddedSIM false (no cellular radios in the simulator) | P5 |
| DeclaredAgeRange | I | eligibility | assert no answer / requestAgeRange error (today SKIP after 8 s) (isEligibleForAgeFeatures never answers in Apple's simulator) | P3 |
| DeviceCheck | ITWV | support | assert DCDevice.isSupported == false and generateToken -> featureUnsupported; DCAppAttestService.generateKey -> error (DCDevice / App Attest unsupported in Apple's simulator) | P8 |
| ExternalAccessory | ITV | manager | assert connectedAccessories empty, EAWiFiUnconfiguredAccessoryBrowser (no MFi accessories) | P5 |
| IdentityDocumentServices | I | - | add a check asserting the simulator behaviour (unsupported / proper error); IdentityDocumentProvider registration types / ISO 18013 request objects (mobile ID documents need Wallet IDs (not in the simulator)) | P8 |
| ImageCaptureCore | IV | device-browser | assert no devices + browser start/stop (no cameras/scanners attached) | P5 |
| LinkSecurity | ITWV | flag-urls | add a check asserting the simulator behaviour (unsupported / proper error); port existing check(s) LinkSecurity.flag-urls (run on T); assert no answer / error from LSLinkSecurityManager (today SKIP after 10 s) (flagged-URL store lives in imagent, absent from simulator runtimes) | P3 |
| LockedCameraCapture | IV | - | add a check asserting the simulator behaviour (unsupported / proper error); LockedCameraCaptureManager / session content URLs: requires a capture extension -> assert API availability & error (camera capture extension (no cameras in the simulator)) | P1 |
| MessageUI | IV | can-send | assert canSendMail/canSendText false and composer init behaviour (today SKIP) (no Mail account / Messages in the simulator) | P6 |
| MetalPerformanceShadersGraph | IV | graph-run | keep SKIP; add a check that builds an MPSGraph (no device) and compiles to an executable without running (MPSGraphDevice init aborts in Apple's simulator too) | P2 |
| NearbyInteraction | IW | capabilities | assert capabilities false (today SKIP); NISession run with NINearbyAccessoryConfiguration -> error (no UWB in the simulator) | P5 |
| ProximityReader | I | reader-support | assert PaymentCardReader.isSupported == false, MobileDocumentReader (Tap to Pay needs NFC hardware) | P5 |
| RoomPlan | I | - | add a check asserting the simulator behaviour (unsupported / proper error); assert RoomCaptureSession.isSupported == false; CapturedRoom JSON decoding from fixture (needs LiDAR) | P5 |
| SafetyKit | IW | crash-detection | add a check asserting the simulator behaviour (unsupported / proper error); port existing check(s) SafetyKit.crash-detection (run on W) (Apple-only entitlement) | P5 |
| SecureElementCredential | I | - | add a check asserting the simulator behaviour (unsupported / proper error); credential session isSupported -> false on sim (needs a Secure Element (NFC)) | P8 |
| SensorKit | I | reader-authorization | assert SRSensorReader.requestAuthorization -> entitlement error (research entitlement + sensors) | P5 |
| TelephonyMessagingKit | I | - | add a check asserting the simulator behaviour (unsupported / proper error); messaging types (iOS 27) build; carrier service -> Apple-sim N/A (needs a carrier SIM / telephony) | P3 |
| TouchController | IV | layout-render-touch | assert TCTouchController.isSupported == false (today SKIP), build descriptor/controls offscreen; add a check asserting the simulator behaviour (unsupported / proper error); port existing check(s) TouchController.layout-render-touch (run on I) (TCTouchController.isSupported is false in Apple's simulator) | P2 |
| WatchConnectivity | IWV | session-activate | assert WCSession.isSupported() == false (today SKIP); watch-only app gets no session state; a companion-app setup would be needed for transfer APIs (no paired device (iOS/visionOS); watch-only app on watchOS) | P3 |
| WeatherKit | ITWV | service-answers | add a check asserting the simulator behaviour (unsupported / proper error); port existing check(s) WeatherKit.service-answers (run on T); assert WeatherService error type (today SKIP) (needs a team-signed WeatherKit entitlement; auth service absent in sim runtimes) | P5 |
| WiFiAware | IV | - | add a check asserting the simulator behaviour (unsupported / proper error); WACapabilities / isSupported -> false on sim (no Wi-Fi Aware radio) | P5 |
| _AVKit_GroupActivities | V | - | add a check asserting the simulator behaviour (unsupported / proper error); AVPlayerPlaybackCoordinator with a GroupSession: no FaceTime in sim - assert coordinator objects (needs a SharePlay session (FaceTime)) | P1 |
| _CoreNFC_UIKit | I | - | add a check asserting the simulator behaviour (unsupported / proper error); NFC UIKit overlay build (no NFC in the simulator) | P5 |

## Covered, with secondary gaps

| framework | platforms | secondary gaps |
|---|---|---|
| AVFAudio | ITWV | AVAudioRecorder / input node capture (sim mic input; assert record + file length); AVAudioSequencer + AVAudioUnitSampler (MIDI file render offline); AVAudioSession interruption / route-change notifications, setPreferredSampleRate/IOBufferDuration; AVAudioSourceNode/SinkNode, AVAudioUnitTimePitch/Varispeed in offline render |
| AVKit | T | AVPictureInPictureController: isPictureInPictureSupported, sample-buffer PiP content source (sim supports PiP on iOS); AVRoutePickerView render, AVPlayerViewControllerDelegate full-screen transitions |
| Accelerate | ITWV | BNNS Graph compile/execute, LAPACK solve |
| Accessibility | ITWV | AccessibilityNotification.Announcement post, AXBrailleMap, AXSettings queries |
| AppIntentsTypeSupport | T | port tvOS value-containers to iOS/watchOS/visionOS |
| BackgroundAssets | T | BADownloaderExtension (needs extension) |
| CFNetwork | ITWV | URLSessionStreamTask, HTTP/2 to loopback TLS, proxy (connectionProxyDictionary), CFHTTPMessage |
| CarPlay | I | CPTemplateApplicationScene in CarPlay simulator window (Apple sim has I/O > External Displays > CarPlay) |
| Charts | ITWV | SectorMark pie, chart selection/scroll APIs, Chart3D (visionOS) |
| CompositorServices | V | LayerRenderer drawable depth/stereo views, foveation config (visionOS) |
| CoreAudioKit | IV | CABTMIDILocalPeripheralViewController / CAInterAppAudio views: Apple-sim N/A (no BT), assert view loads |
| CoreData | ITWV | NSPersistentCloudKitContainer local mirror setup (no account: assert event/error); NSStagedMigrationManager / lightweight + custom migration stages; composite attributes, derived attributes, NSPersistentStoreCoordinator with multiple stores; NSFetchRequest async (NSAsynchronousFetchRequest) + child contexts |
| CoreGraphics | ITWV | CGPDFDocument parsing/scanning (CGPDFScanner), CGImageSource-less JPEG via CGDataProvider, shading/patterns |
| CoreHaptics | ITV | engine: Apple-sim N/A (pattern API covered); AHAP file parse |
| CoreImage | ITV | CIRAWFilter / CIImage from HEIF/RAW, CIImageProcessorKernel, custom CIKernel (Metal) at runtime; CIDetector face/text (Vision-backed: verify on Apple sim) |
| CoreLocationUI | IW | LocationButton tap -> one-time authorization (input) |
| CoreMIDI | T | MIDINetworkSession (iOS) enable/contacts; MIDICIDiscoveryManager / MIDI-CI profile objects |
| CoreML | ITV | MLUpdateTask on-device training (updatable model); MLState stateful models, MLComputePlan; async/batch predictions, MLModelAsset from spec data |
| CoreMedia | ITWV | CMSimpleQueue/CMBufferQueue, CMTimebase rates & timers, CMMemoryPool |
| CoreTransferable | ITWV | FileRepresentation / DataRepresentation import/export |
| CreateMLComponents | ITWV | classifier pipeline + serialization |
| CryptoKit | ITWV | SecureEnclave keys: assert SecureEnclave.isAvailable on sim (verify); ML-KEM / ML-DSA (iOS 26) |
| CryptoTokenKit | WV | TKSmartCard slot manager (no readers: assert empty); TKTokenKeychainContents |
| DeveloperToolsSupport | T | port tvOS design-time-values-library to iOS/watchOS/visionOS |
| ExtensionFoundation | T | port tvOS extension-point-monitor to iOS/watchOS/visionOS; AppExtensionProcess launch of an in-app appex |
| Foundation | I | background URLSessionConfiguration download (nsurlsessiond); #Predicate / NSPredicate evaluation, FormatStyle breadth; Process-less XPC (covered); NSUserActivity / Handoff |
| GLKit | IT | GLKView/GLKBaseEffect draw (iOS/tvOS) |
| GSS | IV | Kerberos auth needs a KDC (not available) |
| GameplayKit | ITV | GKAgent/GKGoal/GKBehavior steering; GKMinmaxStrategist / GKMonteCarloStrategist; GKRuleSystem, GKEntity/GKComponentSystem, GKQuadtree/GKRTree |
| HealthKit | W | HKAnchoredObjectQuery / HKObserverQuery; HKMedication / clinical records: Apple-sim N/A |
| IOSurface | ITV | IOSurface sharing to Metal texture + CVPixelBuffer (partly via CoreVideo check) |
| ImmersiveMediaSupport | V | port visionOS video-frame-fade-command to iOS; ImmersiveMediaRemotePreviewSender/VenueDescriptor/presentation commands JSON |
| JavaScriptCore | ITV | JSExport ObjC class bridging, JSVirtualMachine across contexts |
| LiveCommunicationKit | IWV | ConversationManager.reportNewIncomingConversation + actions |
| LocalAuthentication | IWV | LAContext evaluatePolicy with simulated enrolled biometry (input-biometric needs run.sh input mode); LARight / LAPersistedRight (iOS 16+) |
| MediaIntelligence | T | port tvOS face-group-analyzer to iOS/visionOS |
| MediaIntents | TV | port audio-search-codable to iOS/watchOS |
| MediaToolbox | ITV | MTAudioProcessingTap is the main API - fine; MTRegisterProfessionalVideoWorkflowFormatReaders |
| Messages | I | MSMessagesAppViewController (needs iMessage extension) |
| MetalKit | ITV | MTKMesh from MDLAsset with custom vertex descriptor; port mtkview-draw-loop-on-screen (iOS-only) |
| MusicUnderstanding | T | port tvOS click-track-loudness-rhythm to iOS/watchOS/visionOS |
| NaturalLanguage | ITWV | NLEmbedding / NLContextualEmbedding (assets); NLModel from a CreateML text classifier |
| Network | ITWV | NWProtocolWebSocket client/server on loopback; QUIC (NWProtocolQUIC) loopback; NWProtocolFramer custom framing; NWConnectionGroup multicast; Swift NetworkConnection/NetworkListener API (iOS 26) |
| NetworkExtension | T | NEHotspotConfigurationManager.apply -> sim error; NEFilterManager / NEDNSSettingsManager load |
| NowPlaying | T | port tvOS media-session-primary to iOS/watchOS/visionOS |
| OSLog | ITWV | OSLogStore position filtering, signpost entries (OSLogEntrySignpost) |
| OpenAL | IT | playback with alSourcePlay + state polling, 3D listener/source positions |
| PHASE | ITV | port visionOS spatial-sound-event-playback (engine-only today); PHASEOccluder/material, ambient mixer |
| PencilKit | IV | PKCanvasView drawing via touch input |
| PhotosUI | ITWV | iOS presents picker; tvOS/watchOS/visionOS only build views - assert selection via PhotosPickerItem loadTransferable; PHPickerViewController delegate result handling |
| QuickLookThumbnailing | IV | thumbnails for PDF/movie/text types |
| RealityFoundation | ITV | no RealityFoundation check id (re-exported by RealityKit; exercised in RealityKit checks) |
| SafariServices | IV | SFAuthenticationSession deprecated; SSReadingList add (iOS) |
| Security | ITWV | SecKey RSA/EC sign/verify/encrypt (SecKeyCreateSignature); SecAccessControl with .biometryAny (sim enrolled); shared web credentials |
| SecurityUI | T | port tvOS certificate-sheet to iOS/watchOS/visionOS |
| SoundAnalysis | ITWV | SNClassifySoundRequest on a file (SNAudioFileAnalyzer), custom MLModel request |
| SpriteKit | ITWV | SKView onscreen frame loop (iOS/tvOS covered via _SpriteKit_SwiftUI); SKEmitterNode, SKShader, SKTileMapNode, SKTextureAtlas |
| SwiftUI | I | controls: Picker/Toggle/Slider/Stepper/DatePicker/TextField editing; presentation: sheet/fullScreenCover/popover/alert/confirmationDialog lifecycle; List swipe actions, ScrollView scrollPosition/ScrollViewReader, Lazy grids; TimelineView, Menu/contextMenu, toolbar; DocumentGroup / FileDocument; drag & drop with Transferable |
| SystemConfiguration | ITV | SCNetworkReachability callbacks, CNCopyCurrentNetworkInfo (entitlement) |
| TabularData | ITWV | JSON read/write, joins, summaries |
| UIKit | ITW | UIMenu / UIContextMenuInteraction / UIEditMenuInteraction; UISearchController, UIPageViewController, UISheetPresentationController detents; UITextField secure entry/autofill, UIFindInteraction; UIDatePicker/UIColorPickerViewController/UIFontPickerViewController; scene lifecycle (background/foreground, state restoration via NSUserActivity); UITabBarController sidebar (iOS 18 UITab), UIUpdateLink; printing: UIPrintInteractionController (no printers: assert) |
| USDKit | ITV | _USDKit_RealityKit: convert a USD stage to RealityKit entities |
| UserNotifications | IWV | UNNotificationServiceExtension mutating a delivered push (simctl push equivalent); communication notifications (INSendMessageIntent update) |
| VideoToolbox | ITV | VTPixelRotationSession / VTPixelTransferSession (check covers transfer via AVFoundation); VTCompressionSession multi-pass, ProRes (Apple-sim: verify); VTFrameProcessor (frame-rate conversion, super-resolution) - likely Apple-sim N/A, assert isSupported |
| Vision | ITWV | face rectangles/landmarks, person segmentation, body/hand pose, foreground mask (many fail on Apple sim: "no inference context" - verify each with ref-mac first); VNTranslationalImageRegistration / optical flow; only swift-requests-rectangles-contours |
| WebKit | IV | WKContentRuleListStore compile + block; WKDownload, WKFindInteraction; WKWebsiteDataStore fetch/remove records, IndexedDB/service workers; WKWebExtension (iOS 18.4+) |
| WidgetKit | W | a widget extension in the test app: TimelineProvider timelines via WidgetCenter.currentConfigurations (assert kind present); ControlCenter controls (ControlWidget) reload |
| WorkoutKit | IW | WorkoutScheduler.schedule on iOS (authorization); WorkoutPlan export to file |
| _SwiftData_CoreData | T | port managed-object-model to iOS/watchOS/visionOS |
| _SwiftData_SwiftUI | T | port query-in-hosted-view to iOS/watchOS/visionOS |

## Work packages

Size = framework x platform entries with status none / trivial / thin / apple-sim-na; est. checks = new or reworked checks (one per none/trivial framework, one per uncovered area of a thin one, 1/2 for turning an Apple-sim-N/A SKIP into an assertion; ports count once).

| package | frameworks | entries | est. checks | platforms | none / trivial / thin / sim-N/A |
|---|---|---|---|---|---|
| P1 Media & AV | 25 | 69 | 44 | ITWV | 13 / 8 / 5 / 2 |
| P2 Graphics, 3D, AR & games | 25 | 60 | 44 | ITWV | 15 / 2 / 7 / 3 |
| P3 App extensions, system services, communication & parental controls | 40 | 87 | 41 | ITWV | 26 / 14 / 1 / 5 |
| P4 Data, cloud, contacts/calendars & commerce | 31 | 69 | 40 | ITWV | 17 / 10 / 4 / 1 |
| P5 Health, home, location, sensors & accessories | 37 | 82 | 44 | ITWV | 15 / 5 / 4 / 15 |
| P6 UI frameworks depth & platform UI | 12 | 26 | 26 | ITWV | 5 / 2 / 4 / 1 |
| P7 ML, Apple Intelligence, App Intents/Siri, vision, speech & language | 29 | 83 | 36 | ITWV | 22 / 7 / 3 / 0 |
| P8 Foundation, networking, security, identity & device management | 27 | 49 | 28 | ITWV | 17 / 7 / 1 / 3 |

### P1 Media & AV

AVFoundation editing/export depth (AVVideoComposition + custom compositor, export on tvOS/visionOS, AVMutableMovie, HLS from a loopback server, resource loader, legible/metadata outputs, sample-buffer renderers + synchronizer); AudioToolbox (AudioQueue offline render, AudioFileStream, AUAudioUnit instantiate+render, MusicSequence); CoreAudio HAL property queries; Photos library writes/fetches (sim has sample photos); MediaPlayer/MusicKit player + library (empty-library assertions); ShazamKit custom-catalog match; ports: MusicUnderstanding, NowPlaying, MediaIntents, CoreMIDI UMP, PHASE spatial, ImmersiveMediaSupport.

- **thin**: AVFoundation [ITWV], AudioToolbox [ITV], CoreMIDI [IV], MediaPlayer [ITWV], ShazamKit [ITWV]
- **trivial**: AVKit [IV], AVRouting [TV], AssetsLibrary [I], MediaAccessibility [ITV], MusicKit [ITWV], Photos [ITV], ReplayKit [ITV], VideoSubscriberAccount [ITV]
- **none**: AVKit [W], AVRouting [I], CoreAudio [ITWV], CoreMIDI [W], ImmersiveMediaSupport [I], MediaIntents [IW], MusicUnderstanding [IWV], NowPlaying [IWV], _AVKit_SwiftUI [WV], _CoreHaptics_AudioToolbox [V], _MusicKit_SwiftUI [ITWV], _PhotosUI_SwiftUI [IWV], _PhotosUI_WidgetKit [IV]
- **Apple-sim N/A**: LockedCameraCapture [IV], _AVKit_GroupActivities [V]

### P2 Graphics, 3D, AR & games

Metal 4 / ray tracing / mesh + tile shaders / binary archives / residency sets / MTLIO (verify each feature on Apple's sim first: GPU-family limits); MPS CNN + image kernels; QuartzCore CAMetalLayer/emitter/replicator; SceneKit physics/loading/animation; ModelIO import + texture generation; RealityKit physics, USDZ load, audio, LowLevelMesh (and port visionOS renderer/ECS checks to iOS/tvOS); GameKit sim-account behaviour; GameplayKit agents/strategists/rules; visionOS ARKit providers inside the ImmersiveSpace; new ComputeGraph, TabletopKit, GameSave, MetalPerformancePrimitives (shader-only header lib).

- **thin**: GameController [ITV], Metal [ITV], MetalPerformanceShaders [ITV], ModelIO [ITV], QuartzCore [ITV], RealityKit [ITV], SceneKit [ITWV]
- **trivial**: ARKit [V], GameKit [ITWV]
- **none**: ComputeGraph [ITV], GameSave [IV], MetalPerformancePrimitives [ITV], OpenGLES [V], QuartzCore [W], TabletopKit [V], _GameController_SwiftUI [ITV], _RealityKit_ComputeGraph [ITV], _RealityKit_SwiftUI [I], _SceneKit_SwiftUI [WV], _SpriteKit_SwiftUI [WV], _TabletopKit_GroupActivities [V], _TabletopKit_RealityKit [V], _TabletopKit_SwiftUI [V], _USDKit_RealityKit [ITV]
- **Apple-sim N/A**: ARKit [I], MetalPerformanceShadersGraph [IV], TouchController [IV]

### P3 App extensions, system services, communication & parental controls

Needs harness work: a widget extension (WidgetKit timelines, ActivityKit Live Activities with NSSupportsLiveActivities, ControlWidget), an ExtensionKit appex (AppExtensionPoint discovery + EXHostViewController), a File Provider appex, Info.plist keys (BAAppGroupID, NSAccessorySetupKitSupports). Then TipKit rules/events, AlarmKit scheduling, CallKit incoming-call report, MetricKit log handles + payload fixtures, PushKit/PushToTalk behaviour, BrowserEngineKit/Core entitlement errors, Screen Time family (FamilyControls/ManagedSettings/DeviceActivity/PermissionKit) sim behaviour.

- **thin**: UserNotifications [T]
- **trivial**: ActivityKit [I], AlarmKit [I], BackgroundAssets [I], CallKit [IWV], DeviceActivity [I], FamilyControls [I], FileProvider [IV], ManagedSettings [T], MetricKit [IV], NotificationCenter [I], PushKit [IWV], RelevanceKit [TWV], TipKit [ITWV], WidgetKit [IV]
- **none**: AccessoryLiveActivities [I], AppClip [I], AppMigrationKit [I], BackgroundAssets [V], BrowserEngineCore [ITWV], BrowserEngineKit [ITWV], BrowserKit [IWV], BusinessChat [I], DeviceActivity [W], ExtensionFoundation [IWV], ExtensionKit [ITWV], FamilyControls [W], FileProviderUI [IV], ManagedSettings [IW], ManagedSettingsUI [I], MetricKit [T], PermissionKit [IV], PushToTalk [I], RelevanceKit [I], ScreenTime [I], StateReporting [I], SystemExtensions [I], UserNotificationsUI [ITWV], _DeviceActivity_SwiftUI [I], _PermissionKit_SwiftUI [IV], _PermissionKit_UIKit [IV]
- **Apple-sim N/A**: BackgroundTasks [ITWV], DeclaredAgeRange [I], LinkSecurity [ITWV], TelephonyMessagingKit [I], WatchConnectivity [IWV]

### P4 Data, cloud, contacts/calendars & commerce

CloudKit local API (CKRecord/CKShare/CKQuery/CKSyncEngine state) + server errors; CoreData CloudKit mirror setup and staged migrations; SwiftData migrations/history/ModelActor; CoreSpotlight query; Contacts/EventKit store writes after a TCC grant; StoreKit transaction/sync/review paths; PassKit payment sheet + .pkpass; AdAttributionKit / MarketplaceKit / FinanceKit answers; port SwiftData/CoreData/StoreKit SwiftUI overlay checks from tvOS.

- **thin**: Contacts [IWV], CoreSpotlight [IV], StoreKit [ITWV], SwiftData [ITWV]
- **trivial**: AdSupport [IT], AddressBookUI [I], AppTrackingTransparency [ITV], CloudKit [ITWV], ContactsUI [IV], EventKit [IWV], EventKitUI [IV], GroupActivities [ITV], PassKit [IWV], SharedWithYou [ITV]
- **none**: AdAttributionKit [I], ContactProvider [I], CoreSpotlight [T], FinanceKit [IW], FinanceKitUI [I], MarketplaceKit [I], SharedWithYouCore [T], _AdAttributionKit_StoreKit [I], _CoreData_CloudKit [IWV], _GroupActivities_SwiftUI [V], _GroupActivities_UIKit [IV], _MarketplaceKit_UIKit [I], _PassKit_SwiftUI [WV], _StoreKit_SwiftUI [IWV], _SwiftData_CoreData [IWV], _SwiftData_SwiftUI [IWV], iAd [I]
- **Apple-sim N/A**: AdServices [IV]

### P5 Health, home, location, sensors & accessories

HealthKit store save/query on iOS/visionOS (port the watchOS healthd check), anchored/observer/statistics-collection queries, iPhone workout sessions; CoreLocation liveUpdates/CLMonitor/geocoder; MapKit search/directions/MKMapView overlays; HomeKit home add/remove (verify on Apple first); Matter controller/TLV/certs; most of the Apple-sim N/A list (Bluetooth, NFC, UWB, motion, accessories, RoomPlan, WiFiAware, CarKey...) where the work is turning SKIPs into assertions of the unsupported answer.

- **thin**: CoreLocation [ITWV], HealthKit [IV], MapKit [ITWV], Matter [ITWV]
- **trivial**: AccessorySetupKit [I], DeviceDiscoveryUI [T], ExposureNotification [I], HomeKit [ITWV], _RelevanceKit_MapKit [T]
- **none**: AccessoryNotifications [I], AccessoryTransportExtension [I], DeviceDiscoveryExtension [IV], DeviceDiscoveryUI [I], EnergyKit [ITWV], HealthKitUI [W], HomeExtensions [I], MatterSupport [ITWV], VisionEntitlementServices [V], _CoreLocationUI_SwiftUI [IW], _DeviceDiscoveryUI_SwiftUI [I], _HomeKit_SwiftUI [ITWV], _MapKit_SwiftUI [WV], _RelevanceKit_MapKit [IWV], _WorkoutKit_SwiftUI [IW]
- **Apple-sim N/A**: CarKey [IW], CoreBluetooth [ITWV], CoreMotion [IWV], CoreNFC [I], CoreTelephony [I], ExternalAccessory [ITV], ImageCaptureCore [IV], NearbyInteraction [IW], ProximityReader [I], RoomPlan [I], SafetyKit [IW], SensorKit [I], WeatherKit [ITWV], WiFiAware [IV], _CoreNFC_UIKit [I]

### P6 UI frameworks depth & platform UI

UIKit (menus/context menus, search controller, page VC, sheet detents, pickers, scene lifecycle, UITab sidebar; port the iOS UIKit set to visionOS); SwiftUI controls/presentations/lists/scroll/grid/DocumentGroup/drag-drop on all platforms; PDFKit PDFView + encryption; QuickLook presentation; LinkPresentation metadata fetch from loopback; WebKit content rules / downloads / data store; small overlays (_QuickLook_SwiftUI, _DataDetection_SwiftUI).

- **thin**: LinkPresentation [ITWV], PDFKit [ITV], SwiftUI [TWV], UIKit [V]
- **trivial**: QuickLook [IV], _WatchKit_SwiftUI [W]
- **none**: ClockKit [I], DeveloperToolsSupport [IWV], _DataDetection_SwiftUI [IWV], _QuickLook_SwiftUI [IV], _WebKit_SwiftUI [V]
- **Apple-sim N/A**: MessageUI [IV]

### P7 ML, Apple Intelligence, App Intents/Siri, vision, speech & language

FoundationModels: x86Sim gap - Apple's iOS simulator answers via the host Mac (check PASSes "Pong" on ref-mac), x86Sim reports modelNotReady; then guided generation/tools/streaming. App Intents depth (AppShortcutsProvider, EntityQuery, donations) + all the _X_AppIntents overlays; Intents donations/voice shortcuts; Speech recognition of a synthesized buffer + SpeechAnalyzer; Translation sessions; CoreML training/state; Vision face/pose/segmentation (many fail on Apple's sim too: verify first); NaturalLanguage embeddings; VisionKit ImageAnalyzer.

- **thin**: AppIntents [ITWV], CoreML [W], FoundationModels [IV]
- **trivial**: ImagePlayground [IV], Intents [ITWV], SensitiveContentAnalysis [IV], Speech [ITV], SuggestedActions [V], Translation [I], VisionKit [IV]
- **none**: AppIntentsTypeSupport [IWV], FoundationModels [TW], IntentsUI [T], MediaIntelligence [IV], SuggestedActions [I], Translation [TWV], TranslationUIProvider [I], _AppIntents_HealthKit [ITWV], _AppIntents_SwiftUI [IWV], _AppIntents_UIKit [IWV], _Contacts_AppIntents [ITWV], _CoreSpotlight_FoundationModels [IV], _FinanceKit_AppIntents [I], _FoundationModels_UIKit [IV], _GeoToolbox_AppIntents [ITWV], _LinkPresentation_AppIntents [ITWV], _MediaIntents_AppIntents [ITWV], _MediaPlayer_AppIntents [ITWV], _NowPlaying_AppIntents [ITWV], _Photos_AppIntents [ITV], _Translation_SwiftUI [IV], _UserNotifications_AppIntents [ITWV]

### P8 Foundation, networking, security, identity & device management

Foundation: port the 4 iOS-only checks (websocket, download/upload/cache, markdown formatters, file coordination) to tvOS/watchOS/visionOS + background URLSession; Network QUIC/WebSocket/framer/NetworkConnection; NetworkExtension managers (port tvOS check); Security SecKey ops; AuthenticationServices passkey/ASWebAuthenticationSession loopback callback; LocalAuthentication on tvOS + LARight; CryptoTokenKit SE tokens on iOS/tvOS; DeviceCheck unsupported assertions; MultipeerConnectivity two-peer loopback; device management (ManagedApp port, ManagedAppDistribution, AutomatedDeviceEnrollment, ClassKit).

- **thin**: Foundation [TWV]
- **trivial**: Accounts [I], AuthenticationServices [ITWV], ClassKit [I], CryptoTokenKit [IT], MultipeerConnectivity [ITV], NetworkExtension [IWV], Twitter [I]
- **none**: AutomatedDeviceEnrollment [I], AutomaticAssessmentConfiguration [V], ClassKit [V], ClassKitUI [IV], IdentityDocumentServicesUI [I], IdentityLookupUI [IV], LocalAuthentication [T], LocalAuthenticationEmbeddedUI [IV], ManagedApp [I], ManagedAppDistribution [IV], SecurityUI [IWV], ServicesAccountLinking [I], TrustInsights [IV], _AuthenticationServices_SwiftUI [WV], _ManagedAppDistribution_SwiftUI [V], _SecureElementCredential_SwiftUI [I], _SecureElementCredential_UIKit [I]
- **Apple-sim N/A**: DeviceCheck [ITWV], IdentityDocumentServices [I], SecureElementCredential [I]

