import Foundation

/// User-controlled live-zone order. Missing seats retain their positions for the
/// entire boot session; bundle-ID ranks persist across boots. Observation updates
/// may add new seats but never discard a remembered position on a timeout.
/// Messaging/folder/drawer zones keep their own explicit user orders.
@MainActor
final class StripOrderStore: ObservableObject {
    @Published private(set) var liveOrder: [String] = []
    @Published private(set) var stableKeptAppOrder: [String] = []

    private var stableAppOrder: [String] = []
    private let stableAppOrderKey = "stripAppOrderV2"
    private let appKeysKey = "stripLiveAppKeysV2"

    private let orderKey = "stripLiveOrder"
    private let bootKey = "stripLiveOrderBootTime"
    private let stableKeptOrderKey = "stripKeptAppOrderV1"
    /// 本次开机时间（秒）。开机周期内不变，缓存一次即可。
    private let bootTime: Int

    // Absent window seats remain in memory, but reconciled() only renders current IDs.
    // Never reuse their raw IDs across boots; stableAppOrder carries bundle-ID slots instead.

    /// 粘性 id→appKey 记忆。窗口消失后 appKeyOf 映射即丢，占位 app-* 会因找不到同伴跳尾。
    /// 每次 sync 合并，并与同一开机周期的位置记忆一起持久化。
    private var stickyAppKeys: [String: String] = [:]

    /// 抽屉拖回任务条·精确落点的**外部块暂存**。转正那帧窗口卡还没进 live 区（`drawerStore.remove`
    /// 要下一轮才放回），拿不到卡 id；故只记 `bundleID + 目标`，卡 id 在下一次 `sync` 里用 `appKeyOf`
    /// 现解析、`movingBlock` 落子，解析出的 id 回填 `boundIDs` 供撤销精确清除。
    private struct ExternalBlock {
        var bundleID: String
        var target: String?
        var after: Bool
        var boundIDs: [String]
        var originalOrder: [String]
        var originalAppOrder: [String]
    }
    private var externalBlock: ExternalBlock?
    private var currentIDs: Set<String> = []

    private let defaults: UserDefaults
    private let keptIDsProvider: () -> Set<String>
    private let stableKeptOrderProvider: () -> [String]
    private let inventoryLog: WindowInventoryAnomalyLog
    private var lastProjectionSample: InventoryOrderProjectionSample?

