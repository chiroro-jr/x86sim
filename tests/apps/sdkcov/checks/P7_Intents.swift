// sdkcov P7: App Intents and SiriKit. AppIntents in-process (entities, string / enumerable queries, AppEnum, OpenIntent,
// IntentDialog results, @AppDependency, AppShortcutsProvider, donations), the _X_AppIntents overlays (entity identifiers
// on notifications / Now Playing content / MPAppEntityIdentifier, system intent values of PlaceDescriptor, LinkMetadata,
// AudioSearch, PHAsset, workout audio contexts, CNPostalAddressEntity, ReceiptTransactionEntity), AppIntentsTypeSupport,
// the SwiftUI / UIKit App Intents overlays, Intents (interactions, voice shortcuts, focus status) and IntentsUI.
// The app has no Metadata.appintents (build.sh has no appintentsmetadataprocessor step): what needs the extracted metadata
// (donations, App Shortcut registration with the system) asserts what Apple's simulator answers for such an app.
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppIntents)
import AppIntents
#endif
#if canImport(AppIntentsTypeSupport)
import AppIntentsTypeSupport
#endif
#if canImport(Intents)
import Intents
#endif
#if canImport(IntentsUI) && !os(watchOS)
import IntentsUI
#endif
#if canImport(_AppIntents_SwiftUI)
import _AppIntents_SwiftUI
#endif
#if canImport(_AppIntents_UIKit)
import _AppIntents_UIKit
#endif
#if canImport(_AppIntents_HealthKit) && canImport(HealthKit)
import HealthKit
import _AppIntents_HealthKit
#endif
#if canImport(_UserNotifications_AppIntents)
import UserNotifications
import _UserNotifications_AppIntents
#endif
#if canImport(_NowPlaying_AppIntents)
import NowPlaying
import _NowPlaying_AppIntents
#endif
#if canImport(_MediaPlayer_AppIntents)
import _MediaPlayer_AppIntents
#endif
#if canImport(_GeoToolbox_AppIntents)
import CoreLocation
import GeoToolbox
import _GeoToolbox_AppIntents
#endif
#if canImport(_LinkPresentation_AppIntents)
import LinkPresentation
import _LinkPresentation_AppIntents
#endif
#if canImport(_MediaIntents_AppIntents)
import MediaIntents
import _MediaIntents_AppIntents
#endif
#if canImport(_Photos_AppIntents)
import Photos
import _Photos_AppIntents
#endif
#if canImport(_Contacts_AppIntents) && canImport(Contacts)
import _Contacts_AppIntents
#endif
#if canImport(_FinanceKit_AppIntents)
import _FinanceKit_AppIntents
#endif

// MARK: helpers

