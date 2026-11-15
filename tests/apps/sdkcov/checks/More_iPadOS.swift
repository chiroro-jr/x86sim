// sdkcov functional checks for iPadOS: what an app sees on an iPad and not on an iPhone (regular/regular size classes,
// more than one window scene, window geometry, split view columns, popovers, pointer, hardware keyboard, Apple Pencil,
// drag and drop). Built into the iOS app (#if os(iOS)); every check SKIPs unless the device's idiom is .pad.
// The ones that need host input (pointer, key commands, drag) wait SDKCOV_INPUT_WAIT seconds for it, like
// checks/Inputs.swift; tests/apps/sdkcov/inputs.sh sends it (`x86sim pointer`, `x86sim raw "key down ..."`, touches).
import Foundation
#if os(iOS)
import UIKit
import SwiftUI
import PencilKit
import GameController
import Synchronization
import UniformTypeIdentifiers

// MARK: helpers

private var padInputWait: Double { Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0 }

@MainActor private func padOnly() throws {
    let i = UIDevice.current.userInterfaceIdiom
    if i != .pad { throw Skip("iPad only (this device's idiom is \(i.rawValue), \(UIDevice.current.model))") }
}

/// poll `cond` on the main actor every 30 ms for up to `secs`
private func padWait(_ secs: Double, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end {
        if await MainActor.run(body: { cond() }) { return true }
        try? await Task.sleep(for: .milliseconds(30))
    }
    return await MainActor.run(body: { cond() })
}

/// the app's first window scene (the one the results view is in): foreground-active first
@MainActor private func padScene() throws -> UIWindowScene {
    let all = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let ws = all.first(where: { $0.activationState == .foregroundActive }) ?? all.first else { throw Fail("no window scene") }
    return ws
}

/// show `vc` full screen in a new key window above the app's own; the closure takes it down and gives the key back
@MainActor private func padShow(_ vc: UIViewController) throws -> (UIWindow, () -> Void) {
    let ws = try padScene()
    let prevKey = ws.windows.first(where: { $0.isKeyWindow })
    let w = UIWindow(windowScene: ws)
    w.frame = ws.effectiveGeometry.coordinateSpace.bounds
    w.windowLevel = .normal + 1
    w.rootViewController = vc
    w.makeKeyAndVisible()
    w.layoutIfNeeded()
    return (w, { w.isHidden = true; w.rootViewController = nil; prevKey?.makeKey() })
}

private func sc(_ s: UIUserInterfaceSizeClass) -> String { s == .regular ? "regular" : s == .compact ? "compact" : "unspecified" }
private func sz(_ s: CGSize) -> String {
    func n(_ v: CGFloat) -> String { v.isFinite && abs(v) < 1e7 ? "\(Int(v))" : "max" }   // sizeRestrictions' maximum is greatestFiniteMagnitude
    return "\(n(s.width))x\(n(s.height))"
}

/// a view controller that counts a ⌘K key command and the raw key presses it gets as first responder
private final class PadKeyVC: UIViewController {
    var commands = 0, presses = 0
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let k = UIKeyCommand(title: "sdkcov ⌘K", action: #selector(cmdK), input: "k", modifierFlags: .command)
        k.wantsPriorityOverSystemBehavior = true
        return [k]
    }
    @objc func cmdK() { commands += 1 }
    override func pressesBegan(_ p: Set<UIPress>, with e: UIPressesEvent?) { presses += p.count; super.pressesBegan(p, with: e) }
}

/// hover recognizer + pointer interaction target: counts what the pointer does over it
private final class PadPointerView: UIView, UIPointerInteractionDelegate {
    var hovers = 0, regions = 0, styles = 0
    var lastHover = CGPoint.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemTeal
        addInteraction(UIPointerInteraction(delegate: self))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func hover(_ g: UIHoverGestureRecognizer) { hovers += 1; lastHover = g.location(in: self) }
    func pointerInteraction(_ i: UIPointerInteraction, regionFor r: UIPointerRegionRequest, defaultRegion d: UIPointerRegion) -> UIPointerRegion? { regions += 1; return d }
    func pointerInteraction(_ i: UIPointerInteraction, styleFor r: UIPointerRegion) -> UIPointerStyle? {
        styles += 1; return UIPointerStyle(effect: .highlight(UITargetedPreview(view: self)))
    }
}

