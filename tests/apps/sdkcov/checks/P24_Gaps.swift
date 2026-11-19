// SDK coverage, round 28: checks for [a] gaps (COVERAGE-GAPS.md), mostly host input on the platforms the earlier input
// checks skipped. Each asserts what Apple's simulator answers (ref-mac.sh INPUT=, inputs.sh on x86Sim).
import Foundation
import Synchronization
import SwiftUI
#if canImport(GameController) && os(iOS)
import GameController
#endif
#if canImport(_RealityKit_ComputeGraph) && !os(watchOS)
import ComputeGraph
import Metal
import RealityKit
import _RealityKit_ComputeGraph
#endif
#if os(watchOS)
import CoreLocation
import CoreLocationUI
import _CoreLocationUI_SwiftUI
#endif

private var p24InputWait: Double { Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0 }

#if os(watchOS)
/// a watch List row with trailing swipe actions filling the screen; the host swipes right to left across it
private struct P24WatchSwipeView: View {
    let log: P6Log
    var body: some View {
        List {
            Text("SDKCovSwipeRow").frame(maxWidth: .infinity, minHeight: 80)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("SDKCovArchive") { log.add("archive") }.tint(.blue)
                    Button("SDKCovDelete", role: .destructive) { log.add("delete") }
                }
        }
    }
}
#endif

