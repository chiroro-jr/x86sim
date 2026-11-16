// sdkcov P6 (UI frameworks depth & platform UI): UIKit depth on iOS/iPadOS, tvOS and visionOS. Compositional layouts +
// diffable data sources checked by layout frames and cell pixels, navigation / tab (UITab) / page / search controllers
// by callback order, sheet detents by frames, text input through UITextInput + find, menus, pickers, traits (dark mode,
// Dynamic Type, custom traits) by pixels, accessibility custom actions / rotors, UIUpdateLink, printing answers.
// Each check verified against Apple's simulator (ref-mac.sh). Shared P6 helpers live here (p6*).
import Foundation
import Synchronization
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: helpers shared by the P6 files

/// poll `cond` on the main actor every 30 ms for up to `secs`
func p6Wait(_ secs: Double, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if await MainActor.run(body: { cond() }) { return true }; try? await Task.sleep(for: .milliseconds(30)) }
    return await MainActor.run(body: { cond() })
}
/// run an async body on the main actor
func p6A<T>(_ f: @escaping @MainActor () async throws -> T) async throws -> T { try await Task { @MainActor in try await f() }.value }
func p6Near(_ p: [Int], _ q: [Int], _ tol: Int = 16) -> Bool { zip(p.prefix(3), q).allSatisfy { abs($0 - $1) <= tol } }
/// RGBA of an image's pixel (top-left origin), through an sRGB RGBA8 bitmap
func p6Px(_ img: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return pixel(ctx, x, y).map(Int.init)
}
/// thread-safe event log (callback order)
final class P6Log: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
    func clear() { lock.withLock { items.removeAll() } }
    func has(_ s: String) -> Bool { all.contains(s) }
}

/// put a SwiftUI view on screen: a UIHostingController in its own window (watchOS: Runner.overlay); returns the take-down
@MainActor func p6HostSwiftUI<V: View>(_ v: V, size: CGSize? = nil) throws -> () -> Void {
    #if os(watchOS)
    Runner.shared.overlay = AnyView(v)
    return { Runner.shared.overlay = nil }
    #else
    let hc = UIHostingController(rootView: v)
    let (_, close) = try p6Show(hc)
    return close
    #endif
}

#if !os(watchOS)
@MainActor func p6Scene() throws -> UIWindowScene {
    guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw Fail("no window scene") }
    return ws
}
/// show `vc` full screen in a new window above the app's own; the closure takes it down
@MainActor func p6Show(_ vc: UIViewController) throws -> (UIWindow, () -> Void) {
    let ws = try p6Scene()
    let w = UIWindow(windowScene: ws); w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
    w.rootViewController = vc; w.isHidden = false; w.makeKey(); w.layoutIfNeeded()
    p6LastWindow = w
    return (w, { w.isHidden = true; w.rootViewController = nil })
}
/// the window p6Show made last (p6HostSwiftUI's)
@MainActor var p6LastWindow: UIWindow?
/// the scene's windows, for failure messages
@MainActor func p6Windows() -> String {
    ((try? p6Scene())?.windows ?? []).map { "\(type(of: $0))@\($0.windowLevel.rawValue)\($0.isHidden ? " hidden" : "")\($0.isKeyWindow ? " key" : "") root \($0.rootViewController.map { "\(type(of: $0))" } ?? "nil")" }.joined(separator: "; ")
}
/// the view's pixels as the screen shows them (drawHierarchy after a commit), scale 1
@MainActor func p6Snap(_ v: UIView) -> CGImage? {
    let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
    return UIGraphicsImageRenderer(bounds: v.bounds, format: f).image { _ in _ = v.drawHierarchy(in: v.bounds, afterScreenUpdates: true) }.cgImage
}
/// every subview (depth first) of type T
@MainActor func p6Find<T>(_ v: UIView, _ t: T.Type) -> [T] {
    var out: [T] = []
    func walk(_ v: UIView) { if let x = v as? T { out.append(x) }; v.subviews.forEach(walk) }
    walk(v); return out
}
/// a view controller logging its appearance callbacks as "<name>.<event>" into a shared log
final class P6TrackVC: UIViewController {
    let name: String, log: P6Log, color: UIColor
    init(_ name: String, _ color: UIColor, _ log: P6Log) { self.name = name; self.color = color; self.log = log; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = color }
    override func viewWillAppear(_ a: Bool) { super.viewWillAppear(a); log.add("\(name).willAppear") }
    override func viewDidAppear(_ a: Bool) { super.viewDidAppear(a); log.add("\(name).didAppear") }
    override func viewWillDisappear(_ a: Bool) { super.viewWillDisappear(a); log.add("\(name).willDisappear") }
    override func viewDidDisappear(_ a: Bool) { super.viewDidDisappear(a); log.add("\(name).didDisappear") }
}
let p6Red = UIColor(red: 1, green: 0, blue: 0, alpha: 1), p6Green = UIColor(red: 0, green: 1, blue: 0, alpha: 1), p6Blue = UIColor(red: 0, green: 0, blue: 1, alpha: 1)