/// drag source / drop target pair, side by side
private final class PadDragVC: UIViewController, UIDragInteractionDelegate, UIDropInteractionDelegate {
    let source = UIView(), target = UIView()
    var began = 0, entered = 0, dropped: [String] = []
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .white
        source.backgroundColor = .systemOrange; target.backgroundColor = .systemIndigo
        view.addSubview(source); view.addSubview(target)
        source.addInteraction(UIDragInteraction(delegate: self))
        target.addInteraction(UIDropInteraction(delegate: self))
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // around (0.25, 0.5) and (0.75, 0.5) of the screen: where inputs.sh's touches go
        let b = view.bounds, s = min(b.width, b.height) * 0.3
        source.frame = CGRect(x: b.width * 0.25 - s / 2, y: b.height * 0.5 - s / 2, width: s, height: s)
        target.frame = CGRect(x: b.width * 0.75 - s / 2, y: b.height * 0.5 - s / 2, width: s, height: s)
    }
    func dragInteraction(_ i: UIDragInteraction, itemsForBeginning s: UIDragSession) -> [UIDragItem] {
        began += 1; return [UIDragItem(itemProvider: NSItemProvider(object: "sdkcov drag" as NSString))]
    }
    func dropInteraction(_ i: UIDropInteraction, canHandle s: UIDropSession) -> Bool { s.canLoadObjects(ofClass: NSString.self) }
    func dropInteraction(_ i: UIDropInteraction, sessionDidEnter s: UIDropSession) { entered += 1 }
    func dropInteraction(_ i: UIDropInteraction, sessionDidUpdate s: UIDropSession) -> UIDropProposal { UIDropProposal(operation: .copy) }
    func dropInteraction(_ i: UIDropInteraction, performDrop s: UIDropSession) {
        _ = s.loadObjects(ofClass: NSString.self) { objs in self.dropped += objs.compactMap { $0 as? String } }
    }
}

private struct PadSplitView: View {
    var body: some View {
        NavigationSplitView {
            List(0..<3, id: \.self) { Text("sidebar \($0)") }
        } content: {
            Text("content")
        } detail: {
            Text("detail")
        }
    }
}

