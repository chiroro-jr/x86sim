// sdkcov P4: data and cloud depth. CoreData migrations / CloudKit mirroring / derived + composite attributes /
// multiple stores / async fetch; SwiftData migrations, unique attributes, relationships, history, ModelActor;
// CloudKit's local API (records, shares, queries, operations, CKSyncEngine state) and its server answer without a team
// signature; CoreSpotlight queries and batches; TabularData JSON / joins / summaries. The SwiftData models are written
// out as @Model expands them (the Linux toolchain has no SwiftDataMacros plugin), as Data.swift's SDNote.
import Foundation
import CoreData
import SwiftData
#if canImport(_SwiftData_CoreData)
import _SwiftData_CoreData
#endif
#if canImport(_CoreData_CloudKit)
import _CoreData_CloudKit
#endif
#if canImport(CloudKit)
import CloudKit
#endif
#if canImport(CoreSpotlight)
import CoreSpotlight
import UniformTypeIdentifiers
#endif
#if canImport(TabularData)
import TabularData
#endif

/// a fresh directory under tmp for one check's stores
func p4Dir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p4-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
/// poll `cond` every 100 ms for up to `secs`
func p4Wait(_ secs: Double, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if await cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
    return await cond()
}
/// a value set once from any thread
final class P4Box<T>: @unchecked Sendable {
    private let l = NSLock(); private var v: T?
    func set(_ x: T) { l.withLock { if v == nil { v = x } } }
    func get() -> T? { l.withLock { v } }
    func wait(_ secs: Double) async -> T? { _ = await p4Wait(secs) { get() != nil }; return get() }
}

// MARK: SwiftData models (what @Model expands to)

/// a model with a unique attribute
final class P4Tag: PersistentModel {
    private var _$backingData: any SwiftData.BackingData<P4Tag> = P4Tag.createBackingData()
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    var persistentBackingData: any SwiftData.BackingData<P4Tag> { get { _$backingData } set { _$backingData = newValue } }
    static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        [.init(name: "name", keypath: \P4Tag.name, defaultValue: nil, metadata: Schema.Attribute(.unique)),
         .init(name: "uses", keypath: \P4Tag.uses)]
    }
    required init(backingData: any SwiftData.BackingData<P4Tag>) { _$backingData = backingData }
    init(name: String, uses: Int) { self.name = name; self.uses = uses }
    var name: String {
        get { _$observationRegistrar.access(self, keyPath: \.name); return getValue(forKey: \.name) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.name) { setValue(forKey: \.name, to: newValue) } }
    }
    var uses: Int {
        get { _$observationRegistrar.access(self, keyPath: \.uses); return getValue(forKey: \.uses) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.uses) { setValue(forKey: \.uses, to: newValue) } }
    }
}
extension P4Tag: Observation.Observable {}

/// to-many with a cascade delete rule and an inverse
final class P4Folder: PersistentModel {
    private var _$backingData: any SwiftData.BackingData<P4Folder> = P4Folder.createBackingData()
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    var persistentBackingData: any SwiftData.BackingData<P4Folder> { get { _$backingData } set { _$backingData = newValue } }
    static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        [.init(name: "name", keypath: \P4Folder.name),
         .init(name: "files", keypath: \P4Folder.files, defaultValue: [], metadata: Schema.Relationship(deleteRule: .cascade, inverse: \P4File.folder))]
    }
    required init(backingData: any SwiftData.BackingData<P4Folder>) { _$backingData = backingData }
    // initial values go straight to the backing data, as the macro's init accessors do (self.setValue on a to-many of a
    // model not yet in a context leaves SwiftData reading nil for it later)
    init(name: String) { _$backingData.setValue(forKey: \.name, to: name); _$backingData.setValue(forKey: \.files, to: [P4File]()) }
    var name: String {
        get { _$observationRegistrar.access(self, keyPath: \.name); return getValue(forKey: \.name) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.name) { setValue(forKey: \.name, to: newValue) } }
    }
    var files: [P4File] {
        get { _$observationRegistrar.access(self, keyPath: \.files); return getValue(forKey: \.files) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.files) { setValue(forKey: \.files, to: newValue) } }
    }
}
extension P4Folder: Observation.Observable {}

final class P4File: PersistentModel {
    private var _$backingData: any SwiftData.BackingData<P4File> = P4File.createBackingData()
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    var persistentBackingData: any SwiftData.BackingData<P4File> { get { _$backingData } set { _$backingData = newValue } }
    static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        [.init(name: "name", keypath: \P4File.name), .init(name: "folder", keypath: \P4File.folder)]
    }
    required init(backingData: any SwiftData.BackingData<P4File>) { _$backingData = backingData }
    init(name: String) { self.name = name }
    var name: String {
        get { _$observationRegistrar.access(self, keyPath: \.name); return getValue(forKey: \.name) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.name) { setValue(forKey: \.name, to: newValue) } }
    }
    var folder: P4Folder? {
        get { _$observationRegistrar.access(self, keyPath: \.folder); return getValue(forKey: \.folder) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.folder) { setValue(forKey: \.folder, to: newValue) } }
    }
}
extension P4File: Observation.Observable {}

