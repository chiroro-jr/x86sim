// sdkcov P6: SwiftUI depth on iOS/iPadOS, tvOS, watchOS and visionOS, with the views on screen (a hosting window;
// watchOS: Runner.overlay). Observation's per-property invalidation, lazy stacks / List / grids and scroll position,
// NavigationStack paths, sheet / cover / alert / dialog lifecycles, controls and their UIKit bridges, TextField focus +
// submit, TimelineView cadence, transitions sampled frame by frame, paged TabViews. Verified on Apple's simulator.
import Foundation
import Synchronization
import SwiftUI
// (no .tag(_:): on tvOS / watchOS its opaque return type needs __isPlatformVersionAtLeast, which the Linux link lacks;
// ForEach ids tag Picker and TabView children instead)
#if canImport(UIKit)
import UIKit
#endif

/// per-name counters (view body evaluations, appearances)
final class P6Counts: @unchecked Sendable {
    private let lock = NSLock(); private var d: [String: Int] = [:]
    func bump(_ k: String) { lock.withLock { d[k, default: 0] += 1 } }
    subscript(_ k: String) -> Int { lock.withLock { d[k] ?? 0 } }
    var keys: Set<String> { lock.withLock { Set(d.keys) } }
}

@Observable final class P6Model {
    var a = 0
    var b = 0
    var pos: Int? = nil
    var path: [Int] = []
    var sheet = false
    var cover = false
    var alert = false
    var dialog = false
    var on = true
    var vol = 0.5
    var count = 3
    var seg = 1
    var text = ""
    var submitted = ""
    var wantFocus = false
    var focused = false
    var show = false
    var page = 0
}

private struct P6ObsA: View { let m: P6Model; let c: P6Counts; var body: some View { c.bump("A"); return Text("a \(m.a)") } }
private struct P6ObsB: View { let m: P6Model; let c: P6Counts; var body: some View { c.bump("B"); return Text("b \(m.b)") } }
private struct P6ObsRoot: View {
    let m: P6Model; let c: P6Counts; let log: P6Log
    var body: some View {
        VStack { P6ObsA(m: m, c: c); P6ObsB(m: m, c: c) }
            .onChange(of: m.a) { old, new in log.add("a \(old)->\(new)") }
    }
}

private struct P6LazyRoot: View {
    @Bindable var m: P6Model; let c: P6Counts; let log: P6Log
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<1000, id: \.self) { i in
                    Text("row \(i)").frame(maxWidth: .infinity).frame(height: 40).id(i).onAppear { c.bump("row\(i)"); c.bump("rows") }
                }
            }.scrollTargetLayout()
        }
        .scrollPosition(id: $m.pos, anchor: .top)
    }
}
private struct P6GridRoot: View {
    let log: P6Log
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
            ForEach(0..<9, id: \.self) { i in
                Color.red.frame(height: 30).onGeometryChange(for: CGRect.self) { $0.frame(in: .named("p6grid")) } action: { log.add("\(i) \(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))") }
            }
        }
        .frame(width: 150).coordinateSpace(.named("p6grid")).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
private struct P6ListRoot: View {
    let c: P6Counts
    var body: some View { List(0..<500, id: \.self) { i in Text("item \(i)").onAppear { c.bump("list") } } }
}

private struct P6NavRoot: View {
    @Bindable var m: P6Model; let log: P6Log
    var body: some View {
        NavigationStack(path: $m.path) {
            Text("root").onAppear { log.add("root.appear") }.onDisappear { log.add("root.disappear") }
                .navigationTitle("Root")
                .navigationDestination(for: Int.self) { i in
                    Text("detail \(i)").onAppear { log.add("d\(i).appear") }.onDisappear { log.add("d\(i).disappear") }.navigationTitle("D\(i)")
                }
        }
    }
}

