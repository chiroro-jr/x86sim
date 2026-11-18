// SDK coverage, round 19: [a] gaps of covered frameworks (COVERAGE-GAPS.md), each checked against Apple's simulator
// (ref-mac.sh) as well.
import Foundation
#if canImport(SwiftData)
import SwiftData
import Observation
#endif
#if canImport(ScreenTime)
import ScreenTime
#endif
#if canImport(MetricKit)
import MetricKit
import OSLog
#endif
#if canImport(RealityFoundation)
import RealityFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftData)
/// a model with scalar attributes only (what @Model expands to, as Data.swift's P15Item): a custom store's
/// DefaultSnapshot gives an array attribute back as Data, and reading it then traps ("Could not cast value of type
/// 'Foundation.Data' to 'Swift.Array<Swift.String>'"), Apple's iOS 27.2 simulator too
final class P15Item: PersistentModel {
    private var _$backingData: any SwiftData.BackingData<P15Item> = P15Item.createBackingData()
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    var persistentBackingData: any SwiftData.BackingData<P15Item> { get { _$backingData } set { _$backingData = newValue } }
    static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        [.init(name: "title", keypath: \P15Item.title), .init(name: "n", keypath: \P15Item.n)]
    }
    required init(backingData: any SwiftData.BackingData<P15Item>) { _$backingData = backingData }
    init(title: String, n: Int) { self.title = title; self.n = n }
    var title: String {
        get { _$observationRegistrar.access(self, keyPath: \.title); return getValue(forKey: \.title) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.title) { setValue(forKey: \.title, to: newValue) } }
    }
    var n: Int {
        get { _$observationRegistrar.access(self, keyPath: \.n); return getValue(forKey: \.n) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.n) { setValue(forKey: \.n, to: newValue) } }
    }
}
extension P15Item: Observation.Observable {}

/// a custom SwiftData store (iOS 18 DataStore): snapshots kept in memory, inserts given permanent identifiers
final class P15StoreConfig: DataStoreConfiguration {
    typealias Store = P15Store
    var name: String
    var schema: Schema?
    let tag: String
    init(name: String, schema: Schema? = nil, tag: String) { self.name = name; self.schema = schema; self.tag = tag }
    static func == (a: P15StoreConfig, b: P15StoreConfig) -> Bool { a.tag == b.tag }
    func hash(into h: inout Hasher) { h.combine(tag) }
}
final class P15Store: DataStore {
    typealias Configuration = P15StoreConfig
    typealias Snapshot = DefaultSnapshot
    /// every store's rows and save count (the store object is SwiftData's; the check reads these)
    nonisolated(unsafe) static var rows: [PersistentIdentifier: DefaultSnapshot] = [:]
    nonisolated(unsafe) static var saves = 0, fetches = 0
    var configuration: P15StoreConfig
    var name: String
    var schema: Schema
    var identifier: String
    init(_ configuration: P15StoreConfig, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration; name = configuration.name
        schema = configuration.schema ?? Schema([P15Item.self]); identifier = "sdkcov-p15-\(configuration.tag)"
    }
    func fetch<T>(_ request: DataStoreFetchRequest<T>) throws -> DataStoreFetchResult<T, DefaultSnapshot> where T: PersistentModel {
        // filtering and sorting left to SwiftData (in memory)
        if request.descriptor.predicate != nil { throw DataStoreError.preferInMemoryFilter }
        if !request.descriptor.sortBy.isEmpty { throw DataStoreError.preferInMemorySort }
        P15Store.fetches += 1
        let all = P15Store.rows
        return DataStoreFetchResult(descriptor: request.descriptor, fetchedSnapshots: Array(all.values), relatedSnapshots: all)
    }
    func save(_ request: DataStoreSaveChangesRequest<DefaultSnapshot>) throws -> DataStoreSaveChangesResult<DefaultSnapshot> {
        P15Store.saves += 1
        var remapped: [PersistentIdentifier: PersistentIdentifier] = [:]
        for s in request.inserted {
            let id = try PersistentIdentifier.identifier(for: identifier, entityName: s.persistentIdentifier.entityName, primaryKey: UUID())
            P15Store.rows[id] = s.copy(persistentIdentifier: id)
            remapped[s.persistentIdentifier] = id
        }
        for s in request.updated { P15Store.rows[s.persistentIdentifier] = s }
        for s in request.deleted { P15Store.rows[s.persistentIdentifier] = nil }
        return DataStoreSaveChangesResult(for: identifier, remappedIdentifiers: remapped, snapshotsToReregister: [:])
    }
}
#endif