    /// 诊断载荷该不该构造。调用方在建 `InventoryOrderProjectionSample` 之前先问一句——
    /// 那份载荷含整份 appKey 字典，日志关着时构造它纯属白干（`AppTracker` 同款写法）。
    var isInventoryLogEnabled: Bool { inventoryLog.isEnabled }

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         keptIDsProvider: @escaping () -> Set<String> = { [] },
         stableKeptOrderProvider: (() -> [String])? = nil,
         bootTimeProvider: () -> Int = StripOrderStore.bootTimeSeconds,
         inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog()) {
        self.defaults = defaults
        self.keptIDsProvider = keptIDsProvider
        self.stableKeptOrderProvider = stableKeptOrderProvider ?? { Array(keptIDsProvider()).sorted() }
        self.inventoryLog = inventoryLog
        bootTime = bootTimeProvider()

        let eligibleOrder = self.stableKeptOrderProvider()
        let eligible = Set(eligibleOrder)
        if defaults.object(forKey: stableKeptOrderKey) != nil {
            let stored = defaults.stringArray(forKey: stableKeptOrderKey) ?? []
            var cleaned = Self.cleanedStableOrder(stored, eligible: eligible)
            let known = Set(cleaned)
            cleaned.append(contentsOf: eligibleOrder.filter { !known.contains($0) })
            stableKeptAppOrder = cleaned
            if cleaned != stored { defaults.set(cleaned, forKey: stableKeptOrderKey) }
        } else {
            let legacyApps = (defaults.stringArray(forKey: orderKey) ?? []).compactMap { id -> String? in
                guard id.hasPrefix("app-") else { return nil }
                return String(id.dropFirst(4))
            }
            stableKeptAppOrder = Self.cleanedStableOrder(legacyApps + eligibleOrder, eligible: eligible)
            defaults.set(stableKeptAppOrder, forKey: stableKeptOrderKey)
        }

        // 仅当存档来自**同一开机周期**才信任精确 chip 序（cgWindowID 跨重启会重排/复用）。
        // 跨开机不接管任何 chip id——由 `stableKeptAppOrder` 的 bundleID 排名在 reconcile 里现排。
        if defaults.object(forKey: bootKey) != nil,
           defaults.integer(forKey: bootKey) == bootTime,
           let saved = defaults.stringArray(forKey: orderKey) {
            liveOrder = saved
            stickyAppKeys = defaults.dictionary(forKey: appKeysKey) as? [String: String] ?? [:]
        }
        stableAppOrder = defaults.stringArray(forKey: stableAppOrderKey)
            ?? (liveOrder.isEmpty ? stableKeptAppOrder : [])
        backfillPlaceholderAppKeys(&stickyAppKeys, ids: liveOrder)
    }

    /// App-level slots survive boots, including ordinary apps without keep enabled.
    /// The legacy kept ranks seed users who have not yet recorded the full app order.
    private var stableKeptRanks: [String: Int] {
        var ranks: [String: Int] = [:]
        for appKey in stableAppOrder + stableKeptAppOrder where ranks[appKey] == nil {
            ranks[appKey] = ranks.count
        }
        return ranks
    }

    /// Pure render projection: retain missing seats as rank anchors, then filter
    /// them out. Snapshot arrival order never overrides an existing seat.
    func reconciled(current: [String], appKeyOf: [String: String] = [:],
                    headPreferred: Set<String> = []) -> [String] {
        var merged = stickyAppKeys
        merged.merge(appKeyOf) { _, new in new }
        let currentSet = Set(current)
        let anchors = absentRankAnchors(current: currentSet)
        let effectiveCurrent = current + anchors
        backfillPlaceholderAppKeys(&merged, ids: effectiveCurrent)
        let ordered = StripOrdering.reconcile(
            remembered: liveOrder,
            current: effectiveCurrent,
            appKeyOf: merged,
            headPreferredKeys: headPreferred,
            stableKeptRanks: stableKeptRanks
        )
        let anchorSet = Set(anchors)
        return ordered.filter { !anchorSet.contains($0) }
    }

    /// Retain missing seats without a five-second expiry. Pure read for both render and sync.
    private func absentRankAnchors(current: Set<String>) -> [String] {
        liveOrder.filter { !current.contains($0) }
    }

    /// `app-*` 占位 id 自带 bundleID；映射缺失时从 id 现补（`app-com.foo` → `com.foo`），保证首帧
    /// 「同 app 同伴」定位不落空——kept 退出（`tabgrp-*` → `app-*`）与重开（`app-*` → `tabgrp-*`）
    /// 首帧都靠占位与真窗口共享同一 app 键。已有映射不覆盖。
    private func backfillPlaceholderAppKeys(_ map: inout [String: String], ids: [String]) {
        for id in ids where id.hasPrefix("app-") && map[id] == nil {
            map[id] = String(id.dropFirst(4))
        }
    }

    /// 把记住的顺序与当前 live 集合收敛（丢掉真关闭的、新窗口插到同 app 同伴旁），保留手动排好的相对序。
    /// **作为快照变化的副作用调用，绝不在 body 求值期间调**。`appKeyOf` 必须与 `reconciled` 同源，
    /// 否则落盘的记忆序与显示序不一致，下一帧新窗口会从同伴旁跳回末尾。
    func sync(
        current: [String],
        appKeyOf: [String: String] = [:],
        headPreferred: Set<String> = [],
        projectionSample: InventoryOrderProjectionSample? = nil
    ) {
        if let projectionSample, projectionSample != lastProjectionSample {
            inventoryLog.record(.orderProjectionChanged(
                projectionSample.payload(previousLiveIDs: lastProjectionSample?.currentLiveIDs ?? [])
            ))
            lastProjectionSample = projectionSample
        }
        syncStableKeptMembership()
        let mappingChanged = appKeyOf.contains { stickyAppKeys[$0.key] != $0.value }
        stickyAppKeys.merge(appKeyOf) { _, new in new }

        let currentSet = Set(current)
        currentIDs = currentSet

        let anchors = absentRankAnchors(current: currentSet)
        let effectiveCurrent = current + anchors
        backfillPlaceholderAppKeys(&stickyAppKeys, ids: effectiveCurrent)
        let reconcileResult = StripOrdering.reconcileWithTrace(
            remembered: liveOrder,
            current: effectiveCurrent,
            appKeyOf: stickyAppKeys,
            headPreferredKeys: headPreferred,
            stableKeptRanks: stableKeptRanks
        )
        var next = reconcileResult.order
        // 消费外部块暂存：当被拖 app 的窗口卡都进了 current（reconcile 已纳入 next），用 appKeyOf 解出这组
        // 卡、整块落到暂存目标，**在一次发布里完成**——无尾部闪入、不被对账规则挪走。排除 app-* 兜底卡。
        // keepPlacement 路径无窗口卡，回退用占位 id "app-\(bundleID)" 做单元素块。
        if var ext = externalBlock {
            var blockIDs = next.filter { currentSet.contains($0) && stickyAppKeys[$0] == ext.bundleID && !$0.hasPrefix("app-") }
            if blockIDs.isEmpty {
                let placeholderID = "app-\(ext.bundleID)"
                if currentSet.contains(placeholderID) { blockIDs = [placeholderID] }
            }
            if !blockIDs.isEmpty {
                let seats = next.filter {
                    blockIDs.contains($0) || (!currentSet.contains($0) && stickyAppKeys[$0] == ext.bundleID)
                }
                next = StripOrdering.movingBlock(next, move: seats, relativeTo: ext.target, after: ext.after)
                ext.boundIDs = blockIDs
                externalBlock = ext
            }
        }
        let currentSetForLog = Set(current)
        let visibleNextForLog = next.filter(currentSetForLog.contains)
        for placement in reconcileResult.placements where currentSetForLog.contains(placement.chipID) {
            inventoryLog.record(.orderChipPlaced(InventoryOrderChipPlacedPayload(
                chipID: placement.chipID,
                appKey: stickyAppKeys[placement.chipID],
                index: visibleNextForLog.firstIndex(of: placement.chipID) ?? placement.index,
                reason: placement.reason.rawValue
            )))
        }
        if next != liveOrder {
            liveOrder = next
            persistLiveOrder()
        } else if mappingChanged {
            persistLiveOrder()
        }
        rememberNewApps(in: liveOrder)
        if let ext = externalBlock, !ext.boundIDs.isEmpty {
            rememberManualAppOrder(from: liveOrder, visible: currentSet)
            updateStableKeptOrder(from: liveOrder.filter(currentSet.contains))
        }
        // Keep app identity for every remembered seat, including absent windows.
        let aliveKeys = currentSet.union(Set(liveOrder))
        stickyAppKeys = stickyAppKeys.filter { aliveKeys.contains($0.key) }
    }

    // MARK: - 外部块落点（抽屉拖回任务条·精确落点）

    /// 转正进任务条：暂存"这个 app 的窗口卡整块落到 `target` 左/右（`target==nil` 末尾）"，下一次 `sync` 消费。
    func stageExternalBlock(bundleID: String, relativeTo target: String?, after: Bool) {
        externalBlock = ExternalBlock(bundleID: bundleID, target: target, after: after,
                                      boundIDs: [], originalOrder: liveOrder, originalAppOrder: stableAppOrder)
    }

    /// 连续重排（窗口卡已实体化、暂存已消费后）：把这组 id 整块移到 `targetID` 处。变化才发布。
    func reorderBlock(ids: [String], relativeTo targetID: String, after: Bool) {
        let apps = Set(ids.compactMap { stickyAppKeys[$0] })
        let seats = liveOrder.filter { ids.contains($0) || (!currentIDs.contains($0) && stickyAppKeys[$0].map(apps.contains) == true) }
        let next = StripOrdering.movingBlock(liveOrder, move: seats, relativeTo: targetID, after: after)
        if next != liveOrder {
            liveOrder = next
            rememberManualAppOrder(from: next, visible: currentIDs.union(ids))
            updateStableKeptOrder(from: next.filter(currentIDs.contains))
            persistLiveOrder()
        }
    }

    /// 落定：仅清暂存追踪，`boundIDs` 留在 `liveOrder`（已是正常成员）。
    func commitExternalBlock() { externalBlock = nil }

    /// 撤销转正：从位置记忆中删掉本次绑定的卡并清暂存。**必须在 `revertDrawerToStrip` 的 `drawerStore.add` 触发 sync 之前调**。
    func cancelExternalBlock() {
        guard let ext = externalBlock else { return }
        let bound = Set(ext.boundIDs)
        let original = Set(ext.originalOrder)
        let next = ext.originalOrder + liveOrder.filter { !original.contains($0) && !bound.contains($0) }
        let knownApps = Set(ext.originalAppOrder)
        stableAppOrder = ext.originalAppOrder + stableAppOrder.filter { !knownApps.contains($0) }
        defaults.set(stableAppOrder, forKey: stableAppOrderKey)
        if next != liveOrder { liveOrder = next; persistLiveOrder() }
        externalBlock = nil
    }

    /// 拖动落位：把 `draggedID` 落到 `targetID` 的左/右边。先 reconcile 定下当前显示序，再插位；
    /// 顺序没变就不发布（拖动中 `dropUpdated` 高频调用，挡掉无谓 churn）。
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool, current: [String]) {
        let base = StripOrdering.reconcile(remembered: liveOrder, current: current + absentRankAnchors(current: Set(current)), appKeyOf: stickyAppKeys)
        // Move absent seats of this app with the dragged icon. Otherwise reopening
        // after a manual drag could inherit an obsolete position from a hidden seat.
        let active = Set(current)
        let app = stickyAppKeys[draggedID]
        let block = base.filter {
            $0 == draggedID || (app != nil && stickyAppKeys[$0] == app && !active.contains($0))
        }
        let next = StripOrdering.movingBlock(base, move: block, relativeTo: targetID, after: after)
        if next != liveOrder { liveOrder = next; rememberManualAppOrder(from: next, visible: Set(current)); updateStableKeptOrder(from: next); persistLiveOrder() }
    }

    /// Persist all seat IDs and their app keys for this boot only.
    private func rememberNewApps(in order: [String]) {
        var known = Set(stableAppOrder)
        for id in order {
            guard let app = stickyAppKeys[id], known.insert(app).inserted else { continue }
            stableAppOrder.append(app)
        }
        if defaults.stringArray(forKey: stableAppOrderKey) != stableAppOrder {
            defaults.set(stableAppOrder, forKey: stableAppOrderKey)
        }
    }

    /// Only explicit drag paths call this. Hidden applications retain their rank slots.
    private func rememberManualAppOrder(from order: [String], visible: Set<String>) {
        rememberNewApps(in: order)
        var seen = Set<String>()
        let apps = order.filter(visible.contains).compactMap { id -> String? in
            guard let app = stickyAppKeys[id], seen.insert(app).inserted else { return nil }
            return app
        }
        let moved = Set(apps)
        let slots = stableAppOrder.indices.filter { moved.contains(stableAppOrder[$0]) }
        for (slot, app) in zip(slots, apps) { stableAppOrder[slot] = app }
        defaults.set(stableAppOrder, forKey: stableAppOrderKey)
    }

    private func persistLiveOrder() {
        defaults.set(liveOrder, forKey: orderKey)
        defaults.set(stickyAppKeys, forKey: appKeysKey)
        defaults.set(bootTime, forKey: bootKey)
    }

    private func syncStableKeptMembership() {
        let eligibleOrder = stableKeptOrderProvider()
        let eligible = Set(eligibleOrder)
        var next = stableKeptAppOrder.filter(eligible.contains)
        let known = Set(next)
        next.append(contentsOf: eligibleOrder.filter { !known.contains($0) })
        guard next != stableKeptAppOrder else { return }
        stableKeptAppOrder = next
        defaults.set(next, forKey: stableKeptOrderKey)
    }

    /// Reorder only the visible members in the full stable list. Hidden drawer members keep
    /// their slots, matching the drawer/messaging order-store contract.
    private func updateStableKeptOrder(from chipOrder: [String]) {
        syncStableKeptMembership()
        let eligible = Set(stableKeptOrderProvider())
        var seen = Set<String>()
        let visible = chipOrder.compactMap { id -> String? in
            guard let appKey = stickyAppKeys[id], eligible.contains(appKey), seen.insert(appKey).inserted else {
                return nil
            }
            return appKey
        }
        guard !visible.isEmpty else { return }
        let visibleSet = Set(visible)
        let slots = stableKeptAppOrder.indices.filter { visibleSet.contains(stableKeptAppOrder[$0]) }
        guard slots.count == visible.count else { return }
        var next = stableKeptAppOrder
        for (slot, appKey) in zip(slots, visible) { next[slot] = appKey }
        guard next != stableKeptAppOrder else { return }
        stableKeptAppOrder = next
        defaults.set(next, forKey: stableKeptOrderKey)
    }

    private static func cleanedStableOrder(_ values: [String], eligible: Set<String>) -> [String] {
        var seen = Set<String>()
        return values.filter { eligible.contains($0) && seen.insert($0).inserted }
    }

    /// `kern.boottime` 的秒数；读不到给 0（=不信任任何存档，安全降级）。
    private nonisolated static func bootTimeSeconds() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        return sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 ? Int(tv.tv_sec) : 0
    }
}