/// UINavigationControllerDelegate logging willShow/didShow
final class P6NavDelegate: NSObject, UINavigationControllerDelegate {
    let log: P6Log; init(_ l: P6Log) { log = l }
    func navigationController(_ n: UINavigationController, willShow vc: UIViewController, animated: Bool) { log.add("nav.willShow.\((vc as? P6TrackVC)?.name ?? "?")") }
    func navigationController(_ n: UINavigationController, didShow vc: UIViewController, animated: Bool) { log.add("nav.didShow.\((vc as? P6TrackVC)?.name ?? "?")") }
}
final class P6SearchUpdater: NSObject, UISearchResultsUpdating, UISearchControllerDelegate {
    var texts: [String] = []; let log: P6Log; init(_ l: P6Log) { log = l }
    func updateSearchResults(for s: UISearchController) { texts.append(s.searchBar.text ?? "") }
    func willPresentSearchController(_ s: UISearchController) { log.add("search.willPresent") }
    func didPresentSearchController(_ s: UISearchController) { log.add("search.didPresent") }
    func willDismissSearchController(_ s: UISearchController) { log.add("search.willDismiss") }
    func didDismissSearchController(_ s: UISearchController) { log.add("search.didDismiss") }
}
final class P6PageSource: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let pages: [UIViewController]; init(_ p: [UIViewController]) { pages = p }
    func pageViewController(_ p: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let i = pages.firstIndex(of: vc), i > 0 else { return nil }; return pages[i - 1]
    }
    func pageViewController(_ p: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let i = pages.firstIndex(of: vc), i + 1 < pages.count else { return nil }; return pages[i + 1]
    }
}
final class P6TabDelegate: NSObject, UITabBarControllerDelegate {
    let log: P6Log; init(_ l: P6Log) { log = l }
    func tabBarController(_ t: UITabBarController, shouldSelectTab tab: UITab) -> Bool { log.add("shouldSelect.\(tab.identifier)"); return true }
    func tabBarController(_ t: UITabBarController, didSelectTab tab: UITab, previousTab: UITab?) { log.add("didSelect.\(tab.identifier).from.\(previousTab?.identifier ?? "nil")") }
}
#if os(iOS) || os(visionOS)
final class P6EditMenuDelegate: NSObject, UIEditMenuInteractionDelegate {
    let log: P6Log; var deferredCalls = 0; init(_ l: P6Log) { log = l }
    func editMenuInteraction(_ i: UIEditMenuInteraction, menuFor c: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        log.add("menuFor.\(c.identifier as? String ?? "?").suggested.\(suggestedActions.isEmpty ? 0 : 1)")
        let deferred = UIDeferredMenuElement.uncached { [weak self] done in self?.deferredCalls += 1; done([UIAction(title: "Later") { _ in }]) }
        return UIMenu(children: [UIAction(title: "Archive", image: UIImage(systemName: "archivebox")) { _ in }, deferred] + suggestedActions)
    }
    func editMenuInteraction(_ i: UIEditMenuInteraction, willPresentMenuFor c: UIEditMenuConfiguration, animator: UIEditMenuInteractionAnimating) { log.add("willPresent") }
    func editMenuInteraction(_ i: UIEditMenuInteraction, willDismissMenuFor c: UIEditMenuConfiguration, animator: UIEditMenuInteractionAnimating) { log.add("willDismiss") }
}
#endif
#if os(iOS)
final class P6SheetDelegate: NSObject, UISheetPresentationControllerDelegate {
    let log: P6Log; init(_ l: P6Log) { log = l }
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ s: UISheetPresentationController) { log.add("detent.\(s.selectedDetentIdentifier?.rawValue ?? "nil")") }
    func presentationControllerDidDismiss(_ p: UIPresentationController) { log.add("didDismiss") }
}
#endif
#if os(iOS) || os(visionOS)
/// collects UITextSearching results: implements the ObjC UITextSearchAggregator protocol's methods (Swift only sees the
/// overlay struct, which has no public initializer)
final class P6SearchAggregator: NSObject {
    var ranges: [UITextRange] = []; var finished = false
    @objc var allFoundRanges: NSOrderedSet { NSOrderedSet(array: ranges) }
    @objc(foundRange:forSearchString:inDocument:) func foundRange(_ range: UITextRange, searchString: String, document: AnyObject?) { ranges.append(range) }
    @objc(invalidateFoundRange:inDocument:) func invalidateFoundRange(_ range: UITextRange, document: AnyObject?) {}
    @objc func invalidate() { ranges.removeAll() }
    @objc func finishedSearching() { finished = true }
    /// -[target performTextSearchWithQueryString:usingOptions:resultAggregator:]
    @MainActor func search(_ target: NSObject, _ q: String) {
        if let pr = objc_getProtocol("UITextSearchAggregator") { class_addProtocol(P6SearchAggregator.self, pr) }
        let sel = NSSelectorFromString("performTextSearchWithQueryString:usingOptions:resultAggregator:")
        typealias F = @convention(c) (AnyObject, Selector, NSString, UITextSearchOptions, AnyObject) -> Void
        unsafeBitCast(target.method(for: sel), to: F.self)(target, sel, q as NSString, UITextSearchOptions(), self)
    }
}
final class P6PickerSource: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in p: UIPickerView) -> Int { 2 }
    func pickerView(_ p: UIPickerView, numberOfRowsInComponent c: Int) -> Int { c == 0 ? 10 : 3 }
    func pickerView(_ p: UIPickerView, titleForRow r: Int, forComponent c: Int) -> String? { "\(c):\(r)" }
}
#endif
/// a custom trait (UITraitDefinition) inherited down the hierarchy
struct P6Theme: UITraitDefinition { static let defaultValue = 0; static let name = "SDKCovTheme" }
#endif

extension Registry {
    static var p6: [Check] { p6_uikit + p6_swiftui + p6_docs + p6_web }

