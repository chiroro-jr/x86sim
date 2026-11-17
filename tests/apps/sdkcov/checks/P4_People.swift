// sdkcov P4: contacts and calendars with access granted (run.sh / ref-mac.sh pre-grant Contacts, Calendars and
// Reminders in the device's TCC.db, as `simctl privacy grant` does): Contacts save / fetch / update / delete, groups,
// change history; EventKit events with recurrence, reminders, the change notification; ContactsUI / EventKitUI view
// controllers on screen; ContactProvider without its extension. watchOS: Contacts and EventKit are read-only there.
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Contacts)
import Contacts
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(ContactsUI) && (os(iOS) || os(visionOS))
import ContactsUI
#endif
#if canImport(EventKitUI) && (os(iOS) || os(visionOS))
import EventKitUI
#endif
#if canImport(ContactProvider) && os(iOS)
import ContactProvider
#endif

#if os(iOS) || os(visionOS) || os(tvOS)
@MainActor func p4Scene() throws -> UIWindowScene {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let ws = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { throw Fail("no window scene") }
    return ws
}
/// show `vc` in a new window above the app's own; the closure takes it down
@MainActor func p4Show(_ vc: UIViewController) throws -> (UIWindow, () -> Void) {
    let ws = try p4Scene()
    let w = UIWindow(windowScene: ws)
    w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
    w.rootViewController = vc; w.makeKeyAndVisible(); w.layoutIfNeeded()
    let prev = ws.windows.first { $0 !== w && $0.isKeyWindow }
    return (w, { w.isHidden = true; w.rootViewController = nil; prev?.makeKey() })
}
@MainActor func p4Views(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap { p4Views($0) } }
#endif