extension Registry {
    static var p24: [Check] {
        var c: [Check] = []
        // MARK: GameController: the iPad's pointer-capture mouse (inputs.sh gcmouse: x86sim pointer; ref-mac.sh ipad
        // INPUT='pointer 30 20 5': Indigo relative pointer events): GCMouse connects and its moved handler sees deltas
        #if canImport(GameController) && os(iOS)
        c.append(check("GameController", "input-mouse-move", timeout: 120) {
            let wait = p24InputWait
            guard wait > 0 else { return "\(GCMouse.mice().count) mice (SDKCOV_INPUT_WAIT unset: no pointer awaited)" }
            let ev = Mutex<(n: Int, dx: Float, dy: Float)>((0, 0, 0))
            let hook = { (m: GCMouse) -> Void in
                m.mouseInput?.mouseMovedHandler = { _, dx, dy in ev.withLock { $0.n += 1; $0.dx += dx; $0.dy += dy } }
            }
            let ob = NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { n in
                if let m = n.object as? GCMouse { hook(m) }
            }
            defer { NotificationCenter.default.removeObserver(ob) }
            for m in GCMouse.mice() { hook(m) }
            let got = await p3Wait(wait) { ev.withLock { $0.n > 2 } }
            let e = ev.withLock { $0 }
            let d = "\(GCMouse.mice().count) mice (\(GCMouse.current?.vendorName ?? "none")); \(e.n) moves"
            try expect(got, "no mouse movement in \(Int(wait)) s: \(d)")
            return d
        })
        #endif
        // MARK: CoreLocationUI on watchOS: a LocationButton tapped by the host (inputs.sh locbutton: the middle of the
        // screen) runs its action, as func:CoreLocationUI.input-location-button-tap on iOS
        #if os(watchOS)
        c.append(check("CoreLocationUI", "input-location-button-tap", timeout: 120) {
            let wait = p24InputWait
            let log = P6Log()
            let done = try await onMain {
                try p6HostSwiftUI(GeometryReader { g in
                    LocationButton(.currentLocation) { log.add("action") }
                        .labelStyle(.iconOnly).frame(width: 80, height: 80)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                }.ignoresSafeArea())
            }
            defer { Task { @MainActor in done() } }
            guard wait > 0 else { return "location button on screen (SDKCOV_INPUT_WAIT unset: no tap awaited)" }
            let ok = await p6Wait(wait) { !log.all.isEmpty }
            try expect(ok, "the button's action never ran in \(Int(wait)) s")
            return "tap ran the action, authorization \(CLLocationManager().authorizationStatus.rawValue)"
        })
        // MARK: SwiftUI on watchOS: a right-to-left swipe on a List row reveals its trailing swipe actions as round
        // buttons (a full swipe runs none, both simulators); the host's tap on the outer one runs the first action
        // (inputs.sh swipe), as the full swipe does in func:SwiftUI.input-list-swipe-actions on iOS
        c.append(check("SwiftUI", "input-list-swipe-actions", timeout: 120) {
            let wait = p24InputWait
            let log = P6Log()
            let done = try await onMain { try p6HostSwiftUI(P24WatchSwipeView(log: log)) }
            defer { Task { @MainActor in done() } }
            guard wait > 0 else { return "list with swipe actions on screen (SDKCOV_INPUT_WAIT unset: no swipe awaited)" }
            let ok = await p6Wait(wait) { !log.all.isEmpty }
            try expect(ok, "no swipe action ran in \(Int(wait)) s")
            try expect(log.all.first == "archive", "actions run \(log.all) (the outer button is the first action: archive)")
            return "swipe + tap ran \(log.all.prefix(3))"
        })
        #endif
        // MARK: _RealityKit_ComputeGraph: a ComputeGraphResource made from an assembled graph's pipelines, attached to an
        // entity through ComputeGraphComponent(resource:) and run by RealityRenderer updates (the input + add graph of
        // func:ComputeGraph.pipelines-simulation-advance)
        #if canImport(_RealityKit_ComputeGraph) && !os(watchOS)
        c.append(check("_RealityKit_ComputeGraph", "resource-component-renderer", timeout: 90) {
            var g = ComputeNodeGraph()
            let f = ComputeNodeGraph.DataType(.float)
            let input = ComputeNodeGraph.NodeDefinition(name: "x", outputs: [.init(name: "value", kind: .value, type: .primitive(type: f))], kind: .graphInput)
            let add = ComputeNodeGraph.NodeDefinition(name: "add", inputs: [.init(name: "a", kind: .value, type: .primitive(type: f)), .init(name: "b", kind: .value, type: .primitive(type: f))],
                                                      outputs: [.init(name: "out", kind: .value, type: .primitive(type: f))], kind: .binaryArithmetic(a: f, b: f, operation: .add))
            let n0 = try g.addNode(.init(definition: input, label: "x"))
            var addNode = ComputeNodeGraph.Node(definition: add, label: "add"); addNode.setInput(at: 1, Float(2.5))
            let n1 = try g.addNode(addNode)
            try g.addEdge(.init(source: .init(node: n0, index: 0), target: .init(node: n1, index: 0)))
            let a = try ComputeNodeGraph.Assembly(g)
            let p: ComputeNodeGraph.Pipelines
            do { p = try await ComputeNodeGraph.Pipelines(descriptor: .init(assembly: a)) }
            catch { return "pipelines refused: \(error)" }
            let graph = g
            return try await onMain {
                var out: [String] = []
                let res: ComputeGraphResource
                do { res = try ComputeGraphResource(graph: graph, pipelines: p, dependencies: .init()) }
                catch { return "resource refused: \(error)" }
                var cg = ComputeGraphComponent(resource: res)
                out.append("component resource \(cg.resource != nil), pipelines \(cg.pipelines != nil), state \(cg.state)")
                out.append("uniform x \(cg.uniformHandle(named: "x") != nil), set \(cg.setUniformValue(Float(4), named: "x"))")
                let e = Entity(); e.components.set(cg)
                let r = try RealityRenderer(); r.entities.append(e)
                for _ in 0..<5 { try r.update(1.0 / 60) }
                cg.step(); e.components.set(cg); try r.update(1.0 / 60)
                let got = e.components[ComputeGraphComponent.self]
                out.append("after 6 updates: resource \(got?.resource != nil), pipelines \(got?.pipelines != nil), state \(got.map { "\($0.state)" } ?? "-"), models \(got?.models.count ?? -1), materials \(got?.materials.count ?? -1)")
                let d = out.joined(separator: "; ")
                // Apple's 27.2 simulators (iOS / tvOS / visionOS): the component keeps the resource and its pipelines, the
                // inlined input has no uniform "x", step() leaves the simulation paused
                try expect(d == "component resource true, pipelines true, state playing; uniform x false, set false; after 6 updates: resource true, pipelines true, state paused, models 0, materials 0", d)
                return d
            }
        })
        #endif
        return c
    }
}