    static var p6_uikit: [Check] {
        var c: [Check] = []
        #if os(iOS) || os(tvOS) || os(visionOS)
        // MARK: compositional layout + diffable data source: frames and cell pixels
        c.append(check("UIKit", "compositional-grid-orthogonal-diffable-pixels", timeout: 40) {
            try await p6A { () async throws -> String in
                let cols: [UIColor] = [p6Red, p6Green, p6Blue]
                let layout = UICollectionViewCompositionalLayout { sec, env in
                    if sec == 0 {   // a 3-column grid of 60 pt rows under a 30 pt header
                        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1.0 / 3), heightDimension: .fractionalHeight(1)))
                        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(60)), repeatingSubitem: item, count: 3)
                        let s = NSCollectionLayoutSection(group: group)
                        let h = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(30)), elementKind: "hdr", alignment: .top)
                        s.boundarySupplementaryItems = [h]
                        s.contentInsetsReference = .none; s.supplementaryContentInsetsReference = .none   // tvOS: else inset by the layout margins
                        return s
                    }
                    // a horizontally scrolling row of 100x50 cells, 10 pt apart
                    let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
                    let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(100), heightDimension: .absolute(50)), subitems: [item])
                    let s = NSCollectionLayoutSection(group: group); s.orthogonalScrollingBehavior = .continuous; s.interGroupSpacing = 10
                    s.contentInsetsReference = .none
                    return s
                }
                let cv = UICollectionView(frame: CGRect(x: 0, y: 0, width: 300, height: 400), collectionViewLayout: layout)
                cv.backgroundColor = .white; cv.contentInsetAdjustmentBehavior = .never
                var configured = 0
                let reg = UICollectionView.CellRegistration<UICollectionViewCell, Int> { cell, _, n in
                    configured += 1
                    cell.backgroundConfiguration = .clear(); cell.contentView.backgroundColor = cols[n % 3]
                }
                let hreg = UICollectionView.SupplementaryRegistration<UICollectionReusableView>(elementKind: "hdr") { v, _, _ in v.backgroundColor = .black }
                let ds = UICollectionViewDiffableDataSource<Int, Int>(collectionView: cv) { cv, ip, n in cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: n) }
                ds.supplementaryViewProvider = { cv, k, ip in cv.dequeueConfiguredReusableSupplementary(using: hreg, for: ip) }
                var snap = NSDiffableDataSourceSnapshot<Int, Int>(); snap.appendSections([0, 1])
                snap.appendItems(Array(0..<9), toSection: 0); snap.appendItems(Array(100..<120), toSection: 1)
                await ds.apply(snap, animatingDifferences: false)
                let vc = UIViewController(); vc.view.backgroundColor = .white; vc.view.addSubview(cv)
                let (w, close) = try p6Show(vc); defer { close() }
                w.layoutIfNeeded(); cv.layoutIfNeeded()
                @MainActor func fr(_ i: Int, _ s: Int) -> CGRect { cv.layoutAttributesForItem(at: IndexPath(item: i, section: s))?.frame.integral ?? .null }
                let hdr = cv.layoutAttributesForSupplementaryElement(ofKind: "hdr", at: IndexPath(item: 0, section: 0))?.frame.integral ?? .null
                try expect(hdr == CGRect(x: 0, y: 0, width: 300, height: 30), "header \(hdr)")
                try expect(fr(0, 0) == CGRect(x: 0, y: 30, width: 100, height: 60) && fr(1, 0) == CGRect(x: 100, y: 30, width: 100, height: 60) && fr(5, 0) == CGRect(x: 200, y: 90, width: 100, height: 60),
                           "grid frames \(fr(0, 0)) \(fr(1, 0)) \(fr(5, 0))")
                try expect(fr(0, 1) == CGRect(x: 0, y: 210, width: 100, height: 50) && fr(3, 1).minX == 330, "orthogonal row \(fr(0, 1)) \(fr(3, 1))")
                // the cells as the screen shows them
                guard let img = p6Snap(cv) else { throw Fail("no snapshot") }
                let s = img.width / 300
                @MainActor func at(_ x: Int, _ y: Int) -> [Int] { p6Px(img, x * s, y * s) }
                let px = [at(50, 60), at(150, 60), at(250, 60), at(50, 120), at(150, 15), at(150, 235), at(50, 235)]
                try expect(p6Near(px[0], [255, 0, 0]) && p6Near(px[1], [0, 255, 0]) && p6Near(px[2], [0, 0, 255]) && p6Near(px[3], [255, 0, 0]) && px[4].prefix(3).allSatisfy { $0 < 80 } && p6Near(px[5], [0, 0, 255]) && p6Near(px[6], [0, 255, 0]),
                           "cell pixels \(px)")
                // diff: delete + move; reconfigure re-runs the registration for that item only
                let before = configured
                var s2 = ds.snapshot(); s2.deleteItems([0]); s2.moveItem(8, beforeItem: 1); s2.reconfigureItems([2])
                await ds.apply(s2, animatingDifferences: false); cv.layoutIfNeeded()
                try expect(ds.indexPath(for: 8) == IndexPath(item: 0, section: 0) && ds.itemIdentifier(for: IndexPath(item: 1, section: 0)) == 1, "after diff: \(ds.snapshot().itemIdentifiers(inSection: 0))")
                guard let img2 = p6Snap(cv) else { throw Fail("no snapshot 2") }
                let p8 = p6Px(img2, 50 * s, 60 * s)
                try expect(p6Near(p8, [0, 0, 255]), "item 8 (blue) now first: \(p8)")
                // an outline (section snapshot): collapsed children are not items of the data source
                var sec = NSDiffableDataSourceSectionSnapshot<Int>()
                sec.append([200, 300]); sec.append([201, 202, 203], to: 200); sec.append([301], to: 300)
                await ds.apply(sec, to: 1, animatingDifferences: false)
                let collapsed = ds.snapshot().numberOfItems(inSection: 1)
                sec.expand([200]); await ds.apply(sec, to: 1, animatingDifferences: false)
                let expanded = ds.snapshot().numberOfItems(inSection: 1)
                try expect(collapsed == 2 && expanded == 5 && sec.level(of: 202) == 1 && sec.parent(of: 301) == 300, "outline: collapsed \(collapsed) expanded \(expanded)")
                return "grid/header/orthogonal frames exact, 6 cell pixels, diff + reconfigure (\(configured - before) configured), outline 2 -> 5 items"
            }
        })

        // MARK: navigation controller: push / pop callback order, nav delegate
        c.append(check("UIKit", "navigation-callback-order-bar-items", timeout: 40) {
            let log = P6Log()
            let (nav, del, a, b, close) = try await onMain { () -> (UINavigationController, P6NavDelegate, P6TrackVC, P6TrackVC, () -> Void) in
                let a = P6TrackVC("a", p6Red, log), b = P6TrackVC("b", p6Green, log)
                a.navigationItem.title = "Root"; b.navigationItem.title = "Detail"
                b.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Edit", style: .plain, target: nil, action: nil)
                let nav = UINavigationController(rootViewController: a); let del = P6NavDelegate(log); nav.delegate = del
                let (_, close) = try p6Show(nav)
                return (nav, del, a, b, close)
            }
            defer { Task { @MainActor in close() } }
            _ = del
            try await expect(p6Wait(5) { log.has("a.didAppear") }, "root never appeared: \(log.all)")
            log.clear()
            await onMain { nav.pushViewController(b, animated: true) }
            try await expect(p6Wait(5) { log.has("nav.didShow.b") && log.has("a.didDisappear") }, "push: \(log.all)")
            let push = log.all; log.clear()
            let barTitle = await onMain { nav.navigationBar.topItem?.title }
            let back = await onMain { nav.navigationBar.backItem?.title }
            await onMain { _ = nav.popViewController(animated: true) }
            try await expect(p6Wait(5) { log.has("nav.didShow.a") && log.has("b.didDisappear") }, "pop: \(log.all)")
            let pop = log.all
            let expPush = ["a.willDisappear", "b.willAppear", "nav.willShow.b", "a.didDisappear", "b.didAppear", "nav.didShow.b"]
            let expPop = ["b.willDisappear", "a.willAppear", "nav.willShow.a", "b.didDisappear", "a.didAppear", "nav.didShow.a"]
            try expect(Set(push) == Set(expPush) && push.firstIndex(of: "b.willAppear")! < push.firstIndex(of: "b.didAppear")! && push.last == "nav.didShow.b" || push == expPush, "push order \(push)")
            try expect(Set(pop) == Set(expPop) && pop.last == "nav.didShow.a" || pop == expPop, "pop order \(pop)")
            try expect(barTitle == "Detail" && back == "Root", "bar: top \(String(describing: barTitle)) back \(String(describing: back))")
            let n = await onMain { nav.viewControllers.count }
            try expect(n == 1, "stack after pop \(n)")
            _ = a
            return "push \(push.joined(separator: ",")); pop \(pop.joined(separator: ","))"
        })

        // MARK: UITab-based tab bar controller (iOS 18 / tvOS 18 / visionOS 2 API)
        c.append(check("UIKit", "tabbar-uitab-group-search-selection", timeout: 40) {
            let log = P6Log()
            return try await p6A { () async throws -> String in
                let ta = UITab(title: "Red", image: UIImage(systemName: "a.circle"), identifier: "red") { _ in P6TrackVC("red", p6Red, log) }
                let tb = UITab(title: "Green", image: UIImage(systemName: "b.circle"), identifier: "green") { _ in P6TrackVC("green", p6Green, log) }
                let sub = UITab(title: "Blue", image: UIImage(systemName: "c.circle"), identifier: "blue") { _ in P6TrackVC("blue", p6Blue, log) }
                let group = UITabGroup(title: "More", image: UIImage(systemName: "folder"), identifier: "group", children: [sub]) { _ in UIViewController() }
                let search = UISearchTab { _ in UINavigationController(rootViewController: UIViewController()) }
                let t = UITabBarController(tabs: [ta, tb, group, search])
                let del = P6TabDelegate(log); t.delegate = del
                let (_, close) = try p6Show(t); defer { close(); _ = del }
                try await expect(p6Wait(5) { log.has("red.didAppear") }, "first tab never appeared: \(log.all)")
                try expect(t.selectedTab?.identifier == "red" && t.tabs.count == 4 && t.tab(forIdentifier: "blue") === sub && sub.parent === group, "tabs \(t.tabs.map(\.identifier)) selected \(String(describing: t.selectedTab?.identifier))")
                log.clear()
                t.selectedTab = tb
                try await expect(p6Wait(5) { log.has("green.didAppear") }, "green never appeared: \(log.all)")
                let sel = t.selectedViewController as? P6TrackVC
                try expect(sel?.name == "green" && t.selectedTab === tb, "selected vc \(String(describing: sel?.name))")
                // the selected tab's content on screen
                guard let w = t.view.window, let img = p6Snap(w) else { throw Fail("no snapshot") }
                let mid = p6Px(img, img.width / 2, img.height / 2)
                try expect(p6Near(mid, [0, 255, 0]), "green tab content at the window centre: \(mid)")
                // the tab bar's own items: one per top-level tab (the search tab included)
                let items = t.tabBar.items?.count ?? -1
                // programmatic selection does not ask the delegate
                let delegateCalls = log.all.filter { $0.hasPrefix("shouldSelect") || $0.hasPrefix("didSelect") }
                return "4 tabs (group + search), select green: content \(mid.prefix(3)), bar items \(items), delegate calls \(delegateCalls), mode \(t.mode.rawValue)"
            }
        })

        // MARK: page view controller + search controller
        c.append(check("UIKit", "page-and-search-controllers", timeout: 40) {
            let log = P6Log()
            return try await p6A { () async throws -> String in
                let pages = [P6TrackVC("p0", p6Red, log), P6TrackVC("p1", p6Green, log), P6TrackVC("p2", p6Blue, log)]
                let pvc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
                let src = P6PageSource(pages); pvc.dataSource = src; pvc.delegate = src
                pvc.setViewControllers([pages[0]], direction: .forward, animated: false)
                let (w, close) = try p6Show(pvc); defer { close(); _ = src }
                try await expect(p6Wait(5) { log.has("p0.didAppear") }, "first page never appeared \(log.all)")
                var done: Bool?
                pvc.setViewControllers([pages[1]], direction: .forward, animated: true) { done = $0 }
                try await expect(p6Wait(5) { done != nil && log.has("p1.didAppear") }, "page turn: completion \(String(describing: done)), \(log.all)")
                try expect(pvc.viewControllers?.first === pages[1] && done == true, "current page")
                guard let img = p6Snap(w) else { throw Fail("snapshot") }
                let mid = p6Px(img, img.width / 2, img.height / 2)
                try expect(p6Near(mid, [0, 255, 0]), "page 1 on screen: \(mid)")
                let after = src.pageViewController(pvc, viewControllerAfter: pages[2]), before = src.pageViewController(pvc, viewControllerBefore: pages[1])
                try expect(after == nil && before === pages[0], "data source ends")
                close()
                // search controller in a navigation item: activation and text updates reach the updater
                let up = P6SearchUpdater(log)
                let root = UIViewController(); root.view.backgroundColor = .white; root.title = "Search"
                #if os(tvOS)   // tvOS requires a results controller
                let sc = UISearchController(searchResultsController: UIViewController())
                #else
                let sc = UISearchController(searchResultsController: nil)
                #endif
                sc.searchResultsUpdater = up; sc.delegate = up
                sc.obscuresBackgroundDuringPresentation = false
                #if os(tvOS)   // tvOS: the search controller is the content of a UISearchContainerViewController
                let nav = UISearchContainerViewController(searchController: sc)
                #else
                root.navigationItem.searchController = sc; root.navigationItem.hidesSearchBarWhenScrolling = false
                let nav = UINavigationController(rootViewController: root)
                #endif
                let (_, close2) = try p6Show(nav); defer { close2(); _ = up }
                try await Task.sleep(for: .milliseconds(400))
                log.clear()
                sc.isActive = true
                _ = await p6Wait(5) { log.has("search.didPresent") }
                sc.searchBar.text = "x86"
                sc.searchResultsUpdater?.updateSearchResults(for: sc)
                let active = sc.isActive, events = log.all
                sc.isActive = false
                _ = await p6Wait(5) { log.has("search.didDismiss") }
                #if os(tvOS)   // tvOS: the search container never calls the will/did present delegate methods (Apple's too)
                try expect(active && up.texts.contains("x86"), "search: active \(active), events \(events), updates \(up.texts)")
                #else
                try expect(active && events.starts(with: ["search.willPresent", "search.didPresent"]) && up.texts.contains("x86"), "search: active \(active), events \(events), updates \(up.texts)")
                #endif
                return "page turn completion, page 1 pixels; search \(log.all.joined(separator: ",")), updates \(up.texts)"
            }
        })

        // MARK: traits: dark mode, custom traits, Dynamic Type, by pixels and callbacks
        c.append(check("UIKit", "traits-dark-mode-dynamic-type-pixels", timeout: 40) {
            try await p6A { () async throws -> String in
                let dyn = UIColor { $0.userInterfaceStyle == .dark ? p6Red : p6Blue }
                let themed = UIColor { $0[P6Theme.self] == 1 ? p6Green : UIColor.white }
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let box = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100)); box.backgroundColor = dyn
                let box2 = UIView(frame: CGRect(x: 100, y: 0, width: 100, height: 100)); box2.backgroundColor = themed
                let lbl = UILabel(frame: CGRect(x: 0, y: 120, width: 300, height: 40)); lbl.text = "Dynamic"
                lbl.font = .preferredFont(forTextStyle: .body); lbl.adjustsFontForContentSizeCategory = true
                [box, box2, lbl].forEach { vc.view.addSubview($0) }
                var changes: [String] = []
                box.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: UIView, prev: UITraitCollection) in changes.append("style \(prev.userInterfaceStyle.rawValue)->\(v.traitCollection.userInterfaceStyle.rawValue)") }
                vc.traitOverrides.userInterfaceStyle = .light
                let (_, close) = try p6Show(vc); defer { close() }
                vc.view.layoutIfNeeded()
                guard let l = p6Snap(vc.view) else { throw Fail("snapshot") }
                let lightPx = p6Px(l, 50, 50), plain = p6Px(l, 150, 50)
                let body0 = lbl.font.pointSize
                changes.removeAll()
                vc.traitOverrides.userInterfaceStyle = .dark
                vc.traitOverrides[P6Theme.self] = 1
                vc.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                vc.view.layoutIfNeeded()
                guard let d = p6Snap(vc.view) else { throw Fail("snapshot") }
                let darkPx = p6Px(d, 50, 50), themedPx = p6Px(d, 150, 50)
                let body1 = lbl.font.pointSize
                try expect(p6Near(lightPx, [0, 0, 255]) && p6Near(darkPx, [255, 0, 0]), "dynamic colour light \(lightPx) dark \(darkPx)")
                try expect(p6Near(plain, [255, 255, 255]) && p6Near(themedPx, [0, 255, 0]) && box2.traitCollection[P6Theme.self] == 1, "custom trait colour \(plain) -> \(themedPx)")
                try expect(changes == ["style 1->2"], "trait change callbacks \(changes)")
                try expect(body1 > body0 * 1.5, "Dynamic Type body \(body0) -> \(body1)")
                let resolved = dyn.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)) == p6Red
                try expect(resolved, "resolvedColor")
                return "light \(lightPx.prefix(3)) dark \(darkPx.prefix(3)), custom trait, callbacks \(changes), body \(body0) -> \(body1) pt"
            }
        })

        // MARK: accessibility: custom actions, rotors, container frames
        c.append(check("UIKit", "accessibility-custom-actions-rotor-frames", timeout: 30) {
            try await p6A { () async throws -> String in
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let v = UIView(frame: CGRect(x: 40, y: 60, width: 120, height: 80)); v.isAccessibilityElement = true; v.accessibilityLabel = "Card"
                var archived = 0
                v.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Archive", image: nil) { _ in archived += 1; return true },
                                                UIAccessibilityCustomAction(name: "Fail") { _ in false }]
                vc.view.addSubview(v)
                // two elements inside a container view, with frames in the container's space
                let cont = UIView(frame: CGRect(x: 10, y: 200, width: 200, height: 100)); vc.view.addSubview(cont)
                let e1 = UIAccessibilityElement(accessibilityContainer: cont); e1.accessibilityLabel = "one"; e1.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: 50, height: 20)
                let e2 = UIAccessibilityElement(accessibilityContainer: cont); e2.accessibilityLabel = "two"; e2.accessibilityFrameInContainerSpace = CGRect(x: 60, y: 30, width: 50, height: 20)
                cont.accessibilityElements = [e1, e2]
                // a rotor walking the container's elements
                let items = [e1, e2]
                let rotor = UIAccessibilityCustomRotor(name: "Items") { pred in
                    let cur = pred.currentItem.targetElement as? UIAccessibilityElement
                    let i = cur.flatMap { c in items.firstIndex { $0 === c } }
                    let next = pred.searchDirection == .next ? (i.map { $0 + 1 } ?? 0) : (i.map { $0 - 1 } ?? items.count - 1)
                    return items.indices.contains(next) ? UIAccessibilityCustomRotorItemResult(targetElement: items[next], targetRange: nil) : nil
                }
                vc.view.accessibilityCustomRotors = [rotor]
                let (w, close) = try p6Show(vc); defer { close() }
                w.layoutIfNeeded()
                let r1 = v.accessibilityCustomActions![0].actionHandler!(v.accessibilityCustomActions![0])
                let r2 = v.accessibilityCustomActions![1].actionHandler!(v.accessibilityCustomActions![1])
                try expect(r1 && !r2 && archived == 1, "custom actions \(r1) \(r2) \(archived)")
                let pred = UIAccessibilityCustomRotorSearchPredicate(); pred.searchDirection = .next
                pred.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: e1, targetRange: nil)
                let n1 = rotor.itemSearchBlock(pred)?.targetElement as? UIAccessibilityElement
                pred.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: e2, targetRange: nil)
                let n2 = rotor.itemSearchBlock(pred)
                pred.searchDirection = .previous
                let p1 = rotor.itemSearchBlock(pred)?.targetElement as? UIAccessibilityElement
                try expect(n1 === e2 && n2 == nil && p1 === e1, "rotor next \(String(describing: n1?.accessibilityLabel)) end \(String(describing: n2)) previous \(String(describing: p1?.accessibilityLabel))")
                // frames: container space -> screen coordinates
                // (accessibilityFrame itself is only computed while an assistive technology runs: 0 on Apple's simulator)
                let f2 = UIAccessibility.convertToScreenCoordinates(e2.accessibilityFrameInContainerSpace, in: cont), wantOrigin = cont.convert(CGPoint(x: 60, y: 30), to: nil)
                #if os(visionOS)
                let screenOrigin = wantOrigin
                #else
                let screenOrigin = w.convert(wantOrigin, to: w.screen.coordinateSpace)
                #endif
                // (Apple's simulator returns the rect unconverted while no assistive technology runs)
                let raw = CGRect(x: 60, y: 30, width: 50, height: 20)
                try expect((f2 == raw || (abs(f2.minX - screenOrigin.x) < 1 && abs(f2.minY - screenOrigin.y) < 1)) && f2.width == 50 && e2.accessibilityFrameInContainerSpace == raw, "element frame \(f2) vs \(screenOrigin)")
                // (accessibilityElementCount() and friends answer 0 / NSNotFound until UIKit's accessibility bundle loads with an AT)
                try expect(cont.accessibilityElements?.count == 2 && e2.accessibilityContainer === cont, "container elements \(cont.accessibilityElements?.count ?? -1)")
                // UIAccessibility queries the simulator answers (no assistive technology running)
                let vo = UIAccessibility.isVoiceOverRunning, sw = UIAccessibility.isSwitchControlRunning
                try expect(!vo && !sw, "VoiceOver \(vo) Switch Control \(sw)")
                return "2 custom actions, rotor next/end/previous, element frame \(f2.integral), VO off"
            }
        })
        #endif

        #if os(iOS)
        // MARK: sheet detents: frames per detent (visionOS: no detents)
        c.append(check("UIKit", "sheet-detents-frames", timeout: 40) {
            let log = P6Log()
            return try await p6A { () async throws -> String in
                let root = P6TrackVC("root", .white, log)
                let (w, close) = try p6Show(root); defer { close() }
                try await expect(p6Wait(5) { log.has("root.didAppear") }, "root")
                let sheet = P6TrackVC("sheet", p6Green, log)
                let small = UISheetPresentationController.Detent.Identifier("small")
                let del = P6SheetDelegate(log)
                if let sp = sheet.sheetPresentationController {
                    sp.detents = [.custom(identifier: small) { _ in 200 }, .medium(), .large()]
                    sp.selectedDetentIdentifier = small; sp.prefersGrabberVisible = true; sp.delegate = del
                    sp.largestUndimmedDetentIdentifier = .medium
                }
                var shown = false
                root.present(sheet, animated: true) { shown = true }
                try await expect(p6Wait(5) { shown && log.has("sheet.didAppear") }, "sheet: \(log.all)")
                try await Task.sleep(for: .milliseconds(300))
                let H = w.bounds.height
                func vis() -> CGRect { sheet.view.convert(sheet.view.bounds, to: w).integral }
                let f0 = vis(), safe0 = sheet.view.safeAreaInsets.bottom
                let compact = w.traitCollection.horizontalSizeClass == .compact
                sheet.sheetPresentationController?.animateChanges { sheet.sheetPresentationController?.selectedDetentIdentifier = .medium }
                try await Task.sleep(for: .milliseconds(700))
                let f1 = vis()
                sheet.sheetPresentationController?.animateChanges { sheet.sheetPresentationController?.selectedDetentIdentifier = .large }
                try await Task.sleep(for: .milliseconds(700))
                let f2 = vis()
                let det = sheet.sheetPresentationController?.selectedDetentIdentifier?.rawValue ?? "nil"
                var gone = false
                sheet.dismiss(animated: true) { gone = true }
                _ = await p6Wait(5) { gone }
                let desc = "window h \(Int(H)) compact \(compact): small \(f0) (safe \(safe0)), medium \(f1), large \(f2), selected \(det), delegate \(log.all.filter { $0.hasPrefix("detent") })"
                if compact {
                    // custom detent: 200 pt above the bottom safe area; medium about half; large near full height
                    // (iOS 26 sheets float: inset from the screen edges; the custom height sits between 200 and 200 + safe area)
                    try expect(f0.height >= 199 && f0.height <= 201 + safe0 && f0.maxY >= H - 10, "small detent: \(desc)")
                    try expect(f1.height > f0.height + 50 && abs(f1.height - H / 2) < H * 0.12, "medium detent: \(desc)")
                    try expect(f2.height > f1.height + 50 && f2.minY < H * 0.2, "large detent: \(desc)")
                } else {
                    try expect(f0.height > 0 && f2.height >= f0.height, "regular-width sheet: \(desc)")
                }
                try expect(det == "com.apple.UIKit.large" && gone, "selected \(det), dismissed \(gone)")
                return desc
            }
        })

        #endif
        #if os(iOS) || os(visionOS)
        // MARK: edit menu interaction + UIMenu / UIAction / deferred elements
        c.append(check("UIKit", "menus-edit-menu-actions-deferred", timeout: 30) {
            let log = P6Log()
            return try await p6A { () async throws -> String in
                // a UIMenu tree: actions with state and attributes, an inline submenu, replacingChildren
                var fired: [String] = []
                let a1 = UIAction(title: "Bold", state: .on) { _ in fired.append("bold") }
                let a2 = UIAction(title: "Delete", attributes: .destructive) { _ in fired.append("delete") }
                let inline = UIMenu(title: "", options: .displayInline, children: [a2])
                let m = UIMenu(title: "Format", children: [a1, inline])
                try expect(m.children.count == 2 && (m.children[1] as? UIMenu)?.options.contains(.displayInline) == true && a1.state == .on && a2.attributes.contains(.destructive), "menu tree")
                let m2 = m.replacingChildren([a2]); try expect(m2.children.count == 1 && m.children.count == 2, "replacingChildren")
                // a button's primary action runs on .primaryActionTriggered; menu button state
                let b = UIButton(configuration: .filled(), primaryAction: UIAction(title: "Go") { _ in fired.append("go") })
                b.sendActions(for: .primaryActionTriggered)
                let mb = UIButton(type: .system); mb.menu = m; mb.showsMenuAsPrimaryAction = true
                try expect(fired == ["go"] && mb.menu?.title == "Format" && mb.menu?.children.count == 2 && mb.showsMenuAsPrimaryAction, "primary action \(fired), button menu \(String(describing: mb.menu?.title))")
                // the edit menu: present at a point, delegate asked for the menu, presented, dismissed
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let target = UIView(frame: CGRect(x: 50, y: 200, width: 200, height: 100)); target.backgroundColor = .lightGray; vc.view.addSubview(target)
                let del = P6EditMenuDelegate(log)
                let emi = UIEditMenuInteraction(delegate: del); target.addInteraction(emi)
                let (_, close) = try p6Show(vc); defer { close(); _ = del }
                try await Task.sleep(for: .milliseconds(300))
                emi.presentEditMenu(with: UIEditMenuConfiguration(identifier: "sdkcov", sourcePoint: CGPoint(x: 100, y: 50)))
                try await expect(p6Wait(5) { log.has("willPresent") }, "edit menu never presented: \(log.all)")
                try await Task.sleep(for: .milliseconds(500))
                emi.dismissMenu()
                _ = await p6Wait(5) { log.has("willDismiss") }
                let ev = log.all
                try expect(ev.first?.hasPrefix("menuFor.sdkcov") == true && ev.contains("willPresent") && ev.last == "willDismiss", "edit menu events \(ev)")
                return "UIMenu tree, primary action, edit menu \(ev.joined(separator: ",")), deferred provider calls \(del.deferredCalls)"
            }
        })

        // MARK: text input: UITextInput geometry/editing, marked text, secure entry, find
        c.append(check("UIKit", "text-input-uitextinput-secure-find", timeout: 40) {
            try await p6A { () async throws -> String in
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let tv = UITextView(frame: CGRect(x: 20, y: 100, width: 300, height: 200)); tv.font = .systemFont(ofSize: 20)
                let tf = UITextField(frame: CGRect(x: 20, y: 320, width: 300, height: 40)); tf.isSecureTextEntry = true; tf.textContentType = .password; tf.borderStyle = .roundedRect
                vc.view.addSubview(tv); vc.view.addSubview(tf)
                let (_, close) = try p6Show(vc); defer { close() }
                try expect(tv.becomeFirstResponder(), "text view first responder")
                tv.insertText("hello world")
                guard let start = tv.position(from: tv.beginningOfDocument, offset: 6), let end = tv.position(from: start, offset: 5),
                      let r = tv.textRange(from: start, to: end) else { throw Fail("positions") }
                try expect(tv.text(in: r) == "world" && tv.offset(from: tv.beginningOfDocument, to: tv.endOfDocument) == 11, "text(in:) \(String(describing: tv.text(in: r)))")
                tv.replace(r, withText: "x86sim")
                try expect(tv.text == "hello x86sim" && tv.selectedRange == NSRange(location: 12, length: 0), "replace: '\(tv.text ?? "")' sel \(tv.selectedRange)")
                // geometry: carets move right along the line
                let c0 = tv.caretRect(for: tv.beginningOfDocument), c6 = tv.caretRect(for: tv.position(from: tv.beginningOfDocument, offset: 6)!)
                let fr = tv.firstRect(for: tv.textRange(from: tv.beginningOfDocument, to: tv.position(from: tv.beginningOfDocument, offset: 5)!)!)
                try expect(c6.minX > c0.minX + 30 && fr.width > 30 && fr.height >= 20, "caret 0 \(c0) 6 \(c6), first rect \(fr)")
                let hit = tv.closestPosition(to: CGPoint(x: c6.midX, y: c6.midY)).map { tv.offset(from: tv.beginningOfDocument, to: $0) }
                try expect(hit == 6, "closestPosition \(String(describing: hit))")
                // marked text (an input method's composition)
                tv.selectedRange = NSRange(location: 0, length: 0)
                tv.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
                let marked = tv.markedTextRange.flatMap { tv.text(in: $0) }
                tv.unmarkText()
                try expect(marked == "ni" && tv.markedTextRange == nil && tv.text.hasPrefix("nihello"), "marked \(String(describing: marked)), text \(tv.text ?? "")")
                tv.deleteBackward()
                try expect(tv.text.hasPrefix("nhello"), "deleteBackward: \(tv.text ?? "")")
                // find: UITextSearching over the text view's content
                tv.text = "one two one three one"
                // find: the system find navigator over the text view; its session counts and steps through matches
                tv.isFindInteractionEnabled = true
                tv.findInteraction?.searchText = "one"
                tv.findInteraction?.presentFindNavigator(showingReplace: false)
                _ = await p6Wait(5) { tv.findInteraction?.isFindNavigatorVisible == true && (tv.findInteraction?.activeFindSession?.resultCount ?? 0) > 0 }
                let navVisible = tv.findInteraction?.isFindNavigatorVisible == true
                let sess = tv.findInteraction?.activeFindSession
                let count = sess?.resultCount ?? -1, h0 = sess?.highlightedResultIndex ?? -9
                tv.findInteraction?.findNext()
                let h1 = sess?.highlightedResultIndex ?? -9
                tv.findInteraction?.findNext()
                let h2 = sess?.highlightedResultIndex ?? -9
                tv.findInteraction?.dismissFindNavigator()
                // and UITextSearching directly, with an aggregator object
                let agg = P6SearchAggregator()
                agg.search(tv, "one")
                _ = await p6Wait(3) { agg.finished || agg.ranges.count >= 3 }
                let offs = agg.ranges.map { tv.offset(from: tv.beginningOfDocument, to: $0.start) }.sorted()
                try expect(navVisible && count == 3 && h1 != h0 && h2 != h1, "find navigator visible \(navVisible), results \(count), highlighted \(h0) -> \(h1) -> \(h2); aggregator \(offs) finished \(agg.finished)")
                // secure entry: text kept, copy refused
                try expect(tf.becomeFirstResponder(), "text field first responder")
                tf.insertText("s3cret")
                let canCopy = tf.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil)
                try expect(tf.text == "s3cret" && tf.isSecureTextEntry && !canCopy, "secure text field: \(String(describing: tf.text)) copy \(canCopy)")
                tf.resignFirstResponder()
                return "UITextInput replace/caret/closestPosition/marked text, find navigator 3 results, highlighted \(h0)->\(h1)->\(h2), aggregator \(offs), secure entry"
            }
        })

        // MARK: pickers: date picker clamping / count-down, picker view, color + font pickers
        c.append(check("UIKit", "pickers-date-picker-color-font", timeout: 40) {
            try await p6A { () async throws -> String in
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let dp = UIDatePicker(frame: CGRect(x: 0, y: 80, width: 320, height: 216)); dp.datePickerMode = .date; dp.preferredDatePickerStyle = .wheels
                dp.timeZone = TimeZone(identifier: "UTC"); dp.locale = Locale(identifier: "en_US")
                let minD = Date(timeIntervalSince1970: 1_700_000_000), maxD = Date(timeIntervalSince1970: 1_800_000_000)
                dp.minimumDate = minD; dp.maximumDate = maxD
                let pv = UIPickerView(frame: CGRect(x: 0, y: 320, width: 320, height: 216)); let src = P6PickerSource(); pv.dataSource = src; pv.delegate = src
                vc.view.addSubview(dp); vc.view.addSubview(pv)
                let (_, close) = try p6Show(vc); defer { close(); _ = src }
                var changes = 0
                dp.addAction(UIAction { _ in changes += 1 }, for: .valueChanged)
                dp.setDate(Date(timeIntervalSince1970: 1_000_000_000), animated: false)
                let clampedLow = dp.date
                dp.setDate(Date(timeIntervalSince1970: 1_750_000_000), animated: false)
                let inside = dp.date
                try expect(inside == Date(timeIntervalSince1970: 1_750_000_000), "date inside range \(inside)")
                try expect(changes == 0, "programmatic setDate sends no valueChanged (\(changes))")
                dp.datePickerMode = .countDownTimer; dp.minuteInterval = 5
                dp.countDownDuration = 3600 + 7 * 60 + 30
                let cd = dp.countDownDuration
                pv.selectRow(7, inComponent: 0, animated: false); pv.selectRow(2, inComponent: 1, animated: false)
                try expect(pv.selectedRow(inComponent: 0) == 7 && pv.selectedRow(inComponent: 1) == 2 && pv.numberOfRows(inComponent: 0) == 10, "picker rows")
                // color picker: selected colour round trip, alpha support; font picker configuration
                let cp = UIColorPickerViewController(); cp.selectedColor = p6Red; cp.supportsAlpha = false
                let sel = cp.selectedColor.cgColor.components ?? []
                try expect(sel.count >= 3 && sel[0] > 0.99 && sel[1] < 0.01 && !cp.supportsAlpha, "color picker selected \(sel)")
                let fcfg = UIFontPickerViewController.Configuration(); fcfg.includeFaces = true; fcfg.displayUsingSystemFont = true
                let fp = UIFontPickerViewController(configuration: fcfg)
                try expect(fp.configuration.includeFaces && fp.selectedFontDescriptor == nil, "font picker configuration")
                return "date clamp low \(Int(clampedLow.timeIntervalSince1970)), inside exact, count-down 4050 -> \(Int(cd)), picker rows, color picker, font picker"
            }
        })

        // MARK: UIUpdateLink frame callbacks + printing answers
        c.append(check("UIKit", "update-link-printing", timeout: 30) {
            try await p6A { () async throws -> String in
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let v = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 50)); v.backgroundColor = .orange; vc.view.addSubview(v)
                let (_, close) = try p6Show(vc); defer { close() }
                var n = 0, times: [Double] = []
                let link = UIUpdateLink(view: v)
                link.addAction { l, info in n += 1; times.append(info.modelTime); v.center.x = CGFloat(n) }
                link.requiresContinuousUpdates = true; link.isEnabled = true
                try await Task.sleep(for: .seconds(1))
                link.isEnabled = false
                let n1 = n
                try await Task.sleep(for: .milliseconds(300))
                let mono = zip(times, times.dropFirst()).allSatisfy { $0 < $1 }
                try expect(n1 >= 20 && n == n1 && mono, "update link: \(n1) updates in 1 s, after disable \(n), monotonic \(mono)")
                // printing: the simulator has no printers but the print system answers
                let avail = UIPrintInteractionController.isPrintingAvailable
                let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("p6-print.pdf")
                try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).writePDF(to: pdfURL) { $0.beginPage() }
                let can = UIPrintInteractionController.canPrint(pdfURL)
                let info = UIPrintInfo.printInfo(); info.outputType = .grayscale; info.jobName = "sdkcov"
                let pc = UIPrintInteractionController.shared; pc.printInfo = info; pc.printingItem = pdfURL
                try expect(pc.printInfo?.jobName == "sdkcov" && can, "print info / canPrint \(can)")
                return "\(n1) update-link callbacks in 1 s; printing available \(avail), canPrint pdf \(can)"
            }
        })
        #endif
        return c
    }
}