extension Registry {
    static var p4people: [Check] {
        var c: [Check] = []
        #if canImport(Contacts)
        #if !os(watchOS)
        c.append(check("Contacts", "save-fetch-update-delete-groups-history", timeout: 60) {
            let st = CNContactStore.authorizationStatus(for: .contacts)
            try skipIf(st != .authorized, "Contacts access not granted (status \(st.rawValue)): run.sh / ref-mac.sh pre-grant it")
            let store = CNContactStore()
            func run(_ stage: String, _ r: CNSaveRequest) throws { do { try store.execute(r) } catch { throw Fail("\(stage): \(error)") } }
            let tok = "P4\(Int.random(in: 10000...99999))"
            let changed = P4Box<Bool>()
            let ob = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { _ in changed.set(true) }
            defer { NotificationCenter.default.removeObserver(ob) }
            let token0 = store.currentHistoryToken
            // add
            let m = CNMutableContact(); m.givenName = tok; m.familyName = "Sdkcov"; m.organizationName = "x86Sim"
            m.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "\(tok.lowercased())@example.com" as NSString)]
            m.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 555 010 \(tok.suffix(4))"))]
            m.birthday = DateComponents(year: 1990, month: 12, day: 10)
            let add = CNSaveRequest(); add.add(m, toContainerWithIdentifier: nil)
            try run("add", add)
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey,
                                           CNContactPhoneNumbersKey, CNContactBirthdayKey, CNContactIdentifierKey].map { $0 as CNKeyDescriptor }
            let byName = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: tok), keysToFetch: keys)
            try expect(byName.count == 1 && byName[0].birthday?.month == 12, "by name: \(byName.count)")
            let id = byName[0].identifier
            let byMail = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: "\(tok.lowercased())@example.com"), keysToFetch: keys)
            try expect(byMail.map(\.identifier) == [id], "by email: \(byMail.count)")
            let byPhone = try store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: "+1555010\(tok.suffix(4))")), keysToFetch: keys)
            try expect(byPhone.map(\.identifier).contains(id), "by phone: \(byPhone.count)")
            // update
            let mu = byName[0].mutableCopy() as! CNMutableContact; mu.organizationName = "x86Sim P4"
            let up = CNSaveRequest(); up.update(mu); try run("update", up)
            let again = try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
            try expect(again.organizationName == "x86Sim P4", "update: \(again.organizationName)")
            // a group with the contact as member
            let g = CNMutableGroup(); g.name = "\(tok) group"
            let gr = CNSaveRequest(); gr.add(g, toContainerWithIdentifier: nil); try run("add group", gr)
            let groups = try store.groups(matching: nil).filter { $0.name == "\(tok) group" }
            try expect(groups.count == 1, "group: \(groups.count)")
            // membership in a second request (in the add request itself the group does not exist yet: CNErrorDomain 200)
            let mr = CNSaveRequest(); mr.addMember(again, to: groups[0]); try run("add member", mr)
            let members = try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: groups[0].identifier), keysToFetch: keys)
            try expect(members.map(\.identifier) == [id], "group members \(members.count)")
            // enumeration (CNContactFetchRequest) sees it once
            let fr = CNContactFetchRequest(keysToFetch: keys); fr.predicate = CNContact.predicateForContacts(matchingName: tok); fr.sortOrder = .familyName
            var seen = 0; try store.enumerateContacts(with: fr) { _, _ in seen += 1 }
            try expect(seen == 1, "enumerated \(seen)")
            // change history since the first token (Objective-C only: NS_SWIFT_UNAVAILABLE)
            var hist = "no token"
            if let token0 {
                let hr = CNChangeHistoryFetchRequest(); hr.startingToken = token0; hr.shouldUnifyResults = true
                let sel = NSSelectorFromString("enumeratorForChangeHistoryFetchRequest:error:")
                let res = (store as AnyObject).perform(sel, with: hr, with: nil)?.takeUnretainedValue() as? NSObject
                let en = res?.value(forKey: "value") as? NSEnumerator
                var adds = 0, total = 0
                while let ev = en?.nextObject() { total += 1; if ev is CNChangeHistoryAddContactEvent { adds += 1 } }
                try expect(adds >= 1, "history since the first token: \(total) events, \(adds) contact adds")
                hist = "history \(total) events (\(adds) adds)"
            }
            // delete group + contact
            let del = CNSaveRequest(); del.delete(again.mutableCopy() as! CNMutableContact); try run("delete contact", del)
            let delg = CNSaveRequest(); delg.delete(groups[0].mutableCopy() as! CNMutableGroup); try run("delete group", delg)
            try expect(try store.groups(matching: nil).filter { $0.name == "\(tok) group" }.isEmpty, "group left after delete")
            let gone = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: tok), keysToFetch: keys)
            try expect(gone.isEmpty, "\(gone.count) left after delete")
            let note = await changed.wait(5) != nil
            try expect(note, "no CNContactStoreDidChange")
            return "add/fetch by name, email, phone/update/group/enumerate/delete; \(hist); default container \(store.defaultContainerIdentifier().isEmpty ? "none" : "set")"
        })
        #else
        c.append(check("Contacts", "watch-read-access", timeout: 40) {
            // watchOS: no CNSaveRequest (read-only store); with access granted the store answers fetches
            let st = CNContactStore.authorizationStatus(for: .contacts)
            try skipIf(st != .authorized, "Contacts access not granted (status \(st.rawValue)): run.sh / ref-mac.sh pre-grant it")
            let store = CNContactStore()
            let cont = try store.containers(matching: nil)
            var n = 0
            try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor])) { _, _ in n += 1 }
            let none = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: "zzz-sdkcov-none"), keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor])
            try expect(none.isEmpty, "unexpected match")
            // the default container answers, and fetching by container / identifiers agrees with the enumeration
            let def = store.defaultContainerIdentifier()
            try expect(!cont.isEmpty && cont.contains { $0.identifier == def }, "containers \(cont.map(\.identifier)), default \(def)")
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactIdentifierKey as CNKeyDescriptor]
            let inDef = try store.unifiedContacts(matching: CNContact.predicateForContactsInContainer(withIdentifier: def), keysToFetch: keys)
            var byId = 0
            if let first = inDef.first {
                byId = try store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: [first.identifier]), keysToFetch: keys).count
                try expect(byId == 1, "by identifier: \(byId)")
                let named = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: first.familyName.isEmpty ? first.givenName : first.familyName), keysToFetch: keys)
                try expect(named.contains { $0.identifier == first.identifier }, "by name: \(named.count)")
            }
            try expect(inDef.count == n, "default container \(inDef.count) contacts, enumeration \(n)")
            return "\(cont.count) containers, \(n) contacts (fetch by container / identifier / name agree)"
        })
        #endif
        #endif

        #if canImport(EventKit)
        #if !os(watchOS)
        c.append(check("EventKit", "events-recurrence-reminders-change-note", timeout: 60) {
            let se = EKEventStore.authorizationStatus(for: .event), sr = EKEventStore.authorizationStatus(for: .reminder)
            try skipIf(se != .fullAccess, "Calendar full access not granted (status \(se.rawValue)): run.sh / ref-mac.sh pre-grant it")
            let store = EKEventStore()
            guard let cal = store.defaultCalendarForNewEvents else { throw Fail("no default calendar (\(store.calendars(for: .event).count) calendars, \(store.sources.count) sources)") }
            let changed = P4Box<Bool>()
            let ob = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { _ in changed.set(true) }
            defer { NotificationCenter.default.removeObserver(ob) }
            let tok = "sdkcov-p4-\(Int.random(in: 10000...99999))"
            let start = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!.addingTimeInterval(10 * 3600)
            let e = EKEvent(eventStore: store); e.calendar = cal; e.title = tok; e.location = "Loop"; e.notes = "x86Sim"
            e.startDate = start; e.endDate = start.addingTimeInterval(3600)
            e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 4)))
            e.addAlarm(EKAlarm(relativeOffset: -600))
            try store.save(e, span: .futureEvents, commit: true)
            let id = e.eventIdentifier
            try expect(id != nil, "no event identifier")
            let pred = store.predicateForEvents(withStart: start.addingTimeInterval(-3600), end: start.addingTimeInterval(36 * 86400), calendars: [cal])
            let occ = store.events(matching: pred).filter { $0.title == tok }
            try expect(occ.count == 4, "\(occ.count) occurrences of the weekly x4 event")
            let fetched = store.event(withIdentifier: id!)
            try expect(fetched?.location == "Loop" && fetched?.alarms?.count == 1 && fetched?.hasRecurrenceRules == true, "fetched \(String(describing: fetched))")
            // change one occurrence only
            let third = occ.sorted { $0.startDate < $1.startDate }[2]; third.title = tok + " moved"
            try store.save(third, span: .thisEvent, commit: true)
            let occ2 = store.events(matching: pred).filter { $0.title.hasPrefix(tok) }
            try expect(occ2.filter { $0.title == tok + " moved" }.count == 1 && occ2.count == 4, "detached occurrence: \(occ2.map(\.title))")
            try store.remove(fetched!, span: .futureEvents, commit: true)
            let left = store.events(matching: pred).filter { $0.title.hasPrefix(tok) }
            try expect(left.isEmpty, "\(left.count) left after remove")
            var rem = "reminders: no access (\(sr.rawValue))"
            if sr == .fullAccess, let rcal = store.defaultCalendarForNewReminders() {
                let r = EKReminder(eventStore: store); r.calendar = rcal; r.title = tok; r.priority = 1
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: start)
                try store.save(r, commit: true)
                let found: [EKReminder] = await withCheckedContinuation { k in
                    store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [rcal])) { k.resume(returning: ($0 ?? []).filter { $0.title == tok }) }
                }
                try expect(found.count == 1 && found[0].priority == 1, "incomplete reminders \(found.count)")
                found[0].isCompleted = true; try store.save(found[0], commit: true)
                let done: [EKReminder] = await withCheckedContinuation { k in
                    store.fetchReminders(matching: store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: [rcal])) { k.resume(returning: ($0 ?? []).filter { $0.title == tok }) }
                }
                try expect(done.count == 1 && done[0].completionDate != nil, "completed reminders \(done.count)")
                try store.remove(done[0], commit: true)
                rem = "reminder saved / completed / removed"
            }
            let note = await changed.wait(5) != nil
            try expect(note, "no EKEventStoreChanged")
            return "weekly x4 in \(cal.title), detached 1 occurrence, removed; \(rem)"
        })
        #else
        c.append(check("EventKit", "watch-read-access", timeout: 40) {
            // watchOS: EventKit reads only (saveEvent is prohibited); with access the store lists calendars and answers predicates
            let se = EKEventStore.authorizationStatus(for: .event)
            try skipIf(se != .fullAccess, "Calendar full access not granted (status \(se.rawValue)): run.sh / ref-mac.sh pre-grant it")
            let store = EKEventStore()
            let cals = store.calendars(for: .event)
            let pred = store.predicateForEvents(withStart: .now.addingTimeInterval(-86400 * 7), end: .now.addingTimeInterval(86400 * 30), calendars: nil)
            let evs = store.events(matching: pred)
            // every calendar resolves by identifier, has a source and is one of its source's calendars; the predicate's
            // events lie in its range; a calendar subset answers a subset
            try expect(!cals.isEmpty && !store.sources.isEmpty, "\(cals.count) calendars, \(store.sources.count) sources")
            for c in cals {
                try expect(store.calendar(withIdentifier: c.calendarIdentifier)?.title == c.title, "calendar \(c.title) by identifier")
                try expect(c.source?.calendars(for: .event).contains { $0.calendarIdentifier == c.calendarIdentifier } == true, "calendar \(c.title) not in its source")
            }
            let lo = Date.now.addingTimeInterval(-86400 * 7), hi = Date.now.addingTimeInterval(86400 * 30)
            try expect(evs.allSatisfy { $0.endDate >= lo && $0.startDate <= hi }, "events outside the range")
            let sub = store.events(matching: store.predicateForEvents(withStart: lo, end: hi, calendars: [cals[0]]))
            try expect(sub.count <= evs.count && sub.allSatisfy { $0.calendar.calendarIdentifier == cals[0].calendarIdentifier }, "subset \(sub.count) of \(evs.count)")
            if let e = evs.first { try expect(store.event(withIdentifier: e.eventIdentifier)?.title == e.title, "event by identifier") }
            return "\(cals.count) calendars (\(cals.map(\.title).sorted().joined(separator: ", "))), \(store.sources.count) sources, \(evs.count) events in 5 weeks"
        })
        #endif
        #endif

        #if canImport(ContactsUI) && (os(iOS) || os(visionOS))
        c.append(check("ContactsUI", "picker-and-contact-view-on-screen", timeout: 40) {
            let host = await onMain { UIViewController() }
            let close = try await onMain { try p4Show(host).1 }
            defer { Task { @MainActor in close() } }
            // the picker is a remote view controller (ContactsUI's view service): it gets presented and dismissed
            let picker = await onMain { let p = CNContactPickerViewController(); p.displayedPropertyKeys = [CNContactEmailAddressesKey]; return p }
            await withCheckedContinuation { k in Task { @MainActor in host.present(picker, animated: false) { k.resume() } } }
            let shown = await p4Wait(5) { await onMain { host.presentedViewController === picker && picker.view.window != nil } }
            try expect(shown, "picker not presented")
            await withCheckedContinuation { k in Task { @MainActor in picker.dismiss(animated: false) { k.resume() } } }
            // CNContactViewController for a contact, inside a navigation controller
            let r: String = try await onMain {
                let m = CNMutableContact(); m.givenName = "Ada"; m.familyName = "Lovelace"
                m.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 555 0100"))]
                let v = CNContactViewController(forUnknownContact: m); v.allowsEditing = false; v.allowsActions = false
                let nav = UINavigationController(rootViewController: v)
                host.addChild(nav); nav.view.frame = host.view.bounds; host.view.addSubview(nav.view); nav.didMove(toParent: host)
                nav.view.layoutIfNeeded()
                defer { nav.willMove(toParent: nil); nav.view.removeFromSuperview(); nav.removeFromParent() }
                try expect(v.contact.givenName == "Ada" && v.isViewLoaded && v.view.window != nil, "contact view")
                return "\(p4Views(v.view).count) views"
            }
            return "picker presented + dismissed, contact view \(r)"
        })
        #endif

        #if canImport(EventKitUI) && (os(iOS) || os(visionOS))
        c.append(check("EventKitUI", "event-view-calendar-chooser", timeout: 40) {
            let r: String = try await onMain {
                let store = EKEventStore()
                let e = EKEvent(eventStore: store); e.title = "sdkcov"; e.startDate = .now; e.endDate = .now.addingTimeInterval(3600)
                e.calendar = store.defaultCalendarForNewEvents
                let ev = EKEventViewController(); ev.event = e; ev.allowsEditing = false
                let chooser = EKCalendarChooser(selectionStyle: .multiple, displayStyle: .allCalendars, entityType: .event, eventStore: store)
                chooser.showsDoneButton = true; chooser.selectedCalendars = Set(store.calendars(for: .event).prefix(1))
                let tabs = UITabBarController(); tabs.viewControllers = [UINavigationController(rootViewController: ev), UINavigationController(rootViewController: chooser)]
                let (_, close) = try p4Show(tabs); defer { close() }
                tabs.view.layoutIfNeeded()
                try expect(ev.event?.title == "sdkcov" && ev.isViewLoaded, "event view")
                tabs.selectedIndex = 1; tabs.view.layoutIfNeeded()
                try expect(chooser.isViewLoaded && chooser.view.window != nil, "chooser on screen")
                let edit = EKEventEditViewController(); edit.eventStore = store; edit.event = e
                edit.loadViewIfNeeded()
                return "event view \(p4Views(ev.view).count) views, chooser \(chooser.selectedCalendars.count) selected of \(store.calendars(for: .event).count), edit \(type(of: edit.topViewController.map { $0 } as Any))"
            }
            return r
        })
        #endif

        #if canImport(ContactProvider) && os(iOS)
        c.append(check("ContactProvider", "manager-without-extension", timeout: 30) {
            // the app has no contact provider extension: the manager answers with an error, not a crash
            do {
                let m = try ContactProviderManager()
                var err = "none"
                do { try await m.enable() } catch { err = "\(error)" }
                try expect(err != "none" || m.isEnabled, "enable() neither failed nor enabled")
                return "manager made, enabled \(m.isEnabled), enable(): \(err)"
            } catch {
                // Apple's simulator: the app has no contact provider extension, so no domain is registered
                try expect("\(error)" == "domainNotRegistered", "init: \(error) (Apple's simulator: domainNotRegistered)")
                return "init: \(error)"
            }
        })
        #endif
        return c
    }
}
