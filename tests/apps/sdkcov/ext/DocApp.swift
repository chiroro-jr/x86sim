// sdkcov's DocumentGroup app (iOS: sdkcovDoc-ios.app next to sdkcov-ios.app, com.x86sim.test.sdkcov.doc): a SwiftUI
// document app (DocumentGroup over a plain-text FileDocument). checks/P15_Gaps.swift (func:SwiftUI.document-group-*)
// opens it through its URL scheme sdkcovdoc:; at launch it finds DocumentGroup's document browser, opens a seeded file
// through the browser's delegate (as a tap on the file would), edits the document, waits for its autosave, marks each
// step (ext/Marks.swift) and opens sdkcov: again so the app comes back.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SDKCovTextDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String = "sdkcov new document") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

@MainActor enum DocDriver {
    static var started = false
    static let seeded = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sdkcov-doc.txt")

    static func all(_ vc: UIViewController?) -> [UIViewController] {
        guard let vc else { return [] }
        return [vc] + vc.children.flatMap { all($0) } + all(vc.presentedViewController)
    }
    static func browser() -> UIDocumentBrowserViewController? {
        let roots = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).map(\.rootViewController)
        return roots.flatMap { all($0) }.compactMap { $0 as? UIDocumentBrowserViewController }.first
    }
    /// sdkcov's scene lifecycle check (func:UIKit.scene-lifecycle-round-trip, checks/P22_Gaps.swift) marks
    /// lifecycle-request (a token) just before it opens sdkcovdoc:; such a launch or activation only opens sdkcov:
    /// again (no document work)
    static var answered = Set<String>()
    static func lifecycleRequest() -> String? {
        guard let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sdkcovGroup),
              let s = try? String(contentsOf: g.appendingPathComponent("p3marks/lifecycle-request"), encoding: .utf8),
              let l = s.split(separator: "\n").last else { return nil }
        let f = l.split(separator: " ", maxSplits: 1)
        guard f.count == 2, let t = Double(f[0]), Date().timeIntervalSince1970 - t < 30 else { return nil }
        return String(f[1])
    }
    /// true when a recent lifecycle request is there (answered now or before)
    static func answerLifecycle() -> Bool {
        guard let t = lifecycleRequest() else { return false }
        if answered.insert(t).inserted {
            sdkcovMark("docapp-lifecycle", "token \(t) pid \(ProcessInfo.processInfo.processIdentifier)")
            back("sdkcov://lifecycle-done")
        }
        return true
    }
    /// launched by URL (sdkcovdoc:) or by hand: once per process
    static func start() {
        if answerLifecycle() { return }
        guard !started else { return }
        started = true
        sdkcovMark("docapp-launch", "pid \(ProcessInfo.processInfo.processIdentifier)")
        try? Data("sdkcov seeded text".utf8).write(to: seeded)
        Task { @MainActor in
            var b: UIDocumentBrowserViewController?
            for _ in 0..<60 { b = browser(); if b != nil { break }; try? await Task.sleep(for: .milliseconds(250)) }
            guard let b else {
                let roots = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).map { "\(type(of: $0.rootViewController as Any))" }
                sdkcovMark("docapp-browser", "none (roots \(roots))"); back(); return
            }
            sdkcovMark("docapp-browser", "creation \(b.allowsDocumentCreation) multiple \(b.allowsPickingMultipleItems) types \(b.contentTypesForRecentDocuments.map(\.identifier))")
            // a tap on the file: the browser's delegate (DocumentGroup's) gets it picked
            b.delegate?.documentBrowser?(b, didPickDocumentsAt: [seeded])
        }
    }
    static func opened(_ text: Binding<String>, _ url: URL?) {
        sdkcovMark("docapp-open", "\(url?.lastPathComponent ?? "nil") text '\(text.wrappedValue)'")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            text.wrappedValue = "sdkcov edited text"
            // autosave: the file on disk follows the edit
            var disk = ""
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                disk = (try? String(contentsOf: url ?? seeded, encoding: .utf8)) ?? "unreadable"
                if disk == "sdkcov edited text" { break }
            }
            sdkcovMark("docapp-saved", "disk '\(disk)'")
            back()
        }
    }
    static func back(_ url: String = "sdkcov://doc-done") {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            await UIApplication.shared.open(URL(string: url)!)
        }
    }
}

struct SDKCovDocView: View {
    @Binding var doc: SDKCovTextDoc
    let url: URL?
    var body: some View {
        TextEditor(text: $doc.text).onAppear { DocDriver.opened($doc.text, url) }
    }
}

@main
struct SDKCovDocApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: SDKCovTextDoc()) { cfg in
            SDKCovDocView(doc: cfg.$document, url: cfg.fileURL)
        }
    }
    init() {
        Task { @MainActor in DocDriver.start() }
        // already running: a lifecycle request comes as an activation
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = DocDriver.answerLifecycle() }
        }
    }
}