extension Registry {
    static var more_ipados: [Check] {
        var c: [Check] = []
        #if os(iOS)
        // MARK: what makes an iPad an iPad to an app: idiom, system name, size classes, the screen
        c.append(check("UIKit", "ipad-idiom-size-classes") {
            try await onMain {
                try padOnly()
                let ws = try padScene(), t = ws.traitCollection, d = UIDevice.current
                try expect(t.userInterfaceIdiom == .pad, "scene idiom \(t.userInterfaceIdiom.rawValue)")
                try expect(t.horizontalSizeClass == .regular && t.verticalSizeClass == .regular,
                           "size classes \(sc(t.horizontalSizeClass))/\(sc(t.verticalSizeClass))")
                try expect(d.model == "iPad", "model \(d.model)")
                try expect(d.systemName == "iPadOS", "systemName \(d.systemName)")
                let b = ws.screen.bounds
                return "\(d.systemName) \(d.systemVersion) \(d.model), \(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "?"), screen \(sz(b.size)) @\(ws.screen.scale)x native \(sz(ws.screen.nativeBounds.size)), scene \(sz(ws.effectiveGeometry.coordinateSpace.bounds.size)), size classes \(sc(t.horizontalSizeClass))/\(sc(t.verticalSizeClass)), orientation \(ws.effectiveGeometry.interfaceOrientation.rawValue)"
            }
        })

        // MARK: multitasking: the scene's window geometry, size restrictions, full screen or a resizable window
        c.append(check("UIKit", "ipad-window-geometry") {
            try await onMain {
                try padOnly()
                let ws = try padScene()
                guard let r = ws.sizeRestrictions else { throw Fail("no sizeRestrictions (only scenes that can be resized have them)") }
                let (min0, max0) = (r.minimumSize, r.maximumSize)
                r.minimumSize = CGSize(width: 400, height: 400)
                let set = r.minimumSize
                r.minimumSize = min0
                try expect(set == CGSize(width: 400, height: 400), "minimumSize read back \(sz(set))")
                let g = ws.effectiveGeometry
                let req = UIApplication.shared.supportsMultipleScenes
                let orients = UIApplication.shared.supportedInterfaceOrientations(for: ws.windows.first)
                return "fullScreen \(ws.isFullScreen), window \(sz(g.coordinateSpace.bounds.size)), restrictions min \(sz(min0)) max \(sz(max0)), resizing \(g.isInteractivelyResizing), multiple scenes \(req), orientations 0x\(String(orients.rawValue, radix: 16))"
            }
        })

        // MARK: more than one window: a second scene session for the same app, then closed again
        c.append(check("UIKit", "ipad-multiple-scenes", timeout: 150) {
            let (orig, before) = try await onMain { () -> (UIWindowScene, Int) in
                try padOnly()
                try expect(UIApplication.shared.supportsMultipleScenes, "supportsMultipleScenes false (UIApplicationSupportsMultipleScenes)")
                return (try padScene(), UIApplication.shared.connectedScenes.count)
            }
            let err = Mutex<String?>(nil)
            await onMain {
                let a = NSUserActivity(activityType: "com.x86sim.test.sdkcov.activity")
                UIApplication.shared.requestSceneSessionActivation(nil, userActivity: a, options: nil) { e in err.withLock { $0 = "\(e)" } }
            }
            let connected = await padWait(30) { UIApplication.shared.connectedScenes.count > before || err.withLock({ $0 }) != nil }
            if let e = err.withLock({ $0 }) { throw Fail("activation failed: \(e)") }
            guard connected else { throw Fail("no second scene in 30 s (\(before) connected)") }
            let second = await onMain { UIApplication.shared.connectedScenes.first { $0 !== orig } as? UIWindowScene }
            guard let second else { throw Fail("the new scene is not a window scene") }
            func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
            var t = Date()
            let up = await padWait(30) { second.activationState == .foregroundActive && !second.windows.isEmpty }
            let upMs = ms(t)
            let (origState, sessions, wins) = await onMain {
                (orig.activationState.rawValue, UIApplication.shared.openSessions.count, second.windows.count)
            }
            // close it while it is in front (its window's close button; a background scene's destruction does not complete
            // on Apple's simulator: session still open after 20 s). The app then goes to the background, on Apple's too
            // (SpringBoard shows the home screen): a background task keeps it running to bring its first window back
            // (requestSceneSessionActivation of that session, as from the app switcher)
            let bg = await onMain { UIApplication.shared.beginBackgroundTask(withName: "sdkcov scenes") }
            defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }
            t = Date()
            await onMain { UIApplication.shared.requestSceneSessionDestruction(second.session, options: nil) { e in err.withLock { $0 = "destroy: \(e)" } } }
            let session = second.session
            let gone = await padWait(20) { !UIApplication.shared.openSessions.contains(session) || !UIApplication.shared.connectedScenes.contains(second) }
            let goneMs = ms(t)
            t = Date()
            var back = await padWait(3) { orig.activationState == .foregroundActive }
            let by = back ? "by itself" : "after requestSceneSessionActivation"
            if !back {
                await onMain { UIApplication.shared.requestSceneSessionActivation(orig.session, userActivity: nil, options: nil) { e in err.withLock { $0 = "reactivate: \(e)" } } }
                back = await padWait(40) { orig.activationState == .foregroundActive }
            }
            let backMs = ms(t)
            let e = err.withLock { $0 } ?? ""
            try expect(up, "second scene state \(second.activationState.rawValue) after 30 s, \(wins) windows")
            try expect(gone, "the second scene's session still open after 20 s (state \(second.activationState.rawValue)) \(e)")
            try expect(back, "the first scene did not come back to the foreground (state \(orig.activationState.rawValue)) \(e)")
            return "second scene active in \(upMs) ms with \(wins) window(s), \(sessions) open sessions, first scene state meanwhile \(origState); second closed in \(goneMs) ms, first scene active again \(by) in \(backMs) ms"
        })