private struct P6PresRoot: View {
    @Bindable var m: P6Model; let log: P6Log
    var body: some View {
        Color.white
            .sheet(isPresented: $m.sheet, onDismiss: { log.add("sheet.onDismiss") }) {
                Text("sheet").onAppear { log.add("sheet.appear") }.onDisappear { log.add("sheet.disappear") }
            }
            #if !os(visionOS)
            .fullScreenCover(isPresented: $m.cover, onDismiss: { log.add("cover.onDismiss") }) {
                Color.green.onAppear { log.add("cover.appear") }.onDisappear { log.add("cover.disappear") }
            }
            #endif
            .alert("SDKCov alert", isPresented: $m.alert) {
                Button("OK") { log.add("alert.ok") }
                Button("Cancel", role: .cancel) {}
            } message: { Text("alert message") }
            .confirmationDialog("SDKCov dialog", isPresented: $m.dialog, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {}
                Button("Keep") {}
            }
    }
}

#if os(iOS) || os(visionOS) || os(tvOS)
private struct P6ControlsRoot: View {
    @Bindable var m: P6Model
    @FocusState var f: Bool
    var body: some View {
        VStack {
            Toggle("Wifi", isOn: $m.on)
            #if !os(tvOS)
            Slider(value: $m.vol, in: 0...1)
            Stepper("Count \(m.count)", value: $m.count, in: 0...10)
            #endif
            Picker("Seg", selection: $m.seg) { ForEach(0..<3, id: \.self) { i in Text(["A", "B", "C"][i]) } }.pickerStyle(.segmented)
            TextField("Name", text: $m.text).focused($f).onSubmit { m.submitted = m.text }
        }
        .padding()
        .onChange(of: m.wantFocus) { _, v in f = v }
        .onChange(of: f) { _, v in m.focused = v }
    }
}
#endif

/// records the values a transition's Animatable modifier is handed
private struct P6TProbe: ViewModifier, Animatable {
    var x: Double; let log: P6Log
    var animatableData: Double { get { x } set { x = newValue; log.add(String(format: "%.3f", newValue)) } }
    func body(content: Content) -> some View { content.opacity(x) }
}
private struct P6TransitionRoot: View {
    @Bindable var m: P6Model; let log: P6Log; let ticks: P6Log
    var body: some View {
        VStack {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let _ = ticks.add(String(ctx.date.timeIntervalSinceReferenceDate))
                Text("tick")
            }
            if m.show {
                Color.red.frame(width: 40, height: 40)
                    .transition(.modifier(active: P6TProbe(x: 0, log: log), identity: P6TProbe(x: 1, log: log)))
            }
        }
    }
}
private struct P6PageRoot: View {
    @Bindable var m: P6Model; let log: P6Log
    var body: some View {
        TabView(selection: $m.page) {
            ForEach(0..<3, id: \.self) { i in Text("page \(i)").onAppear { log.add("p\(i).appear") } }
        }
        #if os(watchOS)
        .tabViewStyle(.verticalPage)
        #else
        .tabViewStyle(.page)
        #endif
    }
}

#if !os(watchOS)
/// the view controllers presented above the window's root, top last
@MainActor func p6Presented(_ w: UIWindow?) -> [UIViewController] {
    var out: [UIViewController] = []; var v = w?.rootViewController?.presentedViewController
    while let p = v { out.append(p); v = p.presentedViewController }
    return out
}
#endif