final class P7Box<T>: @unchecked Sendable {
    private let l = NSLock(); private var v: T?
    func set(_ x: T) { l.withLock { if v == nil { v = x } } }
    var value: T? { l.withLock { v } }
    /// the first value set, waiting up to `secs`
    func wait(_ secs: Double) async -> T? {
        let end = Date().addingTimeInterval(secs)
        while Date() < end { if let x = value { return x }; try? await Task.sleep(for: .milliseconds(30)) }
        return value
    }
}
/// `body`'s answer, or nil when it does not answer in `secs` (the task is cancelled)
func p7Within<T: Sendable>(_ secs: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T? {
    let b = P7Box<Result<T, Error>>()
    let t = Task { do { b.set(.success(try await body())) } catch { b.set(.failure(error)) } }
    guard let r = await b.wait(secs) else { t.cancel(); return nil }
    return try r.get()
}
/// "Domain code" of an error
func p7Err(_ e: Error) -> String { let n = e as NSError; return "\(n.domain) \(n.code)" }
#if !os(watchOS)
@MainActor func p7Show(_ vc: UIViewController) throws -> () -> Void {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let ws = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { throw Fail("no window scene") }
    let w = UIWindow(windowScene: ws); w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
    w.rootViewController = vc; w.isHidden = false; w.layoutIfNeeded()
    return { w.isHidden = true; w.rootViewController = nil }
}
@MainActor func p7Main<T>(_ f: @MainActor () async throws -> T) async throws -> T { try await f() }
@MainActor func p7Subviews(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap { p7Subviews($0) } }
#endif

// MARK: App Intents types (no macros: the Linux toolchain has no AppIntents macro plugin)

#if canImport(AppIntents)
struct P7Book: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Book", numericFormat: "\(placeholder: .int) books") }
    static var defaultQuery: P7BookQuery { P7BookQuery() }
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "book \(id)") }
    static let shelf = [P7Book(id: "b1", title: "Dune"), P7Book(id: "b2", title: "Emma"), P7Book(id: "b3", title: "Dracula")]
}
struct P7BookQuery: EntityStringQuery, EnumerableEntityQuery {
    func entities(for identifiers: [String]) async throws -> [P7Book] { P7Book.shelf.filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [P7Book] { P7Book.shelf.filter { $0.title.localizedCaseInsensitiveContains(string) } }
    func allEntities() async throws -> [P7Book] { P7Book.shelf }
    func suggestedEntities() async throws -> [P7Book] { Array(P7Book.shelf.prefix(2)) }
}
enum P7Genre: String, AppEnum {
    case poetry, prose
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Genre" }
    static var caseDisplayRepresentations: [P7Genre: DisplayRepresentation] { [.poetry: "Poetry", .prose: DisplayRepresentation(title: "Prose", subtitle: "long form")] }
}
final class P7Library: @unchecked Sendable {
    static let shared = P7Library()
    private let l = NSLock(); private var opened: [String] = []
    func open(_ id: String) { l.withLock { opened.append(id) } }
    var log: [String] { l.withLock { opened } }
}
struct P7OpenBookIntent: OpenIntent {
    static var title: LocalizedStringResource { "Open book" }
    static var description: IntentDescription { IntentDescription("Opens a book of the sdkcov shelf", categoryName: "Books") }
    @IntentParameter(title: "Book") var target: P7Book
    @IntentParameter(title: "Genre", default: .prose) var genre: P7Genre
    @IntentParameter(title: "Pages", default: 3) var pages: Int
    init() {}
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        P7Library.shared.open(target.id)
        return .result(value: "\(target.title):\(genre.rawValue):\(pages)", dialog: IntentDialog(full: "Opened \(target.title)", supporting: "Opened"))
    }
}
struct P7CountIntent: AppIntent {
    static var title: LocalizedStringResource { "Count books" }
    static var openAppWhenRun: Bool { false }
    init() {}
    func perform() async throws -> some IntentResult & ReturnsValue<Int> { .result(value: P7Book.shelf.count) }
}
struct P7FailIntent: AppIntent {
    static var title: LocalizedStringResource { "Fail" }
    init() {}
    func perform() async throws -> some IntentResult {
        if P7Book.shelf.count > 0 { throw P7IntentError.noShelf }
        return .result()
    }
}
enum P7IntentError: Error, CustomLocalizedStringResourceConvertible {
    case noShelf
    var localizedStringResource: LocalizedStringResource { "No shelf" }
}
struct P7Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: P7CountIntent(), phrases: ["Count books in \(.applicationName)", "How many books in \(.applicationName)"], shortTitle: "Count books", systemImageName: "books.vertical")
        AppShortcut(intent: P7OpenBookIntent(), phrases: ["Open a book in \(.applicationName)"], shortTitle: "Open book", systemImageName: "book")
    }
    static var shortcutTileColor: ShortcutTileColor { .teal }
}
#endif
#if canImport(_AppIntents_UIKit) && !os(watchOS)
final class P7IntentsDS: NSObject, UICollectionViewAppIntentsDataSource {
    var asked = 0
    func collectionView(_ collectionView: UICollectionView, appEntityIdentifierForItemAt indexPath: IndexPath) -> EntityIdentifier? {
        asked += 1
        return EntityIdentifier(for: P7Book.self, identifier: P7Book.shelf[indexPath.item % 3].id)
    }
}
#endif

