import XCTest
@testable import macos_dock_cc_v2

final class AppMembershipProjectionTests: XCTestCase {

    func testRunningAppWithoutInventoryGetsAnEntryWithoutDuplicatingOtherSources() {
        let running: Set<String> = ["missing", "windowed", "kept", "messaging", "drawer", "self", "finder"]
        let result = AppMembershipProjection.missingRunningAppIDs(
            runningIDs: running, representedIDs: ["windowed"], keptIDs: ["kept", "not-running-kept"],
            messagingIDs: ["messaging"], drawerIDs: ["drawer"], excludedIDs: ["self", "finder"])
        XCTAssertEqual(result, ["missing"])
    }

    func testMissingAppLeavesFallbackWhenInventoryRecoversOrProcessQuits() {
        func missing(_ running: Set<String>, represented: Set<String>) -> [String] {
            AppMembershipProjection.missingRunningAppIDs(runningIDs: running, representedIDs: represented,
                keptIDs: [], messagingIDs: [], drawerIDs: [], excludedIDs: [])
        }
        XCTAssertEqual(missing(["app"], represented: []), ["app"])
        XCTAssertEqual(missing(["app"], represented: ["app"]), [])
        XCTAssertEqual(missing(["app"], represented: []), ["app"])
        XCTAssertEqual(missing([], represented: []), [])
    }

    func testDisabledDrawerLetsUnrepresentedRunningAppsReturnToStrip() {
        XCTAssertEqual(AppMembershipProjection.missingRunningAppIDs(
            runningIDs: ["drawer-app"], representedIDs: [], keptIDs: [], messagingIDs: [],
            drawerIDs: ["drawer-app"], excludedIDs: []), [])
        XCTAssertEqual(AppMembershipProjection.missingRunningAppIDs(
            runningIDs: ["drawer-app"], representedIDs: [], keptIDs: [], messagingIDs: [],
            drawerIDs: [], excludedIDs: []), ["drawer-app"])
    }

    func testChromeOffDesktopWindowRemainsRepresentedWithoutDuplicateAppIcon() {
        let chrome = "com.google.Chrome"
        let id = WindowID(rawValue: "chrome-fullscreen-window")
        let record = WindowRecord(id: id, appID: AppID(rawValue: chrome), pid: 711,
            bundleIdentifier: chrome, title: "Chrome", bounds: nil, status: .inactive,
            isOnDesktop: false)
        let items = StripItem.items(from: DockSnapshot(windows: [id: record], orderedWindowIDs: [id]))
        XCTAssertEqual(items.map(\.bundleIdentifier), [chrome])
        XCTAssertFalse(items[0].isOnDesktop)
        XCTAssertEqual(AppMembershipProjection.missingRunningAppIDs(
            runningIDs: [chrome], representedIDs: Set(items.compactMap(\.bundleIdentifier)),
            keptIDs: [], messagingIDs: [], drawerIDs: [], excludedIDs: []), [])
    }

    func testChromeSpaceTransitionAndTerminalHiddenDrawerStillHaveAppEntries() {
        let chrome = "com.google.Chrome"
        let terminal = "com.apple.Terminal"
        let running: Set<String> = [chrome, terminal]
        // Empty window inventory during a transition; the drawer is disabled.
        XCTAssertEqual(Set(AppMembershipProjection.missingRunningAppIDs(
            runningIDs: running, representedIDs: [], keptIDs: [], messagingIDs: [],
            drawerIDs: [], excludedIDs: [])), running)
        // Inventory recovers: only the still-unrepresented Terminal needs a fallback.
        XCTAssertEqual(AppMembershipProjection.missingRunningAppIDs(
            runningIDs: running, representedIDs: [chrome], keptIDs: [], messagingIDs: [],
            drawerIDs: [], excludedIDs: []), [terminal])
    }

    func testDrawerMembersDeduplicates() {
        let result = AppMembershipProjection.drawerMembers(drawerIDs: ["a", "a", "b"])
        XCTAssertEqual(result, ["a", "b"])
    }