        // MARK: UISplitViewController columns side by side in regular width
        c.append(check("UIKit", "ipad-split-view-columns", timeout: 40) {
            let (sv, cols, done) = try await onMain { () -> (UISplitViewController, [UIViewController], () -> Void) in
                try padOnly()
                // two columns: a three-column split in an 11-inch iPad's portrait width overlays its first column
                // (Apple's: twoBesideSecondary asked, twoDisplaceSecondary given)
                let sv = UISplitViewController(style: .doubleColumn)
                let cols = [UIColor.systemRed, .systemBlue].map { col -> UIViewController in let v = UIViewController(); v.view.backgroundColor = col; return v }
                sv.setViewController(cols[0], for: .primary); sv.setViewController(cols[1], for: .secondary)
                sv.preferredSplitBehavior = .tile
                sv.preferredDisplayMode = .oneBesideSecondary
                let (_, done) = try padShow(sv)
                return (sv, cols, done)
            }
            defer { Task { @MainActor in done() } }
            _ = await padWait(5) { cols[1].view.window != nil && cols[1].view.bounds.width > 0 }
            try await Task.sleep(for: .seconds(1))
            @MainActor func layout() -> String {
                cols.map { v -> String in
                    guard let w = v.view.window, !v.view.isHidden else { return "-" }
                    let f = v.view.convert(v.view.bounds, to: w); return "\(Int(f.minX))+\(Int(f.width)) inset \(Int(v.view.safeAreaInsets.left))"
                }.joined(separator: " ")
            }
            let (collapsed, mode, l1, xs) = await onMain { () -> (Bool, Int, String, [CGFloat]) in
                // iPadOS 26+: the sidebar floats over the secondary column, which reaches under it and keeps its content
                // beside it through a left safe-area inset; "beside" = where the secondary's content starts
                let xs = cols.map { v in v.view.window.map { v.view.convert(v.view.bounds, to: $0).minX + v.view.safeAreaInsets.left } ?? -1 }
                return (sv.isCollapsed, sv.displayMode.rawValue, layout(), xs)
            }
            try expect(!collapsed, "collapsed in regular width")
            try expect(mode == UISplitViewController.DisplayMode.oneBesideSecondary.rawValue, "display mode \(mode), columns \(l1)")
            let pw = await onMain { cols[0].view.bounds.width }
            try expect(xs[0] >= 0 && xs[1] >= xs[0] + pw - 1, "columns not side by side: \(l1)")
            // hide the primary column: the secondary alone, full width
            await onMain { sv.hide(.primary) }
            _ = await padWait(5) { sv.displayMode == .secondaryOnly }
            try await Task.sleep(for: .milliseconds(600))
            let (mode2, l2, x2) = await onMain { (sv.displayMode.rawValue, layout(), cols[1].view.window.map { cols[1].view.convert(cols[1].view.bounds, to: $0).minX + cols[1].view.safeAreaInsets.left } ?? -1) }
            try expect(mode2 == UISplitViewController.DisplayMode.secondaryOnly.rawValue && x2 == 0, "after hide(.primary): display mode \(mode2), columns \(l2)")
            return "oneBesideSecondary, columns (x+width) \(l1); after hide(.primary): secondaryOnly \(l2)"
        })

        // MARK: SwiftUI NavigationSplitView: three columns, not collapsed into a stack
        c.append(check("SwiftUI", "ipad-navigation-split-view", timeout: 40) {
            let (hc, done) = try await onMain { () -> (UIHostingController<PadSplitView>, () -> Void) in
                try padOnly()
                let hc = UIHostingController(rootView: PadSplitView())
                let (_, done) = try padShow(hc); return (hc, done)
            }
            defer { Task { @MainActor in done() } }
            @MainActor func find() -> UISplitViewController? {
                @MainActor func f(_ v: UIViewController) -> UISplitViewController? { (v as? UISplitViewController) ?? v.children.lazy.compactMap(f).first }
                return f(hc)
            }
            _ = await padWait(10) { find() != nil }
            try await Task.sleep(for: .seconds(1))
            let r = await onMain { () -> String? in
                guard let s = find() else { return nil }
                return "\(s.isCollapsed ? "collapsed" : "not collapsed"), style \(s.style.rawValue), display mode \(s.displayMode.rawValue)"
            }
            guard let r else { throw Fail("no UISplitViewController under the hosting controller") }
            try expect(r.hasPrefix("not collapsed"), r)
            return r
        })