extension Registry {
    static var p15: [Check] {
        var c: [Check] = []

        // MARK: SwiftData: a custom DataStore (insert / fetch with a predicate SwiftData applies / update / delete)
        #if canImport(SwiftData)
        c.append(check("SwiftData", "custom-data-store", timeout: 30) {
            try await onMain {
                P15Store.rows = [:]; P15Store.saves = 0; P15Store.fetches = 0
                let mc = try ModelContainer(for: Schema([P15Item.self]), configurations: [P15StoreConfig(name: "p15", tag: UUID().uuidString)])
                let ctx = ModelContext(mc)
                for i in 0..<5 { ctx.insert(P15Item(title: "p15-\(i)", n: i)) }
                try ctx.save()
                let stored = P15Store.rows.count
                // a fresh context reads the store; the predicate and the sort run in memory (the store refuses them)
                let ctx2 = ModelContext(mc)
                let all = try ctx2.fetch(FetchDescriptor<P15Item>())
                let pred = Predicate<P15Item> { n in
                    PredicateExpressions.build_starts(PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(n), keyPath: \.title), with: PredicateExpressions.build_Arg("p15-1"))
                }
                let one = try ctx2.fetch(FetchDescriptor<P15Item>(predicate: pred))
                let sorted = try ctx2.fetch(FetchDescriptor<P15Item>(sortBy: [SortDescriptor(\.title, order: .reverse)])).map(\.title)
                guard let first = one.first else { throw Fail("predicate fetch empty (\(all.count) rows)") }
                first.title = "p15-renamed"
                if let last = all.first(where: { $0.title == "p15-4" }) { ctx2.delete(last) }
                try ctx2.save()
                let titles = P15Store.rows.values.compactMap { s -> String? in
                    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])?["title"] as? String
                }.sorted()
                try expect(stored == 5 && all.count == 5, "stored \(stored), fetched \(all.count)")
                try expect(one.count == 1 && sorted.first == "p15-4", "predicate \(one.count), sorted \(sorted)")
                try expect(P15Store.rows.count == 4 && P15Store.saves == 2 && titles == ["p15-0", "p15-2", "p15-3", "p15-renamed"], "after update + delete: \(titles), \(P15Store.saves) saves")
                return "5 inserted through the store, \(P15Store.fetches) store fetches (predicate / sort in memory), update + delete saved: rows \(titles)"
            }
        })
        #endif

        // MARK: ScreenTime: the configuration observer and a web page controller's blocked state
        #if canImport(ScreenTime) && os(iOS)
        c.append(check("ScreenTime", "configuration-observer-webpage-state", timeout: 30) {
            let q = DispatchQueue(label: "sdkcov.p15.st")
            let obs = STScreenTimeConfigurationObserver(updateQueue: q)
            obs.startObserving()
            // the configuration arrives asynchronously (or never: no Screen Time on the device)
            var conf = "nil"
            let end = Date().addingTimeInterval(5)
            while Date() < end {
                if let cf = obs.configuration { conf = "enforcesChildRestrictions \(cf.enforcesChildRestrictions)"; break }
                try await Task.sleep(for: .milliseconds(200))
            }
            obs.stopObserving()
            let w = try await onMain { () throws -> String in
                let vc = STWebpageController()
                vc.url = URL(string: "https://example.com/sdkcov-p15")
                vc.suppressUsageRecording = true
                try vc.setBundleIdentifier("com.x86sim.test.sdkcov")
                vc.urlIsPlayingVideo = true; vc.urlIsPictureInPicture = false
                vc.loadViewIfNeeded()
                return "blocked \(vc.urlIsBlocked), suppress \(vc.suppressUsageRecording), video \(vc.urlIsPlayingVideo), pip \(vc.urlIsPictureInPicture)"
            }
            try expect(w == "blocked false, suppress true, video true, pip false", "web page controller: \(w)")
            return "observer configuration: \(conf); controller \(w)"
        })
        #endif

        // MARK: MetricKit: signposts on MetricKit log handles reach the process's log store
        #if canImport(MetricKit) && (os(iOS) || os(visionOS))
        c.append(check("MetricKit", "signposts-in-log-store", timeout: 40) {
            let t0 = Date().addingTimeInterval(-1)
            let h = MXMetricManager.makeLogHandle(category: "sdkcov-p15")
            mxSignpost(.event, log: h, name: "sdkcov-p15-event")
            mxSignpost(.begin, log: h, name: "sdkcov-p15-interval"); mxSignpost(.end, log: h, name: "sdkcov-p15-interval")
            os_log("sdkcov-p15 marker", log: h, type: .default)
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            var seen: [String] = [], marker = false
            let end = Date().addingTimeInterval(20)
            while Date() < end {
                seen = []; marker = false
                for e in try store.getEntries(at: store.position(date: t0)) {
                    if let s = e as? OSLogEntrySignpost, s.signpostName.hasPrefix("sdkcov-p15") { seen.append("\(s.signpostName)/\(s.signpostType.rawValue)/\(s.category)") }
                    if let l = e as? OSLogEntryLog, l.composedMessage == "sdkcov-p15 marker" { marker = true }
                }
                if marker { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            // Apple's iOS 27.2 simulator: the handle's log message is in the store, its MetricKit signposts are not
            try expect(marker, "the handle's own log message never reached the store")
            try expect(seen.isEmpty, "signposts in the store \(seen) (Apple's simulator: none)")
            return "log message on the MetricKit handle in the store, its signposts not (as Apple's simulator)"
        })
        #endif

        // MARK: RealityFoundation: entity hierarchy, transforms and visual bounds (no renderer)
        #if canImport(RealityFoundation)
        c.append(check("RealityFoundation", "entity-hierarchy-bounds", timeout: 30) {
            try await onMain {
                let root = Entity(); root.name = "root"
                let box = ModelEntity(mesh: .generateBox(size: 0.2), materials: [SimpleMaterial(color: .red, isMetallic: false)])
                box.name = "box"; box.position = [1, 0, 0]
                let child = ModelEntity(mesh: .generateSphere(radius: 0.1)); child.name = "ball"; child.position = [0, 1, 0]
                root.addChild(box); box.addChild(child)
                root.scale = [2, 2, 2]
                let world = child.position(relativeTo: nil)
                let b = root.visualBounds(relativeTo: nil)
                let found = root.findEntity(named: "ball") === child
                try expect(found && abs(world.x - 2) < 1e-4 && abs(world.y - 2) < 1e-4, "ball at \(world), found \(found)")
                try expect(abs(b.min.x - 1.8) < 1e-3 && abs(b.max.y - 2.2) < 1e-3, "bounds \(b.min) .. \(b.max)")
                child.removeFromParent()
                try expect(box.children.isEmpty && child.parent == nil, "detach")
                return "ball at \(world) in world space, bounds \(b.min) .. \(b.max), detached"
            }
        })
        #endif
        // MARK: SwiftUI DocumentGroup: the companion app sdkcovDoc (ext/DocApp.swift, a DocumentGroup over a plain-text
        // FileDocument) opened through its URL scheme; it shows DocumentGroup's document browser, opens a file through
        // the browser's delegate, edits it and waits for the autosave, then opens sdkcov: again
        #if os(iOS)
        c.append(check("SwiftUI", "document-group-open-edit-save", timeout: 150) {
            let t0 = Date()
            let bg = await onMain { UIApplication.shared.beginBackgroundTask(withName: "sdkcov-doc") {} }
            defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }
            let ob = P7Box<Bool>()
            await onMain { UIApplication.shared.open(URL(string: "sdkcovdoc://p15")!) { ob.set($0) } }
            let opened = await ob.wait(20) ?? false
            try expect(opened, "sdkcovdoc: not opened (sdkcovDoc-ios.app installed?)")
            let end = Date().addingTimeInterval(100)
            while Date() < end && p3Marks("docapp-saved", since: t0).isEmpty && !(p3Marks("docapp-browser", since: t0).first?.hasPrefix("none") ?? false) {
                try await Task.sleep(for: .milliseconds(500))
            }
            // back in front (sdkcovDoc opens sdkcov:)
            let front = await p6Wait(30) { UIApplication.shared.applicationState == .active }
            let m = ["launch", "browser", "open", "saved"].map { k in "\(k): \(p3Marks("docapp-" + k, since: t0).last ?? "-")" }
            try expect(p3Marks("docapp-launch", since: t0).count == 1, "\(m)")
            try expect(p3Marks("docapp-browser", since: t0).last?.hasPrefix("creation true") == true, "browser: \(m)")
            try expect(p3Marks("docapp-open", since: t0).last == "sdkcov-doc.txt text 'sdkcov seeded text'", "open: \(m)")
            try expect(p3Marks("docapp-saved", since: t0).last == "disk 'sdkcov edited text'", "autosave: \(m)")
            return m.joined(separator: "; ") + (front ? "; sdkcov active again" : "; sdkcov not active again in 30 s")
        })
        #endif
        return c
    }
}
