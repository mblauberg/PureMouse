import Foundation
import Testing
import UserNotifications
@testable import PureMouseMenu
import PureMouseAppSupport

/// A notification centre whose answers a test holds open, to withdraw a warning while the post is
/// waiting for permission or for the centre to add it.
@MainActor
private final class FakeCentre: NotificationCentre {
    var status: UNAuthorizationStatus
    var holdRequest = false
    var holdAdd = false
    private var requestGates: [CheckedContinuation<Void, Never>] = []
    private var addGates: [CheckedContinuation<Void, Never>?] = []
    /// Every add the centre was asked for, even one taken down again.
    private(set) var added: [String] = []
    private(set) var delivered: [String] = []
    private(set) var removals: [[String]] = []
    private(set) var sounds: [Bool] = []
    private(set) var pages: [URL?] = []

    init(status: UNAuthorizationStatus) { self.status = status }

    func authorization() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async -> Bool {
        if holdRequest { await withCheckedContinuation { requestGates.append($0) } }
        status = .authorized
        return true
    }

    func add(id: String, title: String, body: String, opening: URL?, sound: Bool) async {
        if holdAdd { await withCheckedContinuation { addGates.append($0) } }
        added.append(id)
        sounds.append(sound)
        pages.append(opening)
        delivered.append(id)
    }

    func removeDelivered(ids: [String]) {
        removals.append(ids)
        delivered.removeAll { ids.contains($0) }
    }

    /// How many requests are waiting for the user's answer.
    var waitingForPermission: Int { requestGates.count }
    var waitingToAdd: Int { addGates.count }
    func answerRequest() { requestGates.forEach { $0.resume() }; requestGates = [] }
    func finishAdd() { addGates.forEach { $0?.resume() }; addGates = [] }
    /// Completes one held add, in the order the adds began.
    func finishAdd(index: Int) { addGates[index]?.resume(); addGates[index] = nil }
}

@MainActor
private func settle(until condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
}

@MainActor
struct NotificationDeliveryTests {
    @Test func aPostDeliversOnceAllowed() async {
        let centre = FakeCentre(status: .authorized)
        await NotificationDelivery(centre: centre).post(id: "a", title: "t", body: "b").value
        #expect(centre.delivered == ["a"])
    }

    @Test func anUpdateReminderIsSilentAndOpensTheReleasePage() async {
        let centre = FakeCentre(status: .authorized)
        let page = URL(string: "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0")!
        let offer = UpdateOffer(version: UpdateCheck.Version("0.6.0")!, page: page)
        await NotificationDelivery(centre: centre).post(offer).value
        #expect(centre.delivered == [offer.notificationID])
        #expect(centre.sounds == [false])
        #expect(centre.pages == [page])
    }

    @Test func aWarningWithdrawnWhileWaitingForPermissionNeverAppears() async {
        let centre = FakeCentre(status: .notDetermined)
        centre.holdRequest = true
        let delivery = NotificationDelivery(centre: centre)
        let post = delivery.post(id: "a", title: "t", body: "b")
        await settle { centre.waitingForPermission == 1 }
        delivery.removeDelivered(ids: ["a"])          // the mouse charged meanwhile
        centre.answerRequest()
        await post.value
        #expect(centre.added.isEmpty)
    }

    @Test func aWarningWithdrawnWhileBeingAddedIsTakenDown() async {
        let centre = FakeCentre(status: .authorized)
        centre.holdAdd = true
        let delivery = NotificationDelivery(centre: centre)
        let post = delivery.post(id: "a", title: "t", body: "b")
        await settle { centre.waitingToAdd == 1 }
        delivery.removeDelivered(ids: ["a"])
        centre.finishAdd()
        await post.value
        #expect(centre.delivered.isEmpty)
        #expect(centre.removals.last == ["a"])
    }

    @Test func aNewerPostOfAnIdSurvivesAnEarlierWithdrawal() async {
        let centre = FakeCentre(status: .notDetermined)
        centre.holdRequest = true
        let delivery = NotificationDelivery(centre: centre)
        let first = delivery.post(id: "a", title: "t", body: "b")
        await settle { centre.waitingForPermission == 1 }
        delivery.removeDelivered(ids: ["a"])
        let second = delivery.post(id: "a", title: "t", body: "b")   // crossed again
        await settle { centre.waitingForPermission == 2 }
        centre.answerRequest()
        await first.value
        await second.value
        #expect(centre.delivered == ["a"])
    }

    @Test func aWithdrawalOfOneIdLeavesAnotherPostAlone() async {
        let centre = FakeCentre(status: .notDetermined)
        centre.holdRequest = true
        let delivery = NotificationDelivery(centre: centre)
        let low = delivery.post(id: "low", title: "t", body: "b")
        await settle { centre.waitingForPermission == 1 }
        delivery.removeDelivered(ids: ["other"])
        centre.answerRequest()
        await low.value
        #expect(centre.delivered == ["low"])
    }

    /// A's add is held; B is posted (after a withdrawal, or not) and completes; then A completes.
    private func olderAddFinishesLast(withdrawingBetween: Bool) async {
        let centre = FakeCentre(status: .authorized)
        centre.holdAdd = true
        let delivery = NotificationDelivery(centre: centre)
        let older = delivery.post(id: "a", title: "t", body: "b")
        await settle { centre.waitingToAdd == 1 }
        if withdrawingBetween { delivery.removeDelivered(ids: ["a"]) }
        let newer = delivery.post(id: "a", title: "t", body: "b")
        await settle { centre.waitingToAdd == 2 }
        centre.finishAdd(index: 1)
        await newer.value
        centre.finishAdd(index: 0)
        await older.value
        #expect(centre.delivered == ["a", "a"])
        #expect(centre.removals.filter { $0 == ["a"] }.count == (withdrawingBetween ? 1 : 0))  // only the explicit one
    }

    @Test func anOlderAddFinishingAfterANewerPostLeavesTheNewerOne() async {
        await olderAddFinishesLast(withdrawingBetween: false)
    }

    @Test func anOlderAddFinishingAfterAWithdrawalAndANewerPostLeavesTheNewerOne() async {
        await olderAddFinishesLast(withdrawingBetween: true)
    }
}