    func testDrawerMembersPreservesOrder() {
        let result = AppMembershipProjection.drawerMembers(drawerIDs: ["c", "a", "b"])
        XCTAssertEqual(result, ["c", "a", "b"])
    }

    // MARK: - visibleDrawerIDs = drawer ∩ (running ∪ kept)

    func testVisibleDrawerIDsUsesRunningKeptUnion() {
        let result = AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: ["running", "kept", "messagingOnly", "hidden"],
            keptIDs: ["kept"],
            runningIDs: ["running"]
        )
        // messagingOnly 既不 running 也不 kept → 现在隐藏（messaging 不再独立保活）。
        XCTAssertEqual(result, ["running", "kept"])
    }

    func testVisibleDrawerIDsPreservesInputOrderAndDeduplicates() {
        let result = AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: ["b", "a", "b", "c"],
            keptIDs: ["a", "b", "c"],
            runningIDs: []
        )
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func testDrawerPreviewHonorsLimit() {
        let drawerIDs = (0..<15).map { "app\($0)" }
        let result = AppMembershipProjection.drawerPreview(
            drawerIDs: drawerIDs,
            keptIDs: drawerIDs,
            runningIDs: [],
            limit: 4
        )
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.first, "app0")
    }

    func testDrawerPreviewExcludesInactivePlacements() {
        let result = AppMembershipProjection.drawerPreview(
            drawerIDs: ["a", "b", "c"],
            keptIDs: ["b"],
            runningIDs: ["c"],
            limit: 9
        )
        XCTAssertEqual(result, ["b", "c"])
    }

    // MARK: - visibleMessagingIDs = (messaging − drawer) ∩ (running ∪ kept)

    func testVisibleMessagingIDsExcludesDrawerAndRequiresRunningOrKept() {
        let result = AppMembershipProjection.visibleMessagingIDs(
            messagingIDs: ["running", "kept", "stashed", "gone"],
            drawerIDs: ["stashed"],
            keptIDs: ["kept"],
            runningIDs: ["running"]
        )
        // stashed → 抽屉里隐藏；gone → 既不 running 也不 kept，隐藏。
        XCTAssertEqual(result, ["running", "kept"])
    }

    func testVisibleMessagingIDsPreservesOrderAndDeduplicates() {
        let result = AppMembershipProjection.visibleMessagingIDs(
            messagingIDs: ["c", "a", "c", "b"],
            drawerIDs: [],
            keptIDs: ["a", "b", "c"],
            runningIDs: []
        )
        XCTAssertEqual(result, ["c", "a", "b"])
    }


    // MARK: - badgeEligibleIDs = 身份 ∩ 在跑 − 抽屉（2026-08-23 角标与消息区解绑）

    func testBadgeEligibleIDsUsesIdentityNotZone() {
        let identity: Set<String> = ["com.apple.MobileSMS", "com.tencent.xinWeChat", "com.slack"]
        let result = AppMembershipProjection.badgeEligibleIDs(
            isMessagingApp: { identity.contains($0) },
            drawerIDs: ["com.slack"],                      // 抽屉里的不读
            runningIDs: ["com.apple.MobileSMS", "com.slack", "com.apple.Safari", "com.tencent.xinWeChat"]
        )
        // 信息从没进过消息区，但它是消息应用且在跑 → 有角标资格；Safari 不是消息应用。
        XCTAssertEqual(result, ["com.apple.MobileSMS", "com.tencent.xinWeChat"])
    }

    func testBadgeEligibleIDsIsEmptyWhenNothingRuns() {
        let result = AppMembershipProjection.badgeEligibleIDs(
            isMessagingApp: { _ in true },
            drawerIDs: [],
            runningIDs: []
        )
        XCTAssertTrue(result.isEmpty, "没有消息应用在跑 → 空集 → BadgeStore 停轮询")
    }
}
