// sdkcov File Provider extension (iOS, visionOS: <app>/PlugIns/sdkcovFileProvider.appex, com.apple.fileprovider-nonui,
// an NSFileProviderReplicatedExtension): a read-mostly tree of fixed items (root: hello.txt, docs/ with note.txt) whose
// contents are made on fetch, plus createItem that accepts a new file. checks/P3_Extensions.swift adds a domain, lists
// the tree through the user-visible URL (enumeration), reads hello.txt (materialization: fetchContents) and imports a
// file (createItem).
import Foundation
import FileProvider
import UniformTypeIdentifiers

final class SDKCovFPItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let size: Int
    init(_ id: String, parent: NSFileProviderItemIdentifier, name: String, folder: Bool, size: Int = 0) {
        itemIdentifier = NSFileProviderItemIdentifier(id); parentItemIdentifier = parent; filename = name
        contentType = folder ? .folder : .plainText; self.size = size
    }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsEvicting] }
    var itemVersion: NSFileProviderItemVersion { NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8)) }
    var documentSize: NSNumber? { contentType == .folder ? nil : NSNumber(value: size) }
}

/// the fixed tree: identifier -> (parent, name, folder, contents)
let sdkcovFPTree: [String: (NSFileProviderItemIdentifier, String, Bool, String)] = [
    "hello": (.rootContainer, "hello.txt", false, "hello from the sdkcov file provider"),
    "docs": (.rootContainer, "docs", true, ""),
    "note": (NSFileProviderItemIdentifier("docs"), "note.txt", false, "a note inside docs"),
]

func sdkcovFPItem(_ id: NSFileProviderItemIdentifier) -> NSFileProviderItem? {
    if id == .rootContainer { return SDKCovFPItem(NSFileProviderItemIdentifier.rootContainer.rawValue, parent: .rootContainer, name: "sdkcov", folder: true) }
    guard let t = sdkcovFPTree[id.rawValue] else { return nil }
    return SDKCovFPItem(id.rawValue, parent: t.0, name: t.1, folder: t.2, size: t.3.utf8.count)
}

final class SDKCovFPEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier
    init(_ c: NSFileProviderItemIdentifier) { container = c }
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let kids: [NSFileProviderItem]
        if container == .workingSet { kids = [] }
        else { kids = sdkcovFPTree.filter { $0.value.0 == container }.keys.sorted().compactMap { sdkcovFPItem(NSFileProviderItemIdentifier($0)) } }
        sdkcovMark("fp-enumerate", "\(container.rawValue): \(kids.map(\.filename).joined(separator: ","))")
        observer.didEnumerate(kids)
        observer.finishEnumerating(upTo: nil)
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("1".utf8)))
    }
}

@objc(SDKCovFileProvider)
final class SDKCovFileProvider: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        sdkcovMark("fp-init", "domain \(domain.identifier.rawValue) pid \(ProcessInfo.processInfo.processIdentifier)")
    }
    func invalidate() {}
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let i = sdkcovFPItem(identifier) { completionHandler(i, nil) }
        else { completionHandler(nil, NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue)) }
        return Progress()
    }
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        sdkcovMark("fp-fetch", itemIdentifier.rawValue)
        guard let t = sdkcovFPTree[itemIdentifier.rawValue], !t.2, let item = sdkcovFPItem(itemIdentifier) else {
            completionHandler(nil, nil, NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue)); return Progress()
        }
        do {
            let tmp = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL() ?? FileManager.default.temporaryDirectory
            let u = tmp.appendingPathComponent(UUID().uuidString)
            try Data(t.3.utf8).write(to: u)
            completionHandler(u, item, nil)
        } catch { completionHandler(nil, nil, error) }
        return Progress()
    }
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        sdkcovMark("fp-create", "\(itemTemplate.filename) in \(itemTemplate.parentItemIdentifier.rawValue): \(text)")
        let item = SDKCovFPItem("new-\(itemTemplate.filename)", parent: itemTemplate.parentItemIdentifier, name: itemTemplate.filename, folder: itemTemplate.contentType == .folder, size: text.utf8.count)
        completionHandler(item, [], false, nil)
        return Progress()
    }
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        sdkcovMark("fp-modify", item.itemIdentifier.rawValue)
        completionHandler(item, [], false, nil)
        return Progress()
    }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        sdkcovMark("fp-delete", identifier.rawValue)
        completionHandler(nil)
        return Progress()
    }
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        SDKCovFPEnumerator(containerItemIdentifier)
    }
}
