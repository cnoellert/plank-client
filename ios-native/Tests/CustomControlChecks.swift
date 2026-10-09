import Foundation
import CoreGraphics

@main enum CustomControlChecks {
    static func main() throws {
        try modelChecks()
        ownershipChecks()
        failedAdmissionChecks()
        receiverChecks()
        print("PASS custom controls: bounded saved layouts, legacy migration, independent Space size, clamped geometry, finite bindings, overlapping ownership, physical repeat, combo order, atomic rejection, fail-closed input epochs and stale-change protection")
    }
    private static func modelChecks() throws {
        // The accepted mapping table is the authority for the assignable catalog.
        var mapped = Set<UInt16>()
        for usage in 0...255 {
            for mode in [KeyboardFunctionKeyMode.pc,.appleExtended] {
                if let code = plankIPadVirtualKey(for:usage,functionKeyMode:mode) { mapped.insert(code) }
            }
        }
        precondition(mapped == Set(PlankControlKeyCatalog.entries.map(\.code)))
        precondition(!PlankControlBinding(code:0xFFFF).isValid)
        precondition(!PlankControlBinding(code:0x41,modifiers:16).isValid)
        precondition(PlankControlBinding(code:0x5A,modifiers:3).title == "Shift + Ctrl + Z")
        let original = PlankControlLayout.defaults()
        let reordered = PlankControlLayout.defaults(shortcuts:[.space,.command,.shift,.option,.control])
        let before = original.controls.first { $0.binding.code == 0x20 }!
        let after = reordered.controls.first { $0.binding.code == 0x20 }!
        precondition(before.portrait == after.portrait && before.landscape == after.landscape)
        precondition(after.landscape.width == 200 && reordered.controls[0].binding.code == 0x20)
        precondition(original.isValid && reordered.isValid)
        var moved = after
        moved.landscape.x = 0.92; moved.landscape.y = 0.08
        precondition(moved.landscape.width == 200 && moved.landscape.height == 52)
        let bounds = CGRect(x:10,y:20,width:1000,height:800)
        let atEdge = PlankControlPlacement(x:1,y:0,width:200,height:52).frame(in:bounds)
        precondition(atEdge == CGRect(x:810,y:20,width:200,height:52))
        let small = PlankControlPlacement(x:0,y:0,width:200,height:52).frame(in:CGRect(x:0,y:0,width:80,height:30))
        precondition(small.width == 80 && small.height == 44, "Never shrink hit targets below 44 points")
        let placement = PlankControlPlacement(frame:CGRect(x:310,y:220,width:200,height:52),in:bounds)
        let restored = placement.frame(in:bounds)
        precondition(abs(restored.minX - 310) < 0.0001 && abs(restored.minY - 220) < 0.0001
            && restored.width == 200 && restored.height == 52)
        precondition(PlankControlPlacement(x:.nan,y:0,width:44,height:44).frame(in:bounds) == .zero)
        precondition(!PlankControlPlacement(x:2,y:0,width:44,height:44).isValid)
        precondition(!PlankControlPlacement(x:0,y:0,width:43,height:44).isValid)
        let copy = original.copied()
        precondition(copy.id != original.id && Set(copy.controls.map(\.id)).isDisjoint(with:Set(original.controls.map(\.id))))
        precondition(copy.controls.map(\.landscape) == original.controls.map(\.landscape))
        var invalid = original
        invalid.controls.append(invalid.controls[0])
        precondition(!invalid.isValid, "Repeated control IDs must fail validation")
        invalid = original; invalid.controls[0].label = String(repeating:"a",count:41)
        precondition(!invalid.isValid)
        invalid = original; invalid.controls[0].landscape.width = .infinity
        precondition(!invalid.isValid)
        var library = PlankCustomControlLibrary(layouts:[original])
        let secondID = library.duplicate(id:original.id)!
        precondition(library.layouts.count == 2 && library.selectedID == secondID)
        precondition(library.remove(id:secondID) && library.selectedID == original.id)
        precondition(!library.remove(id:original.id), "Keep one available layout")
        precondition(!library.select(id:UUID()) && !library.upsert(layout:invalid))
        for index in 1..<PlankCustomControlLibrary.maximumLayouts {
            precondition(library.upsert(layout:original.copied(name:"Layout \(index)")))
        }
        precondition(!library.upsert(layout:original.copied()))
        let decoded = try JSONDecoder().decode(PlankCustomControlLibrary.self,from:JSONEncoder().encode(library))
        precondition(decoded == library)
        let suite = "plank.custom-control.checks." + UUID().uuidString
        let storage = UserDefaults(suiteName:suite)!
        defer { storage.removePersistentDomain(forName:suite) }
        var legacy = PlankIPadPencilPadSettings()
        legacy.left = 0.2; legacy.glow = 0.35; legacy.shortcutOrder = [0x20,0x11,0x11,0xFFFF,0x5B]
        legacy.save(to:storage)
        let legacyData = storage.data(forKey:PlankIPadPencilPadSettings.storageKey)
        let migrated = PlankCustomControlLibrary.load(from:storage)
        precondition(migrated.selectedLayout.controls.map(\.binding.code) == [0x20,0x11,0x5B,0x10,0x12])
        precondition(migrated.selectedLayout.controls[0].landscape.width == 200)
        precondition(storage.data(forKey:PlankIPadPencilPadSettings.storageKey) == legacyData)
        precondition(PlankCustomControlLibrary.load(from:storage) == migrated, "Stable migrated IDs survive reopening")
        library.save(to:storage)
        precondition(PlankCustomControlLibrary.load(from:storage) == library)
        var bad = library; bad.selectedID = UUID()
        storage.set(try JSONEncoder().encode(bad),forKey:PlankCustomControlLibrary.storageKey)
        precondition(PlankCustomControlLibrary.load(from:storage).isValid)
    }
    private static func ownershipChecks() {
        typealias Event = PlankControlKeyEvent
        var ledger = PlankControlKeyOwnership()
        let first = UUID(), second = UUID()
        let combo = PlankControlBinding(code:0x5A,modifiers:3)
        let down = ledger.previewBegin(owner:.control(first),binding:combo)!
        precondition(ledger.heldCodes.isEmpty, "Preview may not acquire ownership")
        precondition(down.events == [Event(code:0x10,pressed:true,modifiers:1),
            Event(code:0x11,pressed:true,modifiers:3),Event(code:0x5A,pressed:true,modifiers:3)])
        precondition(ledger.apply(down))
        precondition(!ledger.apply(down), "A preview is applied once")
        precondition(ledger.begin(owner:.control(second),binding:combo,admit:{ $0.isEmpty }))
        precondition(ledger.end(owner:.control(first),admit:{ $0.isEmpty }))
        let up = ledger.previewEnd(owner:.control(second))!
        precondition(up.events == [Event(code:0x5A,pressed:false,modifiers:3),
            Event(code:0x11,pressed:false,modifiers:1),Event(code:0x10,pressed:false,modifiers:0)])
        precondition(ledger.apply(up) && ledger.heldCodes.isEmpty)
        precondition(!ledger.begin(owner:.control(first),binding:combo,admit:{ _ in false }))
        precondition(ledger.heldCodes.isEmpty && ledger.controlOwners.isEmpty, "Rejected admission is wholly inert")
        precondition(ledger.begin(owner:.control(first),binding:combo,admit:{ _ in true }))
        let tap = ledger.previewTap(binding:.init(code:0x41,modifiers:2))!
        precondition(tap.events == [Event(code:0x41,pressed:true,modifiers:3),Event(code:0x41,pressed:false,modifiers:3)])
        precondition(ledger.apply(tap) && ledger.heldCodes == [0x10,0x11,0x5A])
        precondition(ledger.tap(binding:combo,admit:{ $0.isEmpty }), "Do not manufacture a key release for a held trigger")
        precondition(ledger.end(owner:.control(first),admit:{ _ in true }))
        let hardware = ledger.previewHardware(code:0x20,pressed:true,modifiers:0)!
        precondition(ledger.apply(hardware))
        precondition(ledger.begin(owner:.control(first),binding:.init(code:0x20),admit:{ $0.isEmpty }))
        let repeatKey = ledger.previewHardware(code:0x20,pressed:true,modifiers:0)!
        precondition(repeatKey.events == [Event(code:0x20,pressed:true)])
        precondition(ledger.apply(repeatKey))
        let hardwareUp = ledger.previewHardware(code:0x20,pressed:false,modifiers:0)!
        precondition(hardwareUp.events.isEmpty && ledger.apply(hardwareUp))
        precondition(ledger.end(owner:.control(first),admit:{ $0 == [Event(code:0x20,pressed:false)] }))
        // Hardware + two fingers share Shift. Lifting either owner is balanced.
        precondition(ledger.apply(ledger.previewHardware(code:0x10,pressed:true,modifiers:1)!))
        precondition(ledger.begin(owner:.control(first),binding:.init(code:0x10),admit:{ $0.isEmpty }))
        precondition(ledger.begin(owner:.control(second),binding:.init(code:0x10),admit:{ $0.isEmpty }))
        precondition(ledger.retireControls(admit:{ $0.isEmpty }))
        precondition(ledger.controlOwners.isEmpty && ledger.heldCodes == [0x10])
        let hardwareShiftUp = ledger.previewHardware(code:0x10,pressed:false,modifiers:1)!
        precondition(hardwareShiftUp.events == [Event(code:0x10,pressed:false)], "Stale original flags cannot retain released Shift")
        precondition(ledger.apply(hardwareShiftUp))
        precondition(ledger.previewHardware(code:0x10,pressed:false,modifiers:0) == nil)
        precondition(ledger.begin(owner:.control(first),binding:.init(code:0x5A,modifiers:8),admit:{ _ in true }))
        let release = ledger.previewRetireAll()!
        precondition(release.events.map(\.code) == [0x5A,0x5B] && release.events.allSatisfy { !$0.pressed })
        precondition(ledger.apply(release) && ledger.heldCodes.isEmpty)
        let stale = ledger.previewBegin(owner:.control(first),binding:.init(code:0x41))!
        precondition(ledger.tap(binding:.init(code:0x42),admit:{ _ in true }))
        precondition(!ledger.apply(stale), "A delayed preview cannot overwrite a newer hold")
        var other = PlankControlKeyOwnership()
        let foreign = PlankControlKeyOwnership().previewBegin(owner:.control(UUID()),binding:.init(code:0x41))!
        precondition(!other.apply(foreign))
        precondition(ledger.previewBegin(owner:.control(UUID()),binding:.init(code:0xFFFF)) == nil)
        for _ in 0..<PlankControlKeyOwnership.maximumOwners {
            precondition(ledger.begin(owner:.control(UUID()),binding:.init(code:0x41),admit:{ _ in true }))
        }
        precondition(!ledger.begin(owner:.control(UUID()),binding:.init(code:0x42),admit:{ _ in true }))
        precondition(ledger.retireAll(admit:{ $0 == [Event(code:0x41,pressed:false)] }))
    }
    private static func receiverChecks() {
        var receiver = PlankPencilKeyOwnership()
        precondition(receiver.update(code:0x41,pressed:true,source:.pad)?.pressed == true)
        precondition(receiver.update(code:0x41,pressed:true,source:.local) == nil)
        precondition(receiver.update(code:0x41,pressed:true,source:.local)?.pressed == true, "Physical repeat remains available")
        precondition(receiver.update(code:0x41,pressed:false,source:.pad) == nil)
        precondition(receiver.update(code:0x41,pressed:false,source:.local)?.pressed == false)
        _ = receiver.update(code:0x11,pressed:true,source:.pad)
        _ = receiver.update(code:0x5A,pressed:true,source:.pad)
        precondition(receiver.retirePad().map(\.code) == [0x5A,0x11])
    }
    private static func failedAdmissionChecks() {
        final class StubClient {
            var accepts = true, closed = false
            var offers = 0, closes = 0
            var cleanup: [PlankControlKeyEvent] = []
            func offer(_ events: [PlankControlKeyEvent]) -> Bool {
                offers += 1
                return accepts && !closed
            }
            func close(_ retirement: [PlankControlKeyEvent]) {
                cleanup = retirement
                closes += 1; closed = true
            }
        }
        let client = StubClient(), owner = UUID()
        var session = PlankControlKeySession()
        let down = session.ownership.previewBegin(owner:.control(owner),binding:.init(code:0x20))!
        precondition(session.admit(down,offer:client.offer,closeOnRejection:client.close))
        client.accepts = false
        let up = session.ownership.previewEnd(owner:.control(owner))!
        precondition(!session.admit(up,offer:client.offer,closeOnRejection:client.close))
        precondition(!session.accepting && session.ownership.heldCodes.isEmpty
            && session.ownership.controlOwners.isEmpty && client.closed && client.closes == 1)
        precondition(client.cleanup == [.init(code:0x20,pressed:false)])
        let offers = client.offers
        precondition(!session.admit(down,offer:client.offer,closeOnRejection:client.close))
        precondition(client.offers == offers && client.closes == 1, "No retry loop or continuing stale epoch")
        client.closed = false; client.accepts = true; session.reopen()
        let fresh = session.ownership.previewBegin(owner:.control(owner),binding:.init(code:0x20))!
        precondition(fresh.events == [.init(code:0x20,pressed:true)], "Fresh connection cannot inherit the refused touch")
        precondition(session.admit(fresh,offer:client.offer,closeOnRejection:client.close))
        let duplicate = session.ownership.previewBegin(owner:.control(UUID()),binding:.init(code:0x20))!
        client.accepts = false
        let duplicateOffers = client.offers
        precondition(session.admit(duplicate,offer:client.offer,closeOnRejection:client.close))
        precondition(client.offers == duplicateOffers && client.closes == 1,
            "Ownership-only changes have no queue capacity requirement")
        let retirement = session.ownership.previewRetireAll()!
        precondition(!session.admit(retirement,offer:client.offer,closeOnRejection:client.close))
        precondition(client.closes == 2 && !session.accepting && session.ownership.heldCodes.isEmpty)
        session.reopen(); client.closed = false; client.accepts = true
        let hardware = session.ownership.previewHardware(code:0x41,pressed:true,modifiers:0)!
        precondition(session.admit(hardware,offer:client.offer,closeOnRejection:client.close))
        client.accepts = false
        let hardwareUp = session.ownership.previewHardware(code:0x41,pressed:false,modifiers:0)!
        precondition(!session.admit(hardwareUp,offer:client.offer,closeOnRejection:client.close))
        precondition(client.closes == 3 && !session.accepting && session.ownership.heldCodes.isEmpty)
    }
}