/// two versions of one entity ("Memo") for a SchemaMigrationPlan
enum P4SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Memo.self] }
    final class Memo: PersistentModel {
        private var _$backingData: any SwiftData.BackingData<Memo> = Memo.createBackingData()
        private let _$observationRegistrar = Observation.ObservationRegistrar()
        var persistentBackingData: any SwiftData.BackingData<Memo> { get { _$backingData } set { _$backingData = newValue } }
        static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] { [.init(name: "title", keypath: \Memo.title)] }
        required init(backingData: any SwiftData.BackingData<Memo>) { _$backingData = backingData }
        init(title: String) { self.title = title }
        var title: String {
            get { _$observationRegistrar.access(self, keyPath: \.title); return getValue(forKey: \.title) }
            set { _$observationRegistrar.withMutation(of: self, keyPath: \.title) { setValue(forKey: \.title, to: newValue) } }
        }
    }
}
extension P4SchemaV1.Memo: Observation.Observable {}
enum P4SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [Memo.self] }
    final class Memo: PersistentModel {
        private var _$backingData: any SwiftData.BackingData<Memo> = Memo.createBackingData()
        private let _$observationRegistrar = Observation.ObservationRegistrar()
        var persistentBackingData: any SwiftData.BackingData<Memo> { get { _$backingData } set { _$backingData = newValue } }
        static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
            [.init(name: "title", keypath: \Memo.title), .init(name: "words", keypath: \Memo.words, defaultValue: 0)]
        }
        required init(backingData: any SwiftData.BackingData<Memo>) { _$backingData = backingData }
        init(title: String, words: Int) { self.title = title; self.words = words }
        var title: String {
            get { _$observationRegistrar.access(self, keyPath: \.title); return getValue(forKey: \.title) }
            set { _$observationRegistrar.withMutation(of: self, keyPath: \.title) { setValue(forKey: \.title, to: newValue) } }
        }
        var words: Int {
            get { _$observationRegistrar.access(self, keyPath: \.words); return getValue(forKey: \.words) }
            set { _$observationRegistrar.withMutation(of: self, keyPath: \.words) { setValue(forKey: \.words, to: newValue) } }
        }
    }
}
extension P4SchemaV2.Memo: Observation.Observable {}
enum P4MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [P4SchemaV1.self, P4SchemaV2.self] }
    static var stages: [MigrationStage] {
        [.custom(fromVersion: P4SchemaV1.self, toVersion: P4SchemaV2.self, willMigrate: nil, didMigrate: { ctx in
            for m in try ctx.fetch(FetchDescriptor<P4SchemaV2.Memo>()) { m.words = m.title.split(separator: " ").count }
            try ctx.save()
        })]
    }
}

/// what @ModelActor expands to
actor P4NoteWorker: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    init(modelContainer: ModelContainer) {
        let ctx = ModelContext(modelContainer)
        modelExecutor = DefaultSerialModelExecutor(modelContext: ctx)
        self.modelContainer = modelContainer
    }
    func insert(_ n: Int, prefix: String) throws -> Int {
        for i in 0..<n { modelContext.insert(SDNote(title: "\(prefix)\(i)")) }
        try modelContext.save()
        return try modelContext.fetchCount(FetchDescriptor<SDNote>())
    }
    func onExecutor() -> Bool { modelContext === modelExecutor.modelContext }
}

// MARK: CoreData helpers

private func p4Attr(_ n: String, _ t: NSAttributeDescription.AttributeType, optional: Bool = true) -> NSAttributeDescription {
    let a = NSAttributeDescription(); a.name = n; a.type = t; a.isOptional = optional; return a
}
private func p4Entity(_ n: String, _ props: [NSPropertyDescription]) -> NSEntityDescription {
    let e = NSEntityDescription(); e.name = n; e.managedObjectClassName = "NSManagedObject"; e.properties = props; return e
}
private func p4Load(_ c: NSPersistentContainer) throws {
    var errs: [Error] = []
    c.loadPersistentStores { _, e in if let e { errs.append(e) } }
    if let e = errs.first { throw Fail("loadPersistentStores: \(e)") }
}

#if canImport(CloudKit)
final class P4SyncDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    let state = P4Box<CKSyncEngine.State.Serialization>()
    var events: [String] = []; let l = NSLock()
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        l.withLock { events.append("\(event)".split(separator: "(").first.map(String.init) ?? "?") }
        if case .stateUpdate(let u) = event { state.set(u.stateSerialization) }
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? { nil }
}
#endif

extension Registry {
    static var p4: [Check] { p4data + p4people + p4commerce + p4share }