        // MARK: popovers stay popovers in regular width (an iPhone adapts them to sheets)
        c.append(check("UIKit", "ipad-popover", timeout: 40) {
            let (root, done) = try await onMain { () -> (UIViewController, () -> Void) in
                try padOnly()
                let r = UIViewController(); r.view.backgroundColor = .white
                let (_, done) = try padShow(r); return (r, done)
            }
            defer { Task { @MainActor in done() } }
            _ = await padWait(3) { root.view.window != nil }
            func present(_ p: UIViewController) async throws -> (String, CGSize, String) {
                let shown = Mutex(false)
                await onMain {
                    p.popoverPresentationController?.sourceView = root.view
                    p.popoverPresentationController?.sourceRect = CGRect(x: 100, y: 200, width: 20, height: 20)
                    root.present(p, animated: false) { shown.withLock { $0 = true } }
                }
                try expect(await padWait(10) { shown.withLock { $0 } }, "\(type(of: p)) never presented")
                try await Task.sleep(for: .milliseconds(500))
                let r = await onMain { () -> (String, CGSize, String) in
                    // an action sheet's controller is _UIAlertControllerActionSheetRegularPresentationController, a popover subclass
                    let pc = (p.presentationController.map { NSStringFromClass(type(of: $0)) } ?? "nil") + (p.presentationController is UIPopoverPresentationController ? " (popover)" : " (not a popover)")
                    let adapted = p.presentationController?.adaptivePresentationStyle(for: root.traitCollection).rawValue ?? -99
                    return (pc, p.view.frame.size, "adaptive style \(adapted)")
                }
                let gone = Mutex(false)
                await onMain { p.dismiss(animated: false) { gone.withLock { $0 = true } } }
                _ = await padWait(5) { gone.withLock { $0 } }
                return r
            }
            let content = await onMain { () -> UIViewController in
                let v = UIViewController(); v.view.backgroundColor = .systemYellow
                v.preferredContentSize = CGSize(width: 320, height: 200); v.modalPresentationStyle = .popover; return v
            }
            let (pc1, size1, a1) = try await present(content)
            let sheet = await onMain { () -> UIViewController in
                let a = UIAlertController(title: "sdkcov", message: "action sheet", preferredStyle: .actionSheet)
                a.addAction(UIAlertAction(title: "OK", style: .default)); return a
            }
            let (pc2, size2, _) = try await present(sheet)
            let full = await onMain { root.view.bounds.size }
            try expect(pc1.hasSuffix("(popover)") && size1.width <= 330 && size1.height <= 260, "popover: \(pc1) \(sz(size1)) in \(sz(full)), \(a1)")
            try expect(pc2.hasSuffix("(popover)") && size2.width < full.width * 0.6, "action sheet: \(pc2) \(sz(size2)) in \(sz(full))")
            return "popover \(pc1) \(sz(size1)) (\(a1)); action sheet as \(pc2) \(sz(size2)); window \(sz(full))"
        })

        // MARK: pointer: UIPointerInteraction + hover; with SDKCOV_INPUT_WAIT, `x86sim pointer` must reach them
        c.append(check("UIKit", "ipad-pointer-hover", timeout: 120) {
            let wait = padInputWait
            let (v, done) = try await onMain { () -> (PadPointerView, () -> Void) in
                try padOnly()
                let vc = UIViewController(); let v = PadPointerView(frame: .zero); vc.view = v
                let (_, done) = try padShow(vc); return (v, done)
            }
            defer { Task { @MainActor in done() } }
            let mice = await onMain { GCMouse.mice().count }
            let inter = await onMain { v.interactions.contains { $0 is UIPointerInteraction } }
            try expect(inter, "UIPointerInteraction not installed")
            guard wait > 0 else { return "pointer interaction installed, \(mice) GCMouse (SDKCOV_INPUT_WAIT unset: no pointer awaited)" }
            let ok = await padWait(wait) { v.hovers > 1 && v.styles > 0 }
            let (h, r, s, at, m2) = await onMain { (v.hovers, v.regions, v.styles, v.lastHover, GCMouse.mice().count) }
            try expect(ok, "in \(Int(wait)) s: \(h) hover events, \(r) region / \(s) style requests, \(m2) GCMouse")
            return "\(h) hover events (last at \(Int(at.x)),\(Int(at.y))), \(r) pointer regions, \(s) styles, \(m2) GCMouse"
        })

        // MARK: hardware keyboard: a ⌘K UIKeyCommand and raw presses on the first responder
        c.append(check("UIKit", "ipad-key-commands", timeout: 120) {
            let wait = padInputWait
            let (vc, done) = try await onMain { () -> (PadKeyVC, () -> Void) in
                try padOnly()
                let vc = PadKeyVC(); vc.view.backgroundColor = .systemMint
                let (_, done) = try padShow(vc); return (vc, done)
            }
            defer { Task { @MainActor in done() } }
            _ = await padWait(3) { vc.view.window?.isKeyWindow == true }
            let first = await onMain { vc.becomeFirstResponder() }
            try expect(first, "the key view controller did not become first responder")
            let kb = await onMain { GCKeyboard.coalesced != nil }
            guard wait > 0 else { return "first responder with a ⌘K key command, hardware keyboard \(kb) (SDKCOV_INPUT_WAIT unset: no keys awaited)" }
            let ok = await padWait(wait) { vc.commands > 0 }
            let (n, p, kb2) = await onMain { (vc.commands, vc.presses, GCKeyboard.coalesced != nil) }
            try expect(ok, "no ⌘K in \(Int(wait)) s (\(p) presses, hardware keyboard \(kb2))")
            return "⌘K \(n)x, \(p) presses, hardware keyboard \(kb2)"
        })