extension Registry {
    static var p7_intents: [Check] {
        var c: [Check] = []
        #if canImport(AppIntents)
        c.append(check("AppIntents", "entities-queries-enums") {
            let q = P7Book.defaultQuery
            let byId = try await q.entities(for: ["b2", "b9"]).map(\.title)
            let match = try await q.entities(matching: "dr").map(\.title)
            let all = try await q.allEntities().count, sugg = try await q.suggestedEntities().count
            try expect(byId == ["Emma"] && match == ["Dracula"] && all == 3 && sugg == 2, "query: \(byId) \(match) \(all) \(sugg)")
            let tdr = P7Book.typeDisplayRepresentation
            try expect(String(localized: tdr.name) == "Book", "type name \(String(localized: tdr.name))")
            let dr = P7Book.shelf[0].displayRepresentation
            try expect(String(localized: dr.title) == "Dune" && dr.subtitle.map { String(localized: $0) } == "book b1", "display \(dr)")
            try expect(P7Genre.allCases.count == 2 && String(localized: P7Genre.caseDisplayRepresentations[.prose]!.title) == "Prose", "AppEnum")
            let eid = EntityIdentifier(for: P7Book.shelf[1])
            try expect(eid.identifier == "b2" && eid.entityType == P7Book.self && eid == EntityIdentifier(for: P7Book.self, identifier: "b2"), "entity identifier \(eid)")
            return "\(eid.description)"
        })
        c.append(check("AppIntents", "open-intent-parameters-dependency-dialog") {
            // @AppDependency values resolve only inside the system's perform flow (a direct perform() traps):
            // registering one is all an in-process check can do
            let lib = P7Library.shared
            AppDependencyManager.shared.add(dependency: lib)
            var i = P7OpenBookIntent()
            i.target = P7Book.shelf[2]
            try expect(i.genre == .prose && i.pages == 3, "parameter defaults \(i.genre) \(i.pages)")
            i.genre = .poetry; i.pages = 7
            let r = try await i.perform()
            try expect(r.value == "Dracula:poetry:7", "value \(String(describing: r.value))")
            try expect(lib.log.last == "b3", "library saw \(lib.log)")
            try expect(String(localized: P7OpenBookIntent.title) == "Open book" && !P7CountIntent.openAppWhenRun, "static metadata")
            // the parameter's metadata: title, and the value it holds
            try expect(String(localized: i.$target.title) == "Book" && i.$target.wrappedValue.id == "b3", "parameter \(i.$target.title)")
            let c = try await P7CountIntent().perform()
            try expect(c.value == 3, "count \(String(describing: c.value))")
            var thrown = "nothing"
            do { _ = try await P7FailIntent().perform() } catch { thrown = "\(error)" }
            try expect(thrown == "noShelf", "error intent threw \(thrown)")
            return "Dracula:poetry:7, dependency registered"
        })
        c.append(check("AppIntents", "app-shortcuts-provider") {
            let s = P7Shortcuts.appShortcuts
            try expect(s.count == 2, "\(s.count) shortcuts")
            P7Shortcuts.updateAppShortcutParameters()   // tells the system to refetch parameter options: no metadata, no answer
            let neg = P7Shortcuts.negativePhrases
            return "\(s.count) shortcuts, tile color \(P7Shortcuts.shortcutTileColor), negative phrases \(type(of: neg))"
        })
        c.append(check("AppIntents", "donations", timeout: 40) {
            var parts: [String] = []
            // Apple's simulator takes the donation without the app's App Intents metadata, and deletes it by identifier
            let id = try await IntentDonationManager.shared.donate(intent: P7CountIntent())
            parts.append("donated")
            let del = try await IntentDonationManager.shared.deleteDonations(matching: .donationIdentifier(id))
            try expect(del == [id], "deleted \(del) for \(id)")
            parts.append("deleted \(del.count)")
            do {
                let del = try await IntentDonationManager.shared.deleteDonations(matching: .intentType(P7CountIntent.self))
                parts.append("delete by type: \(del.count)")
            } catch { parts.append("delete by type: \(String(describing: error).prefix(100))") }
            return parts.joined(separator: "; ")
        })
        #endif
        #if canImport(AppIntentsTypeSupport) && !os(tvOS)   // tvOS: More_tvOS.swift
        c.append(check("AppIntentsTypeSupport", "value-containers") {
            let ex = [3, 4].makeExpression(), _ = "x86sim".makeExpression(), _ = Date(timeIntervalSince1970: 0).makeExpression()
            _ = ex
            let a = AttributedTypeIdentifier(persistentIdentifier: "SDKCovEntity", bundleIdentifier: "com.x86sim.test.sdkcov")
            let e1 = AttributedEntityIdentifier(entityType: a, instanceIdentifier: "1"), e2 = AttributedEntityIdentifier(entityType: a, instanceIdentifier: "2")
            try expect(e1 != e2 && e1 == AttributedEntityIdentifier(entityType: a, instanceIdentifier: "1"), "identifiers")
            try expect(a != AttributedTypeIdentifier(persistentIdentifier: "SDKCovEntity"), "bundle id part of the type identifier")
            return "expressions made"
        })
        #endif
        #if canImport(_UserNotifications_AppIntents)
        c.append(check("_UserNotifications_AppIntents", "content-entity-identifiers") {
            let ids = P7Book.shelf.map { EntityIdentifier(for: $0) }
            let m = UNMutableNotificationContent(); m.badge = 1
            try expect(m.appEntityIdentifiers.isEmpty, "new content has \(m.appEntityIdentifiers.count) identifiers")
            m.appEntityIdentifiers = Array(ids.prefix(2))
            // Apple's 27.2 simulator reads back [] for this app (entity types it cannot resolve without App Intents
            // metadata); whatever it keeps must survive the copy
            let kept = m.appEntityIdentifiers
            try expect(kept.isEmpty || kept.map(\.identifier) == ["b1", "b2"], "read back \(kept)")
            let copy = m.copy() as! UNNotificationContent
            let back = (copy.mutableCopy() as! UNMutableNotificationContent).appEntityIdentifiers
            try expect(back == kept, "after copy \(back) vs \(kept)")
            return "\(kept.count) identifiers kept (Apple's simulator: 0)"
        })
        #endif
        #if canImport(_NowPlaying_AppIntents)
        c.append(check("_NowPlaying_AppIntents", "content-entity-identifiers") {
            var g = GenericContent(id: "np1", title: "sdkcov", type: .audio, duration: nil, artwork: nil)
            try expect(g.appEntityIdentifiers.isEmpty, "new content has \(g.appEntityIdentifiers.count) identifiers")
            g.appEntityIdentifiers = [EntityIdentifier(for: P7Book.shelf[0])]
            try expect(g.appEntityIdentifiers.map(\.identifier) == ["b1"], "read back \(g.appEntityIdentifiers)")
            return g.appEntityIdentifiers[0].description
        })
        #endif
        #if canImport(_MediaPlayer_AppIntents)
        c.append(check("_MediaPlayer_AppIntents", "entity-identifier-secure-coding") {
            guard let m = MPAppEntityIdentifier(entityIdentifier: EntityIdentifier(for: P7Book.shelf[1])) else { throw Fail("MPAppEntityIdentifier(entityIdentifier:) nil") }
            try expect(MPAppEntityIdentifier.supportsSecureCoding, "secure coding")
            let d = try NSKeyedArchiver.archivedData(withRootObject: m, requiringSecureCoding: true)
            guard let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: MPAppEntityIdentifier.self, from: d) else { throw Fail("unarchive nil") }
            try expect(back == m && back.hash == m.hash && (m.copy() as? MPAppEntityIdentifier) == m, "round trip \(back) vs \(m)")
            let other = MPAppEntityIdentifier(entityIdentifier: EntityIdentifier(for: P7Book.shelf[2]))
            try expect(other != m, "different entities equal")
            return "\(d.count) B: \(m.description.prefix(80))"
        })
        #endif
        #if canImport(_GeoToolbox_AppIntents)
        c.append(check("_GeoToolbox_AppIntents", "place-descriptor-intent-value") {
            let p = PlaceDescriptor(representations: [.coordinate(CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.009)), .address("1 Apple Park Way, Cupertino")], commonName: "Apple Park")
            let tn = String(localized: PlaceDescriptor.typeDisplayRepresentation.name)
            let title = String(localized: p.displayRepresentation.title)
            _ = p.makeExpression()
            try expect(!tn.isEmpty && title.contains("Apple Park"), "type '\(tn)', title '\(title)'")
            return "type '\(tn)', title '\(title)'"
        })
        #endif
        #if canImport(_LinkPresentation_AppIntents)
        c.append(check("_LinkPresentation_AppIntents", "link-metadata-intent-value") {
            let m = LinkMetadata(url: URL(string: "https://example.com/sdkcov")!)
            let tn = String(localized: LinkMetadata.typeDisplayRepresentation.name)
            let title = String(localized: m.displayRepresentation.title)
            _ = m.makeExpression()
            try expect(!tn.isEmpty && !title.isEmpty, "type '\(tn)', title '\(title)'")
            return "type '\(tn)', title '\(title)'"
        })
        #endif
        #if canImport(_MediaIntents_AppIntents)
        c.append(check("_MediaIntents_AppIntents", "audio-search-intent-value") {
            let s = AudioSearch(criteria: .searchQuery("x86sim"))
            let tn = String(localized: AudioSearch.typeDisplayRepresentation.name)
            let title = String(localized: s.displayRepresentation.title)
            _ = s.makeExpression()
            try expect(!tn.isEmpty, "type name empty")
            return "type '\(tn)', title '\(title)'"
        })
        #endif
        #if canImport(_Photos_AppIntents)
        c.append(check("_Photos_AppIntents", "asset-intent-value") {
            let tn = String(localized: PHAsset.typeDisplayRepresentation.name)
            try expect(!tn.isEmpty && !PHAsset.persistentIdentifier.isEmpty, "type '\(tn)' id '\(PHAsset.persistentIdentifier)'")
            let r = PHAsset.fetchAssets(with: nil)
            var title = "no asset in the library"
            if let a = r.firstObject { title = "first asset '\(String(localized: a.displayRepresentation.title))'"; _ = a.makeExpression() }
            return "type '\(tn)', persistent id \(PHAsset.persistentIdentifier), \(title)"
        })
        #endif
        #if canImport(_AppIntents_HealthKit) && canImport(HealthKit)
        c.append(check("_AppIntents_HealthKit", "workout-audio-contexts") {
            let run = AudioContext.workout(activityType: .running), hiit = AudioContext.workout(activityType: .highIntensityIntervalTraining)
            try expect(run != AudioContext.nowPlaying && AudioContext.workout != AudioContext.nowPlaying, "workout context equals nowPlaying")
            let lo = AudioContext.WorkoutIntensityLevel.low, hi = AudioContext.WorkoutIntensityLevel.high
            try expect(lo != hi && lo.rawValue < hi.rawValue && AudioContext.WorkoutIntensityLevel(rawValue: hi.rawValue) == hi, "levels \(lo.rawValue) \(hi.rawValue)")
            let walkLevel = AudioContext.WorkoutIntensityLevel(.walking), hiitLevel = AudioContext.WorkoutIntensityLevel(.highIntensityIntervalTraining)
            try expect(AudioContext.workout(intensityLevel: hi) == AudioContext.workout(intensityLevel: hi), "equality")
            return "walking level \(walkLevel.rawValue), HIIT level \(hiitLevel.rawValue), run == hiit \(run == hiit)"
        })
        #endif
        #if canImport(_Contacts_AppIntents) && canImport(Contacts)
        c.append(check("_Contacts_AppIntents", "postal-address-entity-type") {
            // the overlay has no public declarations: its CNPostalAddressEntity (an AppEntity the system uses) is in the image
            guard let t = _typeByName("20_Contacts_AppIntents21CNPostalAddressEntityV") else { throw Fail("no CNPostalAddressEntity type") }
            guard let e = t as? any AppEntity.Type else { throw Fail("\(t) is not an AppEntity") }
            let n = String(localized: e.typeDisplayRepresentation.name)
            try expect(n == "Contacts Postal Address Entity", "name '\(n)'")
            return "\(t): '\(n)'"
        })
        #endif
        #if canImport(_FinanceKit_AppIntents)
        c.append(check("_FinanceKit_AppIntents", "receipt-transaction-entity-type") {
            guard let t = _typeByName("22_FinanceKit_AppIntents24ReceiptTransactionEntityV") else { throw Fail("no ReceiptTransactionEntity type") }
            guard let e = t as? any AppEntity.Type else { throw Fail("\(t) is not an AppEntity") }
            let n = String(localized: e.typeDisplayRepresentation.name)
            try expect(n == "Receipt Transaction", "name '\(n)'")
            return "\(t): '\(n)'"
        })
        #endif
        #if canImport(_AppIntents_SwiftUI) && !os(tvOS)   // tvOS: More_tvOS.swift
        c.append(check("_AppIntents_SwiftUI", "siri-tip-view-shortcuts-link", timeout: 30) {
            #if os(watchOS)
            // watchOS: no UIKit hosting; the view values only
            var visible = true
            let tip = SiriTipView(intent: P7CountIntent(), isVisible: Binding(get: { visible }, set: { visible = $0 }))
            _ = tip.body
            return "SiriTipView built"
            #else
            return try await p7Main { () async throws -> String in
                let v = VStack {
                    SiriTipView(intent: P7CountIntent()).siriTipViewStyle(.dark)
                    ShortcutsLink()
                }.frame(width: 360, height: 300)
                let hc = UIHostingController(rootView: v)
                let done = try p7Show(hc); defer { done() }
                hc.view.layoutIfNeeded()
                try await Task.sleep(for: .seconds(1))
                let names = p7Subviews(hc.view).map { "\(type(of: $0))" }
                let fit = hc.sizeThatFits(in: CGSize(width: 360, height: 1000))
                try expect(fit.width > 50 && fit.height > 20, "size \(fit), \(names.count) views")
                return "size \(fit), \(names.count) views"
            }
            #endif
        })
        #endif
        #if canImport(_AppIntents_UIKit) && !os(tvOS)
        #if os(watchOS)
        c.append(check("_AppIntents_UIKit", "display-image-system-name") {
            guard let img = DisplayRepresentation.Image(systemName: "book", tintColor: .red) else { throw Fail("Image(systemName:tintColor:) nil") }
            let dr = DisplayRepresentation(title: "Dune", image: img)
            try expect(dr.image != nil, "image dropped")
            return "image made"
        })
        #else
        c.append(check("_AppIntents_UIKit", "collection-view-data-source-identifiers") {
            try await onMain {
                let cv = UICollectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), collectionViewLayout: UICollectionViewFlowLayout())
                let ds = P7IntentsDS()
                cv.appIntentsDataSource = ds
                try expect(cv.appIntentsDataSource === ds, "data source not kept")
                let id = ds.collectionView(cv, appEntityIdentifierForItemAt: IndexPath(item: 4, section: 0))
                try expect(id?.identifier == "b2", "identifier \(String(describing: id))")
                let tv = UITableView(); tv.appIntentsDataSource = nil
                guard let img = DisplayRepresentation.Image(systemName: "book", tintColor: .red) else { throw Fail("Image(systemName:tintColor:) nil") }
                _ = DisplayRepresentation(title: "Dune", image: img)
                return "kept, item 4 -> \(id!.description)"
            }
        })
        #endif
        #endif
        #if canImport(Intents)
        c.append(check("Intents", "interaction-donate-delete", timeout: 30) {
            #if os(tvOS)
            // tvOS has no messaging intents: a media intent
            let item = INMediaItem(identifier: "m1", title: "sdkcov song", type: .song, artwork: nil)
            let intent = INPlayMediaIntent(mediaItems: [item], mediaContainer: nil, playShuffled: true, playbackRepeatMode: .none, resumePlayback: false, playbackQueueLocation: .now, playbackSpeed: nil, mediaSearch: nil)
            try expect(intent.mediaItems?.first?.title == "sdkcov song" && intent.playShuffled == true, "intent")
            let resp = INPlayMediaIntentResponse(code: .success, userActivity: nil)
            #else
            let me = INPerson(personHandle: INPersonHandle(value: "me@example.com", type: .emailAddress), nameComponents: nil, displayName: "Me", image: nil, contactIdentifier: nil, customIdentifier: "me", isMe: true)
            let ada = INPerson(personHandle: INPersonHandle(value: "ada@example.com", type: .emailAddress), nameComponents: PersonNameComponents(givenName: "Ada", familyName: "Lovelace"), displayName: "Ada", image: nil, contactIdentifier: nil, customIdentifier: "ada")
            let intent = INSendMessageIntent(recipients: [ada], outgoingMessageType: .outgoingMessageText, content: "hello", speakableGroupName: INSpeakableString(spokenPhrase: "Engines"), conversationIdentifier: "conv-1", serviceName: "sdkcov", sender: me, attachments: nil)
            try expect(intent.recipients?.first?.displayName == "Ada" && intent.conversationIdentifier == "conv-1", "intent")
            let resp = INSendMessageIntentResponse(code: .success, userActivity: nil)
            #endif
            let ia = INInteraction(intent: intent, response: resp)
            ia.groupIdentifier = "sdkcov-p7"; ia.direction = .outgoing; ia.identifier = "p7-1"
            // archive round trip (interactions are NSSecureCoding)
            let d = try NSKeyedArchiver.archivedData(withRootObject: ia, requiringSecureCoding: true)
            guard let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: INInteraction.self, from: d) else { throw Fail("unarchive") }
            #if os(tvOS)
            let same = (back.intent as? INPlayMediaIntent)?.mediaItems?.first?.identifier == "m1"
            #else
            let same = (back.intent as? INSendMessageIntent)?.content == "hello"
            #endif
            try expect(same && back.groupIdentifier == "sdkcov-p7" && back.direction == .outgoing, "round trip")
            let don = P7Box<String>()
            ia.donate { e in don.set(e.map { p7Err($0) } ?? "ok") }
            let dr = await don.wait(15) ?? "no answer"
            // the app declares no intents (Info.plist IntentsSupported / NSUserActivityTypes): Apple answers 1901
            try expect(dr == "ok" || dr == "IntentsErrorDomain 1901", "donate \(dr)")
            let delg = P7Box<String>()
            INInteraction.delete(with: "sdkcov-p7") { e in delg.set(e.map { p7Err($0) } ?? "ok") }
            let dl = await delg.wait(15) ?? "no answer"
            let dela = P7Box<String>()
            INInteraction.deleteAll { e in dela.set(e.map { p7Err($0) } ?? "ok") }
            let da = await dela.wait(15) ?? "no answer"
            return "donate \(dr), delete group \(dl), delete all \(da), \(d.count) B archive"
        })
        #if !os(tvOS)
        c.append(check("Intents", "voice-shortcuts-shortcut", timeout: 30) {
            let act = NSUserActivity(activityType: "com.x86sim.test.sdkcov.activity"); act.title = "sdkcov"
            #if !os(watchOS)
            act.suggestedInvocationPhrase = "Run sdkcov"
            #endif
            // an intent the app does not declare (no IntentsSupported / intent definition) makes no shortcut: nil on Apple's simulator
            let fromIntent = INShortcut(intent: INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: "x", speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil, sender: nil, attachments: nil))
            try expect(fromIntent == nil, "INShortcut(intent:) for an undeclared intent: \(String(describing: fromIntent))")
            let sc = INShortcut(userActivity: act)
            try expect(sc.userActivity?.activityType == act.activityType && sc.intent == nil, "user activity shortcut")
            #if os(iOS) || os(visionOS)
            let all = P7Box<String>()
            INVoiceShortcutCenter.shared.getAllVoiceShortcuts { v, e in all.set(e.map { p7Err($0) } ?? "\(v?.count ?? -1) voice shortcuts") }
            INVoiceShortcutCenter.shared.setShortcutSuggestions([sc, INShortcut(userActivity: act)])
            let r = await all.wait(15) ?? "no answer"
            let rel = INRelevantShortcut(shortcut: sc); rel.shortcutRole = .information
            rel.relevanceProviders = [INDateRelevanceProvider(start: Date(), end: Date().addingTimeInterval(3600))]
            let rb = P7Box<String>()
            INRelevantShortcutStore.default.setRelevantShortcuts([rel]) { e in rb.set(e.map { p7Err($0) } ?? "ok") }
            let rr = await rb.wait(15) ?? "no answer"
            return "\(r); relevant shortcuts \(rr)"
            #else
            let rel = INRelevantShortcut(shortcut: sc); rel.shortcutRole = .action
            let rb = P7Box<String>()
            INRelevantShortcutStore.default.setRelevantShortcuts([rel]) { e in rb.set(e.map { p7Err($0) } ?? "ok") }
            return "relevant shortcuts \(await rb.wait(15) ?? "no answer")"
            #endif
        })
        #endif
        #if os(iOS) || os(watchOS) || os(visionOS)
        c.append(check("Intents", "focus-status-center", timeout: 20) {
            let st = INFocusStatusCenter.default.authorizationStatus
            let fs = INFocusStatusCenter.default.focusStatus.isFocused
            return "focus authorization \(st.rawValue), isFocused \(String(describing: fs)), siri authorization \(INPreferences.siriAuthorizationStatus().rawValue)"
        })
        #endif
        #endif
        #if canImport(IntentsUI) && os(tvOS)
        c.append(check("IntentsUI", "inimage-uiimage") {
            // tvOS IntentsUI: INImage from UIImage / CGImage and back
            let ctx = bitmap(16, 16); ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let ui = UIImage(cgImage: ctx.makeImage()!)
            let a = INImage(uiImage: ui), b = INImage(cgImage: ctx.makeImage()!)
            let got = P7Box<String>()
            a.fetchUIImage { img in got.set(img.map { "\($0.size)" } ?? "nil") }
            let r = await got.wait(10) ?? "no answer"
            try expect(r != "nil" && r != "no answer", "fetchUIImage \(r)")
            _ = b
            return "fetched \(r)"
        })
        #endif
        return c
    }
}