extension Registry {
    static var p6_swiftui: [Check] {
        var c: [Check] = []
        // MARK: Observation: only the views reading a changed property are re-evaluated
        c.append(check("SwiftUI", "observation-per-property-invalidation", timeout: 30) {
            let m = await onMain { P6Model() }, cnt = P6Counts(), log = P6Log()
            let close = try await onMain { try p6HostSwiftUI(P6ObsRoot(m: m, c: cnt, log: log)) }
            defer { Task { @MainActor in close() } }
            try await expect(p6Wait(5) { cnt["A"] >= 1 && cnt["B"] >= 1 }, "bodies never evaluated: A \(cnt["A"]) B \(cnt["B"])")
            try await Task.sleep(for: .milliseconds(300))
            let a0 = cnt["A"], b0 = cnt["B"]
            await onMain { m.a += 1 }
            try await expect(p6Wait(3) { cnt["A"] > a0 }, "A not re-evaluated after m.a changed")
            try await Task.sleep(for: .milliseconds(300))
            let a1 = cnt["A"], b1 = cnt["B"]
            await onMain { m.b += 5 }
            try await expect(p6Wait(3) { cnt["B"] > b1 }, "B not re-evaluated after m.b changed")
            try await Task.sleep(for: .milliseconds(300))
            let a2 = cnt["A"], b2 = cnt["B"]
            try expect(b1 == b0 && a2 == a1, "unrelated bodies re-evaluated: B \(b0)->\(b1) on a, A \(a1)->\(a2) on b")
            try expect(log.all == ["a 0->1"], "onChange \(log.all)")
            return "A \(a0)->\(a1)->\(a2), B \(b0)->\(b1)->\(b2), onChange \(log.all)"
        })

        // MARK: lazy stacks, scroll position, lazy grid frames, List laziness
        c.append(check("SwiftUI", "lazy-stack-scroll-position-grid-list", timeout: 40) {
            let m = await onMain { P6Model() }, cnt = P6Counts(), log = P6Log()
            var close = try await onMain { try p6HostSwiftUI(P6LazyRoot(m: m, c: cnt, log: log)) }
            try await expect(p6Wait(5) { cnt["rows"] > 0 }, "no row appeared")
            try await Task.sleep(for: .milliseconds(400))
            let first = cnt["rows"]
            await onMain { m.pos = 500 }
            let reached = await p6Wait(5) { cnt["row500"] > 0 }
            try await Task.sleep(for: .milliseconds(300))
            let skipped = cnt["row250"], total = cnt["rows"]
            await onMain { m.pos = 990 }
            let end = await p6Wait(5) { cnt["row990"] > 0 }
            await onMain { close() }
            try expect(first < 60, "lazy stack built \(first) rows up front")
            try expect(reached && skipped == 0 && total < 200 && end, "scrollPosition 500: reached \(reached), row 250 built \(skipped)x, \(total) rows built, end \(end)")
            // grid: three flexible columns of 50 pt in 150 pt
            close = try await onMain { try p6HostSwiftUI(P6GridRoot(log: log)) }
            _ = await p6Wait(5) { log.all.contains { $0.hasPrefix("8 ") } }
            await onMain { close() }
            let g = log.all
            try expect(g.contains("0 0,0,50,30") && g.contains("4 50,30,50,30") && g.contains("8 100,60,50,30"), "grid frames \(g)")
            // List is lazy too
            close = try await onMain { try p6HostSwiftUI(P6ListRoot(c: cnt)) }
            _ = await p6Wait(5) { cnt["list"] > 0 }
            try await Task.sleep(for: .milliseconds(400))
            await onMain { close() }
            let listed = cnt["list"]
            try expect(listed > 0 && listed < 100, "List rows appeared \(listed) of 500")
            return "\(first) rows up front, jump to 500 built \(total) in all, grid frames exact, List \(listed)/500 rows"
        })

        // MARK: NavigationStack driven by its path
        c.append(check("SwiftUI", "navigation-stack-path", timeout: 40) {
            let m = await onMain { P6Model() }, log = P6Log()
            let close = try await onMain { try p6HostSwiftUI(P6NavRoot(m: m, log: log)) }
            defer { Task { @MainActor in close() } }
            try await expect(p6Wait(5) { log.has("root.appear") }, "root \(log.all)")
            await onMain { m.path = [1] }
            try await expect(p6Wait(5) { log.has("d1.appear") }, "push 1: \(log.all)")
            await onMain { m.path.append(2) }
            try await expect(p6Wait(5) { log.has("d2.appear") }, "push 2: \(log.all)")
            await onMain { _ = m.path.removeLast() }
            try await expect(p6Wait(5) { log.has("d2.disappear") }, "pop 2: \(log.all)")
            try await Task.sleep(for: .milliseconds(800))   // let the pop transition finish first
            await onMain { m.path = [] }
            let popped = await p6Wait(8) { log.has("d1.disappear") && log.all.filter { $0 == "root.appear" }.count >= 2 }
            try expect(popped, "pop to root: \(log.all)")
            let p = await onMain { m.path }
            try expect(p.isEmpty && !log.has("d3.appear"), "path \(p)")
            return log.all.joined(separator: ",")
        })

        // MARK: presentations: sheet / full-screen cover / alert / confirmation dialog
        c.append(check("SwiftUI", "presentation-sheet-cover-alert-dialog", timeout: 60) {
            let m = await onMain { P6Model() }, log = P6Log()
            let close = try await onMain { try p6HostSwiftUI(P6PresRoot(m: m, log: log)) }
            defer { Task { @MainActor in close() } }
            try await Task.sleep(for: .milliseconds(500))
            await onMain { m.sheet = true }
            try await expect(p6Wait(5) { log.has("sheet.appear") }, "sheet: \(log.all)")
            try await Task.sleep(for: .milliseconds(500))
            await onMain { m.sheet = false }
            try await expect(p6Wait(5) { log.has("sheet.onDismiss") && log.has("sheet.disappear") }, "sheet dismiss: \(log.all)")
            var out = "sheet ok"
            #if !os(visionOS)
            try await Task.sleep(for: .milliseconds(500))
            await onMain { m.cover = true }
            try await expect(p6Wait(5) { log.has("cover.appear") }, "cover: \(log.all)")
            try await Task.sleep(for: .milliseconds(500))
            await onMain { m.cover = false }
            try await expect(p6Wait(5) { log.has("cover.onDismiss") }, "cover dismiss: \(log.all)")
            out += ", cover ok"
            #endif
            #if !os(watchOS)
            // alert and dialog become UIAlertControllers presented by the hosting window
            try await Task.sleep(for: .milliseconds(500))
            await onMain { m.alert = true }
            let w = await onMain { p6LastWindow }
            _ = await p6Wait(5) { p6Presented(w).contains { $0 is UIAlertController } }
            let alert = await onMain { () -> String in
                guard let a = p6Presented(w).compactMap({ $0 as? UIAlertController }).first else { return "none: \(p6Presented(w).map { "\(type(of: $0))" })" }
                return "\(a.title ?? "nil")|\(a.message ?? "nil")|\(a.actions.map(\.title!))|\(a.preferredStyle.rawValue)"
            }
            await onMain { m.alert = false }
            _ = await p6Wait(5) { !p6Presented(w).contains { $0 is UIAlertController } }
            try await Task.sleep(for: .milliseconds(500))
            await onMain { m.dialog = true }
            _ = await p6Wait(5) { p6Presented(w).contains { $0 is UIAlertController } }
            let dialog = await onMain { () -> String in
                guard let a = p6Presented(w).compactMap({ $0 as? UIAlertController }).first else { return "none: \(p6Presented(w).map { "\(type(of: $0))" })" }
                return "\(a.title ?? "nil")|\(a.actions.map(\.title!))|\(a.preferredStyle.rawValue)"
            }
            await onMain { m.dialog = false }
            _ = await p6Wait(5) { p6Presented(w).isEmpty }
            let wins = await onMain { p6Windows() }
            try expect(alert.hasPrefix("SDKCov alert|alert message|") && alert.contains("OK") && alert.contains("Cancel"), "alert: \(alert); windows \(wins)")
            try expect(dialog.hasPrefix("SDKCov dialog|") && dialog.contains("Delete") && dialog.contains("Keep"), "dialog: \(dialog)")
            out += "; alert \(alert); dialog \(dialog)"
            #else
            await onMain { m.alert = true }
            try await Task.sleep(for: .milliseconds(800))
            await onMain { m.alert = false }
            #endif
            return out + "; \(log.all.joined(separator: ","))"
        })

        #if os(iOS) || os(visionOS) || os(tvOS)
        // MARK: controls bound to a model, through their UIKit counterparts; TextField focus + submit
        c.append(check("SwiftUI", "controls-bindings-textfield-focus-submit", timeout: 40) {
            let m = await onMain { P6Model() }
            let close = try await onMain { try p6HostSwiftUI(P6ControlsRoot(m: m)) }
            defer { Task { @MainActor in close() } }
            try await Task.sleep(for: .milliseconds(600))
            let w = await onMain { p6LastWindow }
            guard let w else { throw Fail("no window") }
            var found: [String] = []
            // segmented picker: a UISegmentedControl, both directions
            let seg = await onMain { p6Find(w, UISegmentedControl.self).first }
            if let seg {
                let s0 = await onMain { seg.selectedSegmentIndex }
                await onMain { seg.selectedSegmentIndex = 2; seg.sendActions(for: .valueChanged) }
                let ok = await p6Wait(2) { m.seg == 2 }
                await onMain { m.seg = 0 }
                let back = await p6Wait(2) { seg.selectedSegmentIndex == 0 }
                try expect(s0 == 1 && ok && back, "segmented: initial \(s0), UI->model \(ok), model->UI \(back)")
                found.append("segmented")
            }
            #if !os(tvOS)
            if let sw = await onMain({ p6Find(w, UISwitch.self).first }) {
                let on0 = await onMain { sw.isOn }
                await onMain { sw.setOn(false, animated: false); sw.sendActions(for: .valueChanged) }
                let ok = await p6Wait(2) { !m.on }
                try expect(on0 && ok, "switch: initial \(on0), UI->model \(ok)")
                found.append("switch")
            }
            if let sl = await onMain({ p6Find(w, UISlider.self).first }) {
                let v0 = await onMain { sl.value }
                await onMain { m.vol = 0.8 }
                let ok = await p6Wait(2) { abs(sl.value - 0.8) < 0.01 }
                try expect(abs(v0 - 0.5) < 0.01 && ok, "slider: initial \(v0), model->UI \(ok)")
                found.append("slider")
            }
            if let st = await onMain({ p6Find(w, UIStepper.self).first }) {
                await onMain { st.value = 4; st.sendActions(for: .valueChanged) }
                let ok = await p6Wait(2) { m.count == 4 }
                let cnt = await onMain { m.count }
                try expect(ok, "stepper UI->model: count \(cnt)")
                found.append("stepper")
            }
            #endif
            // focus: @FocusState makes the field first responder; typed text reaches the binding; return submits
            await onMain { m.wantFocus = true }
            let focused = await p6Wait(5) { m.focused }
            let tf = await onMain { p6Find(w, UITextField.self).first { $0.isFirstResponder } }
            #if os(tvOS)   // tvOS: focusing the field moves the focus engine; editing happens in the system keyboard UI (no first responder field)
            await onMain { m.wantFocus = false }
            try expect(focused, "focus never reached the field")
            return "UIKit-backed: \(found); TextField @FocusState focus"
            #else
            if tf == nil {
                let diag = await onMain { () -> String in
                    let fields = p6Find(w, UITextField.self)
                    let fr = (w.value(forKey: "firstResponder") as AnyObject?).map { "\(type(of: $0))" } ?? "nil"
                    let key = (try? p6Scene().keyWindow).flatMap { $0 }.map { "\(type(of: $0)) level \($0.windowLevel.rawValue)" } ?? "nil"
                    return "\(fields.count) fields (first responder: \(fields.map(\.isFirstResponder))), window key \(w.isKeyWindow), window first responder \(fr), scene key window \(key); windows \(p6Windows())"
                }
                throw Fail("focus: focused \(focused), no first-responder text field: \(diag)")
            }
            await onMain { tf!.insertText("x86sim") }
            let typed = await p6Wait(3) { m.text == "x86sim" }
            await onMain { tf!.insertText("\n") }
            let submitted = await p6Wait(3) { m.submitted == "x86sim" }
            await onMain { m.wantFocus = false }
            let unfocused = await p6Wait(3) { !m.focused && !tf!.isFirstResponder }
            let (txt, sub) = await onMain { (m.text, m.submitted) }
            try expect(typed && submitted && unfocused, "text \(txt) submitted \(sub) unfocused \(unfocused)")
            #if os(iOS)
            try expect(found.contains("segmented") && found.contains("switch") && found.contains("slider"), "UIKit-backed controls found: \(found)")
            #endif
            return "UIKit-backed: \(found); TextField focus + typing + submit + unfocus"
            #endif
        })
        #endif

        // MARK: TimelineView cadence; a transition's frames sampled through an Animatable modifier
        c.append(check("SwiftUI", "timeline-transition-frame-sampling", timeout: 30) {
            let m = await onMain { P6Model() }, log = P6Log(), ticks = P6Log()
            let close = try await onMain { try p6HostSwiftUI(P6TransitionRoot(m: m, log: log, ticks: ticks)) }
            defer { Task { @MainActor in close() } }
            try await Task.sleep(for: .milliseconds(300))
            let t0 = ticks.all.count
            try await Task.sleep(for: .seconds(1.2))
            let t1 = ticks.all.count
            let dates = Set(ticks.all).compactMap(Double.init).sorted()
            let gaps = zip(dates, dates.dropFirst()).map { $1 - $0 }
            let done = Mutex<Double?>(nil)
            let start = Date()
            await onMain { withAnimation(.linear(duration: 0.5)) { m.show = true } completion: { done.withLock { $0 = Date().timeIntervalSince(start) } } }
            try await expect(p6Wait(5) { done.withLock { $0 } != nil }, "transition completion never ran")
            let el = done.withLock { $0 }!
            let vals = log.all.compactMap(Double.init)
            let mid = vals.filter { $0 > 0.05 && $0 < 0.95 }
            let mono = zip(mid, mid.dropFirst()).allSatisfy { $0 <= $1 + 1e-6 }
            try expect(t1 - t0 >= 6, "TimelineView .periodic(0.1): \(t1 - t0) updates in 1.2 s")
            try expect(gaps.allSatisfy { g in abs(g - (g * 10).rounded() / 10) < 0.02 && g > 0.05 }, "timeline dates not on a 0.1 s grid: \(gaps.prefix(8))")
            try expect(mid.count >= 5 && mono && vals.last.map { abs($0 - 1) < 0.001 } == true, "transition frames \(vals.count): \(mid.count) intermediate, monotonic \(mono), last \(String(describing: vals.last))")
            try expect(el > 0.4 && el < 1.5, "completion after \(el) s")
            return "timeline \(t1 - t0) ticks / 1.2 s; insertion transition \(mid.count) intermediate frames, completion \(String(format: "%.2f", el)) s"
        })

        // MARK: paged TabView driven by its selection (watchOS: vertical pages)
        c.append(check("SwiftUI", "tabview-page-selection", timeout: 30) {
            let m = await onMain { P6Model() }, log = P6Log()
            let close = try await onMain { try p6HostSwiftUI(P6PageRoot(m: m, log: log)) }
            defer { Task { @MainActor in close() } }
            try await expect(p6Wait(5) { log.has("p0.appear") }, "page 0: \(log.all)")
            await onMain { m.page = 2 }
            try await expect(p6Wait(5) { log.has("p2.appear") }, "page 2: \(log.all)")
            await onMain { m.page = 1 }
            try await expect(p6Wait(5) { log.has("p1.appear") }, "page 1: \(log.all)")
            return log.all.joined(separator: ",")
        })
        return c
    }
}