        // MARK: drag and drop between two views (iPad: drag interactions are on by default)
        c.append(check("UIKit", "ipad-drag-drop", timeout: 120) {
            let wait = padInputWait
            let (vc, done) = try await onMain { () -> (PadDragVC, () -> Void) in
                try padOnly()
                let vc = PadDragVC(); let (_, done) = try padShow(vc); return (vc, done)
            }
            defer { Task { @MainActor in done() } }
            let (byDefault, tfDrag) = await onMain { () -> (Bool, Bool) in
                let tf = UITextView(); return (UIDragInteraction.isEnabledByDefault, tf.textDragInteraction?.isEnabled ?? false)
            }
            try expect(byDefault, "UIDragInteraction.isEnabledByDefault false")
            try expect(tfDrag, "UITextView's text drag interaction is off")
            guard wait > 0 else { return "drag enabled by default, text views draggable (SDKCOV_INPUT_WAIT unset: no drag awaited)" }
            let ok = await padWait(wait) { !vc.dropped.isEmpty }
            let (b, e, d) = await onMain { (vc.began, vc.entered, vc.dropped) }
            try expect(ok, "no drop in \(Int(wait)) s: \(b) drags began, \(e) target entries")
            try expect(d == ["sdkcov drag"], "dropped \(d)")
            return "\(b) drag(s) began, \(e) target entries, dropped \(d)"
        })

        // MARK: Apple Pencil: UIPencilInteraction preferences, a PencilKit canvas on screen with the tool picker
        c.append(check("PencilKit", "ipad-canvas-tool-picker", timeout: 40) {
            let (cv, picker, done) = try await onMain { () -> (PKCanvasView, PKToolPicker, () -> Void) in
                try padOnly()
                let vc = UIViewController(); let cv = PKCanvasView(); vc.view = cv
                cv.backgroundColor = .white; cv.drawingPolicy = .anyInput
                cv.tool = PKInkingTool(.marker, color: .systemBlue, width: 20)
                cv.addInteraction(UIPencilInteraction())
                let pts: [PKStrokePoint] = (0..<30).map { (i: Int) -> PKStrokePoint in let x = CGFloat(100 + i * 10), y = CGFloat(300 + i * 4)
                    return PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
                cv.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: .now))])
                let (_, done) = try padShow(vc)
                let picker = PKToolPicker()
                picker.addObserver(cv); picker.setVisible(true, forFirstResponder: cv)
                _ = cv.becomeFirstResponder()
                return (cv, picker, done)
            }
            defer { Task { @MainActor in picker.setVisible(false, forFirstResponder: cv); cv.resignFirstResponder(); done() } }
            let visible = await padWait(10) { picker.isVisible }
            try await Task.sleep(for: .milliseconds(500))
            let r = await onMain { () -> (String, Double, Bool) in
                let tap = UIPencilInteraction.preferredTapAction.rawValue, only = UIPencilInteraction.prefersPencilOnlyDrawing
                let hover = UIPencilInteraction.prefersHoverToolPreview
                let f = UIGraphicsImageRendererFormat(); f.scale = 1
                let img = UIGraphicsImageRenderer(bounds: cv.bounds, format: f).image { _ in _ = cv.drawHierarchy(in: cv.bounds, afterScreenUpdates: true) }.cgImage
                var ink = 0.0
                if let img {
                    let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                    var n = 0, k = 0
                    for y in stride(from: 280, to: min(img.height, 440), by: 2) { for x in stride(from: 90, to: min(img.width, 400), by: 2) { n += 1; if pixel(ctx, x, y)[0] < 100 { k += 1 } } }
                    ink = n == 0 ? 0 : Double(k) / Double(n)
                }
                return ("tap action \(tap), pencil-only drawing \(only), hover preview \(hover), tool \(type(of: cv.tool))", ink, cv.isFirstResponder)
            }
            try expect(r.1 > 0.02, "the stroke is not on screen (dark pixels \(r.1))")
            try expect(visible, "tool picker not visible (canvas first responder \(r.2))")
            return "\(r.0), stroke on screen (\(String(format: "%.3f", r.1)) dark), tool picker visible"
        })
        #endif
        return c
    }
}
#else
extension Registry { static var more_ipados: [Check] { [] } }
#endif