    static var p4data: [Check] {
        var c: [Check] = []

        // MARK: CoreData
        c.append(check("CoreData", "staged-migration-custom-stage", timeout: 60) {
            // v1 Item(n) -> v2 Item(n, label): NSStagedMigrationManager with a custom stage that fills the new attribute
            let dir = try p4Dir("staged"); defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("s.sqlite")
            let v1 = NSManagedObjectModel(); v1.entities = [p4Entity("Item", [p4Attr("n", .integer64, optional: false)])]
            let v2 = NSManagedObjectModel(); v2.entities = [p4Entity("Item", [p4Attr("n", .integer64, optional: false), p4Attr("label", .string)])]
            try expect(v1.versionChecksum != v2.versionChecksum, "version checksums equal")
            let c1 = NSPersistentContainer(name: "staged", managedObjectModel: v1)
            c1.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
            try p4Load(c1)
            let ctx1 = c1.newBackgroundContext()
            try await ctx1.perform {
                for i in 1...10 { NSManagedObject(entity: v1.entitiesByName["Item"]!, insertInto: ctx1).setValue(i, forKey: "n") }
                try ctx1.save()
            }
            for s in c1.persistentStoreCoordinator.persistentStores { try c1.persistentStoreCoordinator.remove(s) }
            let ran = P4Box<Int>()
            let stage = NSCustomMigrationStage(migratingFrom: NSManagedObjectModelReference(model: v1, versionChecksum: v1.versionChecksum),
                                               to: NSManagedObjectModelReference(model: v2, versionChecksum: v2.versionChecksum))
            stage.label = "v1 to v2"
            stage.didMigrateHandler = { mgr, _ in
                guard let ctx = mgr.container?.newBackgroundContext() else { return }
                try ctx.performAndWait {
                    let all = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Item"))
                    for o in all { o.setValue("item \((o.value(forKey: "n") as? Int) ?? -1)", forKey: "label") }
                    try ctx.save()
                    ran.set(all.count)
                }
            }
            let mgr = NSStagedMigrationManager([stage])
            let c2 = NSPersistentContainer(name: "staged", managedObjectModel: v2)
            let d = NSPersistentStoreDescription(url: url)
            d.setOption(mgr, forKey: NSPersistentStoreStagedMigrationManagerOptionKey)
            c2.persistentStoreDescriptions = [d]
            try p4Load(c2)
            try expect(ran.get() == 10, "custom stage didMigrate saw \(String(describing: ran.get())) items")
            let r = NSFetchRequest<NSManagedObject>(entityName: "Item"); r.sortDescriptors = [NSSortDescriptor(key: "n", ascending: true)]
            let items = try c2.viewContext.fetch(r)
            try expect(items.count == 10 && items.last?.value(forKey: "label") as? String == "item 10", "labels \(items.map { $0.value(forKey: "label") as? String ?? "nil" })")
            // a plain lightweight (inferred) migration back to a model with one more optional attribute
            for s in c2.persistentStoreCoordinator.persistentStores { try c2.persistentStoreCoordinator.remove(s) }
            let v3 = NSManagedObjectModel(); v3.entities = [p4Entity("Item", [p4Attr("n", .integer64, optional: false), p4Attr("label", .string), p4Attr("flag", .boolean)])]
            let c3 = NSPersistentContainer(name: "staged", managedObjectModel: v3)
            let d3 = NSPersistentStoreDescription(url: url); d3.shouldMigrateStoreAutomatically = true; d3.shouldInferMappingModelAutomatically = true
            c3.persistentStoreDescriptions = [d3]
            try p4Load(c3)
            let n3 = try c3.viewContext.count(for: NSFetchRequest<NSManagedObject>(entityName: "Item"))
            try expect(n3 == 10, "after the lightweight migration \(n3) items")
            return "custom stage migrated 10 rows, lightweight stage kept \(n3)"
        })
        c.append(check("CoreData", "derived-composite-attributes", timeout: 40) {
            // Box(name, size: composite (w, h), items: to-many, itemCount: derived items.@count), Item(box)
            let dir = try p4Dir("derived"); defer { try? FileManager.default.removeItem(at: dir) }
            let box = p4Entity("Box", []), item = p4Entity("Item", [p4Attr("n", .integer64)])
            let items = NSRelationshipDescription(); items.name = "items"; items.destinationEntity = item; items.maxCount = 0; items.deleteRule = .cascadeDeleteRule; items.isOptional = true
            let owner = NSRelationshipDescription(); owner.name = "box"; owner.destinationEntity = box; owner.maxCount = 1; owner.deleteRule = .nullifyDeleteRule; owner.isOptional = true
            items.inverseRelationship = owner; owner.inverseRelationship = items
            let cnt = NSDerivedAttributeDescription(); cnt.name = "itemCount"; cnt.attributeType = .integer64AttributeType; cnt.isOptional = true
            cnt.derivationExpression = NSExpression(format: "items.@count")
            let comp = NSCompositeAttributeDescription(); comp.name = "size"; comp.isOptional = true
            comp.elements = [p4Attr("w", .integer64), p4Attr("h", .integer64)]
            box.properties = [p4Attr("name", .string), comp, items, cnt]; item.properties = [p4Attr("n", .integer64), owner]
            let m = NSManagedObjectModel(); m.entities = [box, item]
            let pc = NSPersistentContainer(name: "derived", managedObjectModel: m)
            pc.persistentStoreDescriptions = [NSPersistentStoreDescription(url: dir.appendingPathComponent("d.sqlite"))]
            try p4Load(pc)
            let ctx = pc.viewContext
            for (n, w, h, k) in [("Alpha", 2, 3, 1), ("Beta", 4, 5, 2), ("Gamma", 6, 1, 3)] {
                let o = NSManagedObject(entity: box, insertInto: ctx)
                o.setValue(n, forKey: "name"); o.setValue(["w": w, "h": h], forKey: "size")
                for i in 0..<k { NSManagedObject(entity: item, insertInto: ctx).setValuesForKeys(["n": i, "box": o]) }
            }
            try ctx.save(); ctx.reset()
            let r = NSFetchRequest<NSManagedObject>(entityName: "Box"); r.predicate = NSPredicate(format: "itemCount == 2")
            let hit = try ctx.fetch(r)
            try expect(hit.count == 1 && hit[0].value(forKey: "name") as? String == "Beta", "derived itemCount == 2: \(hit.map { $0.value(forKey: "name") ?? "?" })")
            // composite values come back as dictionaries (an SQL store does not take composite key paths in predicates or sorts)
            let all = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Box"))
            let sizes = Dictionary(uniqueKeysWithValues: all.map { ($0.value(forKey: "name") as? String ?? "?", $0.value(forKey: "size") as? [String: Any]) })
            try expect((sizes["Gamma"]??["w"] as? Int) == 6 && (sizes["Gamma"]??["h"] as? Int) == 1 && (sizes["Alpha"]??["w"] as? Int) == 2, "composite values \(sizes)")
            return "derived itemCount predicate, composite size (w,h) round trip"
        })
        c.append(check("CoreData", "configurations-multiple-stores-async-fetch-child-context", timeout: 60) {
            // entity A in configuration "One", B in "Two": two SQLite stores under one coordinator
            let dir = try p4Dir("multi"); defer { try? FileManager.default.removeItem(at: dir) }
            let a = p4Entity("A", [p4Attr("v", .integer64)]), b = p4Entity("B", [p4Attr("v", .integer64)])
            let m = NSManagedObjectModel(); m.entities = [a, b]
            m.setEntities([a], forConfigurationName: "One"); m.setEntities([b], forConfigurationName: "Two")
            let pc = NSPersistentContainer(name: "multi", managedObjectModel: m)
            let d1 = NSPersistentStoreDescription(url: dir.appendingPathComponent("one.sqlite")); d1.configuration = "One"
            let d2 = NSPersistentStoreDescription(url: dir.appendingPathComponent("two.sqlite")); d2.configuration = "Two"
            pc.persistentStoreDescriptions = [d1, d2]
            try p4Load(pc)
            try expect(pc.persistentStoreCoordinator.persistentStores.count == 2, "\(pc.persistentStoreCoordinator.persistentStores.count) stores")
            let ctx = pc.viewContext
            for i in 0..<20 { NSManagedObject(entity: a, insertInto: ctx).setValue(i, forKey: "v") }
            for i in 0..<5 { NSManagedObject(entity: b, insertInto: ctx).setValue(i, forKey: "v") }
            try ctx.save()
            let s1 = pc.persistentStoreCoordinator.persistentStores.first { $0.configurationName == "One" }!
            let rA = NSFetchRequest<NSManagedObject>(entityName: "A"); rA.affectedStores = [s1]
            try expect(try ctx.count(for: rA) == 20, "A in store One")
            let rB = NSFetchRequest<NSManagedObject>(entityName: "B"); rB.affectedStores = [s1]
            try expect(try ctx.count(for: rB) == 0, "B leaked into store One")
            // a child context: its save reaches the parent, not the store, until the parent saves
            let child = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType); child.parent = ctx
            try await child.perform { NSManagedObject(entity: a, insertInto: child).setValue(100, forKey: "v"); try child.save() }
            try expect(ctx.hasChanges && ctx.insertedObjects.count == 1, "parent sees the child's insert: \(ctx.insertedObjects.count)")
            try ctx.save()
            // NSAsynchronousFetchRequest with progress
            let bg = pc.newBackgroundContext()
            let got = P4Box<Int>()
            let fr = NSFetchRequest<NSManagedObject>(entityName: "A"); fr.predicate = NSPredicate(format: "v >= 10")
            let afr = NSAsynchronousFetchRequest(fetchRequest: fr) { res in got.set(res.finalResult?.count ?? -1) }
            try await bg.perform { _ = try bg.execute(afr) }
            let n = await got.wait(10)
            try expect(n == 11, "async fetch v >= 10: \(String(describing: n))")
            return "2 stores by configuration, child -> parent save, async fetch \(n!)"
        })
        #if canImport(CloudKit)
        c.append(check("CoreData", "cloudkit-container-local-mirror", timeout: 120) {
            // NSPersistentCloudKitContainer with the app's iCloud container: the store loads and works locally; mirroring
            // reports its setup through eventChangedNotification (no account / no team signature: it does not succeed)
            let dir = try p4Dir("ckmirror"); defer { try? FileManager.default.removeItem(at: dir) }
            let note = p4Entity("Note", [p4Attr("title", .string), p4Attr("n", .integer64)])
            let m = NSManagedObjectModel(); m.entities = [note]
            let pc = NSPersistentCloudKitContainer(name: "ckmirror", managedObjectModel: m)
            let d = NSPersistentStoreDescription(url: dir.appendingPathComponent("ck.sqlite"))
            d.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.x86sim.test.sdkcov")
            d.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            d.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            pc.persistentStoreDescriptions = [d]
            let events = P4Box<[String]>(); var evs: [String] = []; let el = NSLock()
            let ob = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: pc, queue: nil) { n in
                guard let e = n.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
                let s = "\(e.type.rawValue):\(e.endDate == nil ? "started" : (e.succeeded ? "ok" : "failed \((e.error as NSError?)?.domain ?? "") \((e.error as NSError?)?.code ?? 0)"))"
                el.withLock { evs.append(s); if e.endDate != nil { events.set(evs) } }
            }
            defer { NotificationCenter.default.removeObserver(ob) }
            try p4Load(pc)
            let ctx = pc.viewContext
            for i in 0..<3 { let o = NSManagedObject(entity: note, insertInto: ctx); o.setValue("n\(i)", forKey: "title"); o.setValue(i, forKey: "n") }
            try ctx.save()
            try expect(try ctx.count(for: NSFetchRequest<NSManagedObject>(entityName: "Note")) == 3, "local rows")
            // the CloudKit schema initialisation needs the server: an error, never a hang or a crash
            var initErr = "none"
            do { try pc.initializeCloudKitSchema(options: [.dryRun]) } catch { initErr = "\((error as NSError).domain) \((error as NSError).code)" }
            let ev = await events.wait(20)
            let all = el.withLock { evs }
            // Apple's simulator: the setup event starts and does not finish within 20 s; x86Sim's finishes failed (CKError 8,
            // as the server check below). Either way mirroring never sets up without a team signature
            try expect(all.first == "0:started" && !all.contains(where: { $0.hasSuffix(":ok") }), "mirroring events \(all)")
            return "3 local rows, events \(all.isEmpty ? "none" : all.joined(separator: ","))\(ev == nil ? " (no finished event in 20 s)" : ""), dry-run schema init \(initErr)"
        })
        #endif

        // MARK: _CoreData_CloudKit / _SwiftData_CoreData ports (tvOS has them in More_tvOS.swift)
        #if !os(tvOS)
        c.append(check("_CoreData_CloudKit", "container-options-scope") {
            let o = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.x86sim.test.sdkcov")
            try expect(o.databaseScope == .private, "default scope \(o.databaseScope.rawValue)")
            o.databaseScope = .public
            try expect(o.databaseScope == .public && o.containerIdentifier == "iCloud.com.x86sim.test.sdkcov", "scope \(o.databaseScope.rawValue)")
            o.databaseScope = .shared
            try expect(o.databaseScope == .shared, "shared scope")
            return "private (default) -> public -> shared"
        })
        c.append(check("_SwiftData_CoreData", "managed-object-model") {
            guard let m = NSManagedObjectModel.makeManagedObjectModel(for: [SDNote.self, P4Folder.self, P4File.self]) else { throw Fail("no model") }
            let e = m.entitiesByName["SDNote"]
            try expect(e != nil && Set(e!.attributesByName.keys).isSuperset(of: ["title", "stamp"]), "entities \(m.entitiesByName.keys.sorted())")
            let rel = m.entitiesByName["P4Folder"]?.relationshipsByName["files"]
            try expect(rel?.isToMany == true && rel?.deleteRule == .cascadeDeleteRule && rel?.inverseRelationship?.name == "folder",
                       "P4Folder.files: toMany \(String(describing: rel?.isToMany)) rule \(String(describing: rel?.deleteRule.rawValue)) inverse \(String(describing: rel?.inverseRelationship?.name))")
            return "SDNote \(e!.attributesByName.keys.sorted()), P4Folder.files to-many cascade"
        })
        #endif

        // MARK: SwiftData depth
        c.append(check("SwiftData", "unique-attribute-upsert", timeout: 40) {
            try await onMain {
                let mc = try ModelContainer(for: P4Tag.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
                let ctx = mc.mainContext
                // @Attribute(.unique): a second insert with the same name updates the row (upsert)
                ctx.insert(P4Tag(name: "swift", uses: 1)); ctx.insert(P4Tag(name: "data", uses: 2)); try ctx.save()
                ctx.insert(P4Tag(name: "swift", uses: 5)); try ctx.save()
                let tags = try ctx.fetch(FetchDescriptor<P4Tag>(sortBy: [SortDescriptor(\.name)]))
                try expect(tags.map { "\($0.name)=\($0.uses)" } == ["data=2", "swift=5"], "unique upsert: \(tags.map { "\($0.name)=\($0.uses)" })")
                return "upsert kept 2 rows, swift=5"
            }
        })
        c.append(check("SwiftData", "relationship-inverse-cascade", timeout: 40) {
            try await onMain {
                let mc = try ModelContainer(for: P4Folder.self, P4File.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
                let ctx = mc.mainContext
                let f = P4Folder(name: "docs"); ctx.insert(f)
                for i in 0..<4 { let x = P4File(name: "f\(i)"); ctx.insert(x); x.folder = f }
                try ctx.save()
                try expect(f.files.count == 4, "inverse: folder has \(f.files.count) files")
                let files = try ctx.fetch(FetchDescriptor<P4File>())
                try expect(files.count == 4 && files.allSatisfy { $0.folder?.name == "docs" }, "folder set on \(files.filter { $0.folder != nil }.count)/\(files.count)")
                ctx.delete(f); try ctx.save()
                let left = try ctx.fetchCount(FetchDescriptor<P4File>())
                try expect(left == 0, "cascade left \(left) files")
                return "4 files, inverse to-many, cascade delete"
            }
        })
        c.append(check("SwiftData", "versioned-schema-migration-plan", timeout: 60) {
            let dir = try p4Dir("sdmig"); defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("m.store")
            do {
                let c1 = try ModelContainer(for: Schema(versionedSchema: P4SchemaV1.self), configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
                let ctx = ModelContext(c1)
                for t in ["one", "two words", "three little words"] { ctx.insert(P4SchemaV1.Memo(title: t)) }
                try ctx.save()
            }
            let c2 = try ModelContainer(for: Schema(versionedSchema: P4SchemaV2.self), migrationPlan: P4MigrationPlan.self,
                                        configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let ctx = ModelContext(c2)
            let memos = try ctx.fetch(FetchDescriptor<P4SchemaV2.Memo>(sortBy: [SortDescriptor(\.title)]))
            let got = memos.map { "\($0.title)=\($0.words)" }
            try expect(got == ["one=1", "three little words=3", "two words=2"], "after migration \(got)")
            return got.joined(separator: ", ")
        })
        c.append(check("SwiftData", "history-model-actor", timeout: 60) {
            let dir = try p4Dir("sdhist"); defer { try? FileManager.default.removeItem(at: dir) }
            let mc = try ModelContainer(for: SDNote.self, configurations: ModelConfiguration(url: dir.appendingPathComponent("h.store"), cloudKitDatabase: .none))
            // a ModelActor inserts on its own executor
            let w = P4NoteWorker(modelContainer: mc)
            let n = try await w.insert(6, prefix: "bg")
            try expect(n == 6, "actor count \(n)")
            try expect(await w.onExecutor(), "modelContext is not the executor's")
            // the main context sees them, then history lists the transaction with 6 inserts
            let main = ModelContext(mc)
            try expect(try main.fetchCount(FetchDescriptor<SDNote>()) == 6, "main context count")
            let tx = try main.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
            let inserts = tx.flatMap(\.changes).filter { if case .insert = $0 { return true }; return false }.count
            try expect(inserts == 6, "history: \(tx.count) transactions, \(inserts) inserts")
            // a token after them: history since it is empty until another change
            guard let tok = tx.last?.token else { throw Fail("no token") }
            var since = HistoryDescriptor<DefaultHistoryTransaction>()
            since.predicate = Predicate<DefaultHistoryTransaction> { t in   // #Predicate { $0.token > tok }, expanded
                PredicateExpressions.build_Comparison(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(t), keyPath: \.token),
                                                      rhs: PredicateExpressions.build_Arg(tok), op: .greaterThan)
            }
            try expect(try main.fetchHistory(since).isEmpty, "history after the last token not empty")
            main.insert(SDNote(title: "main")); try main.save()
            let after = try main.fetchHistory(since)
            try expect(after.count == 1, "\(after.count) transactions after the token")
            try main.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>())
            return "actor inserted 6, history \(tx.count) tx / \(inserts) inserts, 1 after the token"
        })

        // MARK: CloudKit
        #if canImport(CloudKit)
        c.append(check("CloudKit", "records-coding-share-query-operations") {
            let zone = CKRecordZone(zoneName: "sdkcov")
            try expect(zone.zoneID.ownerName == CKCurrentUserDefaultName && zone.zoneID.zoneName == "sdkcov", "zone id")
            let rid = CKRecord.ID(recordName: "doc-1", zoneID: zone.zoneID)
            let r = CKRecord(recordType: "Doc", recordID: rid)
            let parent = CKRecord(recordType: "Folder", recordID: CKRecord.ID(recordName: "folder-1", zoneID: zone.zoneID))
            r["title"] = "Hello"; r["n"] = 42; r["tags"] = ["a", "b"]; r["when"] = Date(timeIntervalSince1970: 1_700_000_000)
            r["blob"] = Data([1, 2, 3])
            r["folder"] = CKRecord.Reference(record: parent, action: .deleteSelf)
            r.setParent(parent)
            r.encryptedValues["secret"] = "s3cret"
            try expect(Set(r.changedKeys()).isSuperset(of: ["title", "n", "tags", "when", "blob", "folder"]), "changedKeys \(r.changedKeys())")
            try expect(r.encryptedValues["secret"] as? String == "s3cret", "encrypted value")
            // NSSecureCoding: the whole record, then system fields only
            let full = try NSKeyedArchiver.archivedData(withRootObject: r, requiringSecureCoding: true)
            guard let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: full) else { throw Fail("unarchive") }
            try expect(back.recordID == rid && back["n"] as? Int == 42 && back["tags"] as? [String] == ["a", "b"] && back.parent?.recordID == parent.recordID,
                       "round trip \(back)")
            try expect((back["folder"] as? CKRecord.Reference)?.action == .deleteSelf, "reference action")
            let sysCoder = NSKeyedArchiver(requiringSecureCoding: true); r.encodeSystemFields(with: sysCoder); sysCoder.finishEncoding()
            let sysU = try NSKeyedUnarchiver(forReadingFrom: sysCoder.encodedData); sysU.requiresSecureCoding = true
            guard let sys = CKRecord(coder: sysU) else { throw Fail("system fields record") }
            try expect(sys.recordID == rid && sys.recordType == "Doc" && sys["title"] == nil, "system fields carry fields: \(sys.allKeys())")
            // shares
            let share = CKShare(rootRecord: r)
            share[CKShare.SystemFieldKey.title] = "Shared doc"; share.publicPermission = .readOnly
            try expect(share.publicPermission == .readOnly && share[CKShare.SystemFieldKey.title] as? String == "Shared doc" && r.share != nil, "record share")
            let zshare = CKShare(recordZoneID: zone.zoneID)
            try expect(zshare.recordID.recordName == CKRecordNameZoneWideShare, "zone-wide share name \(zshare.recordID.recordName)")
            // queries + operations (configured, not run)
            let q = CKQuery(recordType: "Doc", predicate: NSPredicate(format: "n > %d AND title BEGINSWITH %@", 10, "He"))
            q.sortDescriptors = [NSSortDescriptor(key: "n", ascending: false)]
            let qo = CKQueryOperation(query: q); qo.zoneID = zone.zoneID; qo.resultsLimit = 25; qo.desiredKeys = ["title"]
            let cfg = CKOperation.Configuration(); cfg.timeoutIntervalForRequest = 7; cfg.qualityOfService = .userInitiated; cfg.allowsCellularAccess = false
            qo.configuration = cfg
            try expect(qo.resultsLimit == 25 && qo.configuration.timeoutIntervalForRequest == 7 && qo.query?.recordType == "Doc", "query op")
            let mo = CKModifyRecordsOperation(recordsToSave: [r, share], recordIDsToDelete: [parent.recordID])
            mo.savePolicy = .changedKeys; mo.isAtomic = true
            try expect(mo.recordsToSave?.count == 2 && mo.savePolicy == .changedKeys, "modify op")
            let zo = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone.zoneID], configurationsByRecordZoneID: [zone.zoneID: .init(previousServerChangeToken: nil, resultsLimit: 10, desiredKeys: nil)])
            try expect(zo.recordZoneIDs?.count == 1, "zone changes op")
            let sub = CKQuerySubscription(recordType: "Doc", predicate: NSPredicate(value: true), options: [.firesOnRecordCreation])
            let ni = CKSubscription.NotificationInfo(); ni.shouldSendContentAvailable = true; sub.notificationInfo = ni
            try expect(sub.querySubscriptionOptions == [.firesOnRecordCreation], "subscription")
            return "record \(full.count) B archived, system fields \(sysCoder.encodedData.count) B, share + zone share, query/modify/zone-changes ops"
        })
        c.append(check("CloudKit", "sync-engine-state-server-error", timeout: 150) {   // Apple's fresh simulator: cloudd answers after up to ~60 s
            // CKSyncEngine's local state, and what the server side answers to an app without a team signature / account
            let ck = CKContainer(identifier: "iCloud.com.x86sim.test.sdkcov")
            let db = ck.privateCloudDatabase
            try expect(db.databaseScope == .private, "scope")
            let del = P4SyncDelegate()
            var cfg = CKSyncEngine.Configuration(database: db, stateSerialization: nil, delegate: del); cfg.automaticallySync = false
            let eng = CKSyncEngine(cfg)
            let zid = CKRecordZone.ID(zoneName: "sdkcov")
            let ids = (0..<3).map { CKRecord.ID(recordName: "r\($0)", zoneID: zid) }
            eng.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zid))])
            eng.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
            eng.state.remove(pendingRecordZoneChanges: [.saveRecord(ids[0])])
            eng.state.add(pendingRecordZoneChanges: [.deleteRecord(ids[0])])
            let pend = eng.state.pendingRecordZoneChanges
            try expect(pend.count == 3 && pend.contains(.deleteRecord(ids[0])) && !pend.contains(.saveRecord(ids[0])), "pending \(pend)")
            try expect(eng.state.pendingDatabaseChanges.count == 1, "pending db changes")
            // the engine posts its state through the delegate; round-trip it through JSON into a second engine
            var restored = "no stateUpdate event in 10 s"
            if let ser = await del.state.wait(10) {
                let js = try JSONEncoder().encode(ser)
                let ser2 = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: js)
                var cfg2 = CKSyncEngine.Configuration(database: db, stateSerialization: ser2, delegate: P4SyncDelegate()); cfg2.automaticallySync = false
                let eng2 = CKSyncEngine(cfg2)
                func key(_ c: CKSyncEngine.PendingRecordZoneChange) -> String {
                    switch c { case .saveRecord(let id): return "save \(id.recordName)"; case .deleteRecord(let id): return "delete \(id.recordName)"; @unknown default: return "other" }
                }
                let got = Set(eng2.state.pendingRecordZoneChanges.map(key)), want = Set(pend.map(key))
                try expect(got == want, "restored pending \(got.sorted()) want \(want.sorted())")
                restored = "state \(js.count) B JSON restored"
            }
            // a server operation: CloudKit refuses an app without a team-signed application-identifier
            var srv = "no error"
            do { _ = try await db.save(CKRecord(recordType: "Probe", recordID: CKRecord.ID(recordName: "probe"))) }
            catch let e as CKError { srv = "CKError \(e.code.rawValue)" }
            catch { srv = "\((error as NSError).domain) \((error as NSError).code)" }
            // Apple's simulator: missingEntitlement (8), CloudKit reads the container from a team-signed application-identifier
            try expect(srv == "CKError \(CKError.Code.missingEntitlement.rawValue)", "server save: \(srv) (Apple's: CKError 8, missing entitlement)")
            return "3 pending record changes + 1 zone, \(restored), events \(del.l.withLock { del.events }), server save \(srv)"
        })
        #endif

        // MARK: CoreSpotlight
        #if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
        c.append(check("CoreSpotlight", "search-query-batch-client-state", timeout: 240) {   // Apple's fresh simulator: up to ~110 s
            try skipIf(!CSSearchableIndex.isIndexingAvailable(), "indexing unavailable")
            let tok = "p4tok\(Int.random(in: 100000...999999))"
            let idx = CSSearchableIndex(name: "sdkcov-p4")
            // a batch with client state
            let state = Data("state-\(tok)".utf8)
            idx.beginBatch()
            let items = (0..<3).map { i -> CSSearchableItem in
                let a = CSSearchableItemAttributeSet(contentType: .text); a.title = "\(tok) item \(i)"; a.contentDescription = "sdkcov p4"
                a.keywords = [tok]; a.rating = NSNumber(value: i)
                return CSSearchableItem(uniqueIdentifier: "\(tok)-\(i)", domainIdentifier: "sdkcov-p4", attributeSet: a)
            }
            idx.indexSearchableItems(items, completionHandler: nil)   // inside a batch: completes with endBatch
            try await idx.endBatch(withClientState: state)
            let got = try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data?, Error>) in
                idx.fetchLastClientState { d, e in if let e { k.resume(throwing: e) } else { k.resume(returning: d) } }
            }
            try expect(got == state, "client state \(got.map { String(decoding: $0, as: UTF8.self) } ?? "nil")")
            // CSSearchQuery finds them (indexing is asynchronous: retry for a while)
            var found: [String] = []
            let until = Date().addingTimeInterval(150)
            while Date() < until {
                let ctx = CSSearchQueryContext(); ctx.fetchAttributes = ["title", "rating"]
                let q = CSSearchQuery(queryString: "title == \"\(tok)*\"", queryContext: ctx)
                found = []
                for try await r in q.results { found.append(r.item.uniqueIdentifier) }
                if found.count == 3 { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            try expect(Set(found) == Set(items.map(\.uniqueIdentifier)), "query found \(found)")
            try await idx.deleteSearchableItems(withDomainIdentifiers: ["sdkcov-p4"])
            var after = -1
            for _ in 0..<20 {
                let q = CSSearchQuery(queryString: "title == \"\(tok)*\"", queryContext: nil)
                after = 0; for try await _ in q.results { after += 1 }
                if after == 0 { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            try expect(after == 0, "\(after) items after the delete")
            return "batch of 3 with client state, query found 3, gone after delete"
        })
        c.append(check("CoreSpotlight", "user-query", timeout: 60) {
            // CSUserQuery (iOS 18): prepare() then a query over the app's items; the semantic model may be absent in a simulator
            CSUserQuery.prepare()
            let ctx = CSUserQueryContext(); ctx.fetchAttributes = ["title"]; ctx.maxResultCount = 5; ctx.enableRankedResults = true
            let q = CSUserQuery(userQueryString: "sdkcov", userQueryContext: ctx)
            var items = 0, sugg = 0, err = "none"
            do { for try await r in q.responses { switch r { case .item: items += 1; case .suggestion: sugg += 1; @unknown default: break } } }
            catch { err = "\((error as NSError).domain) \((error as NSError).code)" }
            q.cancel()
            // Apple's simulator (iOS, visionOS): the query ends with nothing found and no error
            try expect(items == 0 && sugg == 0 && err == "none", "\(items) items, \(sugg) suggestions, error \(err) (Apple's simulator: 0, 0, none)")
            return "\(items) items, \(sugg) suggestions, error \(err)"
        })
        #endif
        #if os(tvOS)
        c.append(check("CoreSpotlight", "tvos-runtime-answers", timeout: 20) {
            // tvOS: every CoreSpotlight API is marked unavailable, but the framework ships its classes; what they answer
            // through the Objective-C runtime (as an app built against an older SDK would call them)
            guard let idx = NSClassFromString("CSSearchableIndex") as? NSObject.Type,
                  let set = NSClassFromString("CSSearchableItemAttributeSet") as? NSObject.Type else { throw Fail("no CoreSpotlight classes") }
            let avail = (idx as AnyObject).perform(NSSelectorFromString("isIndexingAvailable")) != nil
            let a = set.init()
            a.setValue("sdkcov", forKey: "title")
            try expect(a.value(forKey: "title") as? String == "sdkcov", "attribute set title")
            let d = try NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: true)
            return "indexing available \(avail), attribute set archived \(d.count) B"
        })
        #endif

        // MARK: TabularData
        #if canImport(TabularData)
        c.append(check("TabularData", "json-join-summary") {
            let people = try DataFrame(jsonData: Data(#"[{"id":1,"name":"ann","team":"a"},{"id":2,"name":"bob","team":"b"},{"id":3,"name":"cid","team":"a"}]"#.utf8))
            let scores = try DataFrame(csvData: Data("id,score\n1,90\n2,70\n3,85\n4,10\n".utf8))
            try expect(people.rows.count == 3 && people.columns.map(\.name).sorted() == ["id", "name", "team"], "json shape \(people.shape)")
            let j = people.joined(scores, on: "id", kind: .inner)
            try expect(j.rows.count == 3, "inner join rows \(j.rows.count)")
            let lj = scores.joined(people, on: "id", kind: .left)
            try expect(lj.rows.count == 4, "left join rows \(lj.rows.count)")
            let sum = scores.summary(of: "score")
            let mean = sum["mean", Double.self][0]
            try expect(abs((mean ?? 0) - 63.75) < 0.001, "mean \(String(describing: mean))")
            let out = try j.jsonRepresentation()
            let back = try DataFrame(jsonData: out)
            try expect(back.rows.count == 3, "json round trip \(back.shape)")
            let csv = String(decoding: try j.csvRepresentation(), as: UTF8.self)
            try expect(csv.split(separator: "\n").count == 4, "csv lines")
            return "join 3 / left 4, mean 63.75, json \(out.count) B"
        })
        #endif
        return c
    }
}
