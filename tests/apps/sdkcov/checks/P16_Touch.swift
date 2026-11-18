// SDK coverage, round 20: more touch-driven checks (tests/apps/sdkcov/inputs.sh cvmenu ...; ref-mac.sh INPUT=... on
// the Mac). A long press on a UICollectionView cell (the Files app's browser is one): the scroll view delays the
// cell's touches, then the context menu interaction opens the cell's menu.
import Foundation
#if canImport(FileProvider)
import FileProvider
#endif
#if canImport(UIKit)
import UIKit
#endif

private var touchWait16: Double { Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0 }

#if os(iOS) || os(visionOS)
/// a collection view of one big cell (0.1..0.9 x 0.3..0.7 of the screen; the host presses (0.2, 0.5), left, as Files' first column); the delegate gives it a context menu and
/// notes the touch times the cell saw (UITouch.timestamp against the system uptime when it arrived)
@MainActor private final class P16CollectionVC: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    let log: P6Log
    init(log: P6Log) { self.log = log; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    final class Cell: UICollectionViewCell {
        var log: P6Log?
        override var isHighlighted: Bool { didSet { if isHighlighted { log?.add("highlight") } } }
        override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
            if let x = t.first { log?.add(String(format: "began dt=%.3f", ProcessInfo.processInfo.systemUptime - x.timestamp)) }
            super.touchesBegan(t, with: e)
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        let b = view.bounds.size
        let l = UICollectionViewFlowLayout()
        l.itemSize = CGSize(width: b.width * 0.8, height: b.height * 0.4)
        l.sectionInset = UIEdgeInsets(top: b.height * 0.3, left: b.width * 0.1, bottom: b.height * 0.3, right: b.width * 0.1)
        let cv = UICollectionView(frame: view.bounds, collectionViewLayout: l)
        cv.contentInsetAdjustmentBehavior = .never
        cv.backgroundColor = .white; cv.alwaysBounceVertical = true
        cv.register(Cell.self, forCellWithReuseIdentifier: "c")
        cv.dataSource = self; cv.delegate = self
        cv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cv)
    }
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { 1 }
    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "c", for: ip) as! Cell
        c.log = log; c.contentView.backgroundColor = .orange
        return c
    }
    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) { log.add("select") }
    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        log.add("menu")
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: "SDKCovCellOne") { _ in }, UIAction(title: "SDKCovCellTwo", attributes: .destructive) { _ in }])
        }
    }
}
#endif

extension Registry {
    static var p16_touch: [Check] {
        var c: [Check] = []
        #if os(iOS) || os(visionOS)
        // MARK: UIKit: a long press on a collection view cell opens its context menu (not a tap: no selection)
        c.append(check("UIKit", "input-collection-context-menu", timeout: 120) {
            let wait = touchWait16
            let log = P6Log()
            // pushed onto a navigation stack (as the Files browser's folders): the back swipe's edge pan is in the touch's
            // gesture graph and has to fail before the long press may begin
            let close = try await onMain { () throws -> () -> Void in
                let nav = UINavigationController(rootViewController: UIViewController())
                nav.pushViewController(P16CollectionVC(log: log), animated: false)
                return try p6Show(nav).1
            }
            defer { Task { @MainActor in close() } }
            guard wait > 0 else { return "collection view with a cell context menu on screen (SDKCOV_INPUT_WAIT unset: no long press awaited)" }
            let shown = await p6Wait(wait) { p13Labels().contains("SDKCovCellTwo") }
            try expect(shown, "no context menu in \(Int(wait)) s (cell events \(log.all))")
            try expect(!log.has("select"), "the long press also selected the cell (events \(log.all))")
            return "long press opened the cell's menu (events \(log.all.filter { !$0.hasPrefix("began") }))"
        })
        #endif
        #if os(iOS)
        // MARK: FileProviderUI: the Files app hands the app's File Provider UI extension (ext/FPAction.swift) the error of
        // its location. With no domain added, Files shows the replicated extension's default location as "Authentication
        // Required" and runs the extension's prepare(forError:) with NSFileProviderError notAuthenticated (-1000), Apple's
        // simulator and x86Sim alike. (The extension's custom action, NSExtensionFileProviderActions, is in no item's
        // context menu in Apple's iOS 27.2 Files: not reachable by touch.) The app opens Files (shareddocuments:); the
        // host (inputs.sh fpauth / ref-mac.sh INPUT) dismisses Apple's first-launch keyboard tip, goes Browse > sdkcov
        c.append(check("FileProviderUI", "input-files-authentication-error", timeout: 200) {
            let wait = touchWait16
            guard wait > 0 else { return "SDKCOV_INPUT_WAIT unset: no Files visit awaited" }
            // with --only the check starts while the app launches: Files opens over an active app
            _ = await p6Wait(30) { UIApplication.shared.applicationState == .active }
            let t0 = Date()
            try? await NSFileProviderManager.removeAllDomains()
            let bg = await onMain { UIApplication.shared.beginBackgroundTask(withName: "sdkcov-fpauth") {} }
            defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }
            let ob = P7Box<Bool>()
            await onMain { UIApplication.shared.open(URL(string: "shareddocuments://")!) { ob.set($0) } }
            let opened = await ob.wait(20) ?? false
            try expect(opened, "shareddocuments: not opened")
            let end = Date().addingTimeInterval(wait)
            while Date() < end && p3Marks("fpaction-error", since: t0).isEmpty && p3Marks("fpaction-prepare", since: t0).isEmpty {
                try await Task.sleep(for: .milliseconds(500))
            }
            let prep = p3Marks("fpaction-prepare", since: t0), err = p3Marks("fpaction-error", since: t0)
            try expect(prep.isEmpty, "the extension was asked for an action: \(prep)")
            try expect(err.first == "NSFileProviderErrorDomain -1000", "the extension's error from Files in \(Int(wait)) s: \(err) (fp marks \(p3Marks("fp-init", since: t0)))")
            return "Files handed the File Provider UI extension its location's error: \(err.first ?? "")"
        })
        #endif
        return c
    }
}
