// sdkcov P4: SharedWithYou (highlight center, attribution view, collaboration lookups),
// GroupActivities without a FaceTime call (no session, activation disabled) and its UIKit / SwiftUI overlays.
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SharedWithYou) && !os(watchOS)
import SharedWithYou
#endif
#if canImport(SharedWithYouCore)
import SharedWithYouCore
#endif
#if canImport(GroupActivities) && !os(watchOS)
import GroupActivities
#endif
#if canImport(_GroupActivities_UIKit) && (os(iOS) || os(visionOS))
import _GroupActivities_UIKit
#endif
#if canImport(_GroupActivities_SwiftUI) && os(visionOS)
import _GroupActivities_SwiftUI
#endif

#if canImport(GroupActivities) && !os(watchOS)
struct P4Activity: GroupActivity {
    static let activityIdentifier = "com.x86sim.test.sdkcov.p4"
    var docID: String
    var page: Int
    var metadata: GroupActivityMetadata {
        var m = GroupActivityMetadata(); m.title = "sdkcov p4"; m.subtitle = docID; m.type = .generic
        m.fallbackURL = URL(string: "https://example.com/\(docID)"); m.supportsContinuationOnTV = false
        return m
    }
}
#endif

#if canImport(SharedWithYou) && !os(watchOS)
final class P4HighlightDelegate: NSObject, SWHighlightCenterDelegate { func highlightCenterHighlightsDidChange(_ c: SWHighlightCenter) {} }
#endif

extension Registry {
    static var p4share: [Check] {
        var c: [Check] = []
        #if canImport(SharedWithYou) && !os(watchOS)
        c.append(check("SharedWithYou", "highlight-center-lookups-attribution-view", timeout: 40) {
            let (center, del) = await onMain { (SWHighlightCenter(), P4HighlightDelegate()) }
            await onMain { center.delegate = del }
            try expect(await onMain { center.delegate === del }, "delegate")
            let n = await onMain { center.highlights.count }
            // a URL nobody shared with this device: an error, not a highlight
            let url = URL(string: "https://example.com/sdkcov-p4-\(UUID().uuidString)")!
            let h: String = await withCheckedContinuation { k in center.getHighlightFor(url) { hl, e in k.resume(returning: hl != nil ? "highlight" : "error \((e as NSError?)?.domain ?? "nil") \((e as NSError?)?.code ?? 0)") } }
            try expect(h.hasPrefix("error"), "getHighlight(for: unknown URL): \(h)")
            var collab = "n/a (tvOS)"
            #if !os(tvOS)
            collab = "returned"
            do { _ = try center.collaborationHighlight(forIdentifier: "sdkcov-none") } catch { collab = "\((error as NSError).domain) \((error as NSError).code)" }
            try expect(collab != "returned", "collaborationHighlight(forIdentifier:) found something")
            #endif
            let title = SWHighlightCenter.highlightCollectionTitle
            try expect(!title.isEmpty, "highlightCollectionTitle")
            #if os(iOS) || os(visionOS) || os(tvOS)
            let v: String = try await onMain {
                let av = SWAttributionView(); av.displayContext = .detail; av.horizontalAlignment = .center; av.preferredMaxLayoutWidth = 300
                av.menuTitleForHideAction = "Hide"
                let host = UIViewController(); host.view.addSubview(av); av.frame = CGRect(x: 20, y: 100, width: 300, height: 60)
                let (_, close) = try p4Show(host); defer { close() }
                av.layoutIfNeeded()
                try expect(av.highlight == nil && av.displayContext == .detail && av.menuTitleForHideAction == "Hide", "attribution view properties")
                return "attribution view \(av.intrinsicContentSize)"
            }
            #else
            let v = ""
            #endif
            return "\(n) highlights, '\(title)', unknown URL: \(h), collaboration: \(collab), \(v), system collaboration \(SWHighlightCenter.isSystemCollaborationSupportAvailable)"
        })
        #endif

        #if canImport(GroupActivities) && !os(watchOS)
        c.append(check("GroupActivities", "no-call-activation-coding", timeout: 40) {
            let a = P4Activity(docID: "doc-7", page: 3)
            let md = a.metadata
            try expect(md.title == "sdkcov p4" && md.subtitle == "doc-7" && md.fallbackURL?.lastPathComponent == "doc-7" && md.type == .generic, "metadata")
            // activities are Codable: what goes to the other participants
            let js = try JSONEncoder().encode(a)
            let back = try JSONDecoder().decode(P4Activity.self, from: js)
            try expect(back.docID == "doc-7" && back.page == 3, "Codable round trip")
            // no FaceTime call: not eligible, no session arrives, preparation says activation is disabled
            let obs = await onMain { GroupStateObserver() }
            let elig = await onMain { obs.isEligibleForGroupSession }
            try expect(!elig, "eligible for a group session without a call")
            let got = P4Box<String>()
            let t = Task { for await s in P4Activity.sessions() { got.set("\(s.state)"); break } }
            let s = await got.wait(2); t.cancel()
            try expect(s == nil, "a session arrived: \(s!)")
            let r = await a.prepareForActivation()
            let rs: String
            switch r { case .activationDisabled: rs = "activationDisabled"; case .activationPreferred: rs = "activationPreferred"; case .cancelled: rs = "cancelled"; @unknown default: rs = "unknown" }
            try expect(rs == "activationDisabled", "prepareForActivation \(rs)")
            return "metadata + Codable \(js.count) B, not eligible, no session, \(rs)"
        })
        #endif
        #if canImport(_GroupActivities_UIKit) && (os(iOS) || os(visionOS))
        c.append(check("_GroupActivities_UIKit", "sharing-controller-association", timeout: 30) {
            try await onMain {
                var sc = "made"
                do { let v = try GroupActivitySharingController(P4Activity(docID: "d", page: 1)); v.loadViewIfNeeded(); sc = "made, view \(v.isViewLoaded)" }
                catch { sc = "init error \(error)" }
                let lazy = GroupActivitySharingController(preparationHandler: { P4Activity(docID: "lazy", page: 0) })
                lazy.loadViewIfNeeded()
                var assoc = "n/a (iOS)"
                #if os(visionOS)
                let host = UIViewController()
                let i = GroupActivityAssociationInteraction(associationKind: .primary("sdkcov"))
                host.view.addInteraction(i)
                try expect(host.view.interactions.contains { $0 === i } && i.view === host.view, "association interaction")
                assoc = "attached"
                #endif
                return "sharing controller \(sc); lazy controller view \(lazy.isViewLoaded); association interaction \(assoc)"
            }
        })
        #endif
        #if canImport(_GroupActivities_SwiftUI) && os(visionOS)
        c.append(check("_GroupActivities_SwiftUI", "association-modifier", timeout: 30) {
            try await p4OnScreen(Text("sdkcov").groupActivityAssociation(.primary("sdkcov")), secs: 1)
        })
        #endif
        return c
    }
}
