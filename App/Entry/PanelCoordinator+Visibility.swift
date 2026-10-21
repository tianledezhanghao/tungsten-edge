import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 显隐：多屏悬停切屏、边缘自动隐藏 / 唤醒、可见性状态机的应用。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
extension PanelCoordinator {
    /// 固定档下把 display UUID 解析成当前的 NSScreen（固定屏缺席回落主屏 / 首屏）；
    /// 跟随鼠标档返回 nil。刻意**无持久运行态**：每次屏幕参数 / 设置变化都重解析一遍，
    /// 固定的屏一接回来自然搬回去，不需要任何「记住上次在哪」的状态机。
    /// ③④ 的 `.fixed` 单元同样走这里：屏刚拔掉、编排层还没来得及拆它的那一瞬回落主屏，不会飞到 nil。
    func resolvedPinnedScreen() -> NSScreen? {
        guard let pinnedUUID = fixedDisplayUUID else { return nil }
        let screens = NSScreen.screens
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: pinnedUUID,
            screenUUIDs: screens.map { DisplayIdentity.uuidString(for: $0) },
            mainIndex: NSScreen.main.flatMap { screens.firstIndex(of: $0) }
        )
        switch outcome {
        case .matched(let index), .fallback(let index):
            return screens[index]
        case nil:
            return nil
        }
    }

    // 鼠标移动监视器（安装 / 节流 / 菜单跟踪期间挂起）整体在编排层 `TaskbarScreenOrchestrator`：
    // 全进程一套，回调转发给每个单元的 `pollMousePosition()`。单元只保留探测与武装逻辑。

    func logScreenMap() {
        let screens = NSScreen.screens
        for (i, screen) in screens.enumerated() {
            let f = screen.frame
            let vf = screen.visibleFrame
            hoverLogger.info("screen-map index=\(i, privacy: .public) name=\(screen.localizedName, privacy: .public) frame=(\(f.minX, privacy: .public),\(f.minY, privacy: .public),\(f.width, privacy: .public),\(f.height, privacy: .public)) visibleFrame=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public)) isMain=\(screen == NSScreen.main, privacy: .public) isScreens0=\(i == 0, privacy: .public)")
        }
    }

    /// 每次（节流后的）鼠标移动都进这里，由编排层转发。别的屏上的移动在 `handleBottomEdgeProbe` 廉价早退。
    func pollMousePosition() {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens

        var curScreenIdx: Int? = nil
        var curScreen: NSScreen? = nil
        for (i, s) in screens.enumerated() {
            if s.frame.contains(mouse) { curScreenIdx = i; curScreen = s; break }
        }

        let dyFromBottom: CGFloat
        let inHotZone: Bool
        if let s = curScreen {
            dyFromBottom = mouse.y - s.frame.minY
            inHotZone = dyFromBottom <= Self.hoverHotZone
        } else {
            dyFromBottom = -1
            inHotZone = false
        }

        handleBottomEdgeProbe(screen: curScreen, inHotZone: inHotZone)
        updateEdgeIdleTimerFromMouse()

        guard curScreenIdx != hoverLastScreenIndex || inHotZone != hoverLastInHotZone else { return }
        hoverLastScreenIndex = curScreenIdx
        hoverLastInHotZone = inHotZone

        if Self.hoverVerboseLogging {
            let panelScreenIdx = dockPanel.map { p -> String in
                let ps = panelCurrentScreen(panel: p)
                return screens.firstIndex(of: ps).map { "\($0)" } ?? "?"
            } ?? "nil"
            if let s = curScreen, let idx = curScreenIdx {
                let f = s.frame
                let vf = s.visibleFrame
                hoverLogger.info("cursor screen=\(idx, privacy: .public) name=\(s.localizedName, privacy: .public) mouse=(\(mouse.x, privacy: .public),\(mouse.y, privacy: .public)) frame=(\(f.minX, privacy: .public),\(f.minY, privacy: .public),\(f.width, privacy: .public),\(f.height, privacy: .public)) visibleFrame=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public)) dyFromBottom=\(dyFromBottom, privacy: .public) inHotZone=\(inHotZone, privacy: .public) panelScreen=\(panelScreenIdx, privacy: .public)")
            } else {
                hoverLogger.info("cursor screen=none mouse=(\(mouse.x, privacy: .public),\(mouse.y, privacy: .public)) dyFromBottom=none inHotZone=false panelScreen=\(panelScreenIdx, privacy: .public)")
            }
        }

    }

    func cancelHoverSwitch() {
        hoverSwitchTimer?.invalidate()
        hoverSwitchTimer = nil
        hoverSwitchTargetScreen = nil
    }

    private func commitHoverSwitch() {
        hoverSwitchTimer = nil
        // 保险：350ms dwell 窗口内设置可能翻到固定档，武装时的判定已过期。
        guard hoverScreenSwitchingEnabled else {
            hoverSwitchTargetScreen = nil
            return
        }
        guard let targetScreen = hoverSwitchTargetScreen, let panel = dockPanel else {
            hoverSwitchTargetScreen = nil
            return
        }
        hoverSwitchTargetScreen = nil
        // Confirm the cursor is still on the target screen (it may have left within the last poll gap).
        guard targetScreen.frame.contains(NSEvent.mouseLocation) else { return }
        let panelScreen = panelCurrentScreen(panel: panel)
        guard targetScreen != panelScreen else { return }   // panel already moved (e.g. screenParametersChanged)
        let screens = NSScreen.screens
        let fromIdx = screens.firstIndex(of: panelScreen).map { "\($0)" } ?? "?"
        let toIdx = screens.firstIndex(of: targetScreen).map { "\($0)" } ?? "?"
        let actualWidth = PanelGeometry.dockTargetFrame(
            contentWidth: lastDesiredWidth,
            on: Self.screenGeometry(targetScreen),
            metrics: layoutMetrics
        ).width - Self.shadowPadding * 2
        closeFolderPopup()   // 切屏后旧锚点在旧屏,弹窗收起
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        layoutPanels(contentWidth: lastDesiredWidth, on: targetScreen, animated: false)
        hoverLogger.info("switch toScreen=\(toIdx, privacy: .public) name=\(targetScreen.localizedName, privacy: .public) actualWidth=\(actualWidth, privacy: .public) fromScreen=\(fromIdx, privacy: .public)")
        armEdgeWakeIfNeeded(on: targetScreen, requiresHotZone: false)
    }

    private func handleBottomEdgeProbe(screen: NSScreen?, inHotZone: Bool) {
        guard let screen, let panel = dockPanel else {
            cancelHoverSwitch()
            cancelEdgeWake()
            return
        }

        let panelScreen = panelCurrentScreen(panel: panel)
        if screen != panelScreen {
            // 固定到某屏：别的屏的底边热区什么都不武装——dwell 计时器根本不该起。
            guard hoverScreenSwitchingEnabled else {
                cancelEdgeWake()
                cancelHoverSwitch()
                return
            }
            cancelEdgeWake()
            if hoverSwitchTargetScreen == screen {
                return
            }
            if inHotZone {
                hoverSwitchTimer?.invalidate()
                hoverSwitchTargetScreen = screen
                let timer = Timer(timeInterval: Self.hoverSwitchDwell, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.commitHoverSwitch() }
                }
                RunLoop.main.add(timer, forMode: .common)
                hoverSwitchTimer = timer
            } else {
                cancelHoverSwitch()
            }
            return
        }

        cancelHoverSwitch()
        if inHotZone {
            armEdgeWakeIfNeeded(on: screen)
        } else if edgeWakeTargetScreen == screen, edgeWakeRequiresHotZone {
            cancelEdgeWake()
        }
    }

    /// 钨极菜单开着时停掉边缘自动隐藏，否则空闲计时照跑、任务条会从菜单底下缩掉。
    func setTaskbarMenuOpen(_ open: Bool) {
        setAutoHideInhibitor(.taskbarMenuOpen, active: open)
        resizeCursorMenuVisibilityChanged(open)
    }

    var isTaskbarMenuOpen: Bool { visibilityState.autoHideInhibitors.contains(.taskbarMenuOpen) }

    func setAutoHideInhibitor(_ inhibitor: EdgeAutoHideInhibitor, active: Bool) {
        let before = visibilityState
        visibilityState.setInhibitor(inhibitor, active: active)
        if visibilityState != before { reconcilePanelVisibility() }
    }

    func reconcilePanelVisibility() {
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil

        let edgeDelay = settingsStore.edgeAutoHideDelay
        let edgeEnabled = edgeDelay != AppSettingsStore.neverHideDelay
        visibilityState.reconcileEdgeAutoHide(isEnabled: edgeEnabled)

        if edgeDelay == AppSettingsStore.neverHideDelay {
            cancelEdgeWake()
        } else if visibilityState.autoHideInhibitors.isEmpty,
                  !visibilityState.hideReasons.contains(.fullscreen),
                  !visibilityState.hideReasons.contains(.fullscreenTransitionPending) {
            if visibilityState.hideReasons.contains(.edgeAutoHide) {
                if EdgeAutoHideRuntimeRules.canArmWake(state: visibilityState, delay: edgeDelay),
                   let screen = screenContainingMouse(),
                   isMouseInBottomHotZone(on: screen) {
                    armEdgeWakeIfNeeded(on: screen)
                }
            } else if EdgeAutoHideRuntimeRules.canArmIdleHide(state: visibilityState, delay: edgeDelay),
                      isMouseOutsideInteractivePanels() {
                armEdgeIdleHideTimer()
            }
        } else {
            cancelEdgeWake()
        }

        applyPanelVisibility()
    }

    func updateEdgeIdleTimerFromMouse() {
        guard EdgeAutoHideRuntimeRules.canArmIdleHide(state: visibilityState, delay: settingsStore.edgeAutoHideDelay) else { return }

        if isMouseOutsideInteractivePanels() {
            if edgeIdleHideTimer == nil {
                armEdgeIdleHideTimer()
            }
        } else {
            edgeIdleHideTimer?.invalidate()
            edgeIdleHideTimer = nil
        }
    }

    private func armEdgeIdleHideTimer() {
        guard let interval = EdgeAutoHideRuntimeRules.idleHideInterval(for: settingsStore.edgeAutoHideDelay) else { return }
        if interval == 0 {
            edgeIdleHideTimer?.invalidate()
            edgeIdleHideTimerFired()
            return
        }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.edgeIdleHideTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeIdleHideTimer = timer
    }

    private func edgeIdleHideTimerFired() {
        edgeIdleHideTimer = nil
        guard EdgeAutoHideRuntimeRules.canArmIdleHide(state: visibilityState, delay: settingsStore.edgeAutoHideDelay),
              isMouseOutsideInteractivePanels() else { return }
        visibilityState.setEdgeAutoHidden(true)
        reconcilePanelVisibility()
    }

    private func armEdgeWakeIfNeeded(on screen: NSScreen, requiresHotZone: Bool = true) {
        // 固定到某屏：唤醒探测只认**面板实际所在的屏**（不是存的固定屏——固定屏被拔、
        // 条落在回退屏时，回退屏照常唤醒）。这里是所有武装路径的单一咽喉，
        // 包括 reconcilePanelVisibility 里按 screenContainingMouse() 的那条。
        if !hoverScreenSwitchingEnabled,
           let panel = dockPanel, panelCurrentScreen(panel: panel) != screen {
            return
        }
        guard EdgeAutoHideRuntimeRules.canArmWake(state: visibilityState, delay: settingsStore.edgeAutoHideDelay) else { return }
        if edgeWakeTargetScreen == screen,
           edgeWakeTimer != nil,
           edgeWakeRequiresHotZone == requiresHotZone { return }
        cancelEdgeWake()
        edgeWakeTargetScreen = screen
        edgeWakeRequiresHotZone = requiresHotZone
        let timer = Timer(timeInterval: settingsStore.edgeAutoHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.edgeWakeTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeWakeTimer = timer
    }

    private func edgeWakeTimerFired() {
        edgeWakeTimer = nil
        guard let screen = edgeWakeTargetScreen,
              edgeWakeShouldStillFire(on: screen),
              EdgeAutoHideRuntimeRules.canArmWake(state: visibilityState, delay: settingsStore.edgeAutoHideDelay) else {
            edgeWakeTargetScreen = nil
            edgeWakeRequiresHotZone = true
            return
        }
        edgeWakeTargetScreen = nil
        edgeWakeRequiresHotZone = true
        // 顺带搬屏只属于跟随鼠标档；固定档下武装已被上面的咽喉拦住，这里再挡一道
        // arm 与 fire 之间屏幕集合变化的漂移。
        if hoverScreenSwitchingEnabled, let panel = dockPanel, panelCurrentScreen(panel: panel) != screen {
            layoutPanels(contentWidth: lastDesiredWidth, on: screen, animated: false)
        }
        visibilityState.setEdgeAutoHidden(false)
        reconcilePanelVisibility()
    }

    func cancelEdgeWake() {
        edgeWakeTimer?.invalidate()
        edgeWakeTimer = nil
        edgeWakeTargetScreen = nil
        edgeWakeRequiresHotZone = true
    }

    private func edgeWakeShouldStillFire(on screen: NSScreen) -> Bool {
        if edgeWakeRequiresHotZone {
            return isMouseInBottomHotZone(on: screen)
        }
        return screen.frame.contains(NSEvent.mouseLocation)
    }

    func applyPanelVisibility() {
        guard !isSuspendedForPermissionLoss else { return }
        let shouldShow = visibilityState.isVisible
        let fullscreenHide = !shouldShow && (
            visibilityState.hideReasons.contains(.fullscreen)
                || visibilityState.hideReasons.contains(.fullscreenTransitionPending))
        if fullscreenHide, dockVisibilityMotion != nil {
            cancelDockVisibilityAnimation()
            orderDockSurfaceOut()
            capsulePanel?.orderOut(nil)
        }
        guard shouldShow != panelsAreVisible else { return }
        panelsAreVisible = shouldShow
        // 角标轮询的零感知门控跟着任务条逻辑显隐走（编排层按「任一单元可见」合并）；恢复时 BadgeStore 会立即读一次。
        onLogicalVisibilityChanged?(shouldShow)
        if Self.edgeHoverTraceEnabled { logEdgeHoverTrace(shouldShow: shouldShow) }
        if shouldShow {
            let fullscreenReturn = lastHideWasForFullscreen
            lastHideWasForFullscreen = false
            if fullscreenReturn {
                cancelDockVisibilityAnimation()
                let panels = [dockGlassBackgroundPanel, dockPanel, capsulePanel].compactMap { $0 }
                let fade = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                for panel in panels { panel.alphaValue = fade ? 0 : 1 }
                dockPanel?.ignoresMouseEvents = false
                capsulePanel?.ignoresMouseEvents = false
                orderDockAndCapsuleFront()
                if fade {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.32
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        for panel in panels { panel.animator().alphaValue = 1 }
                    }
                }
            } else {
                animateDockVisibility(show: true)
            }
            if drawerWantsOpen { drawerPanel?.orderFrontRegardless() }
            pinResidentPanelsIfNeeded()
            // 藏起来的这段时间里可能有全屏空间被销毁，系统会顺手把面板从别的桌面上摘掉
            // （issue #19）。健康时这里只是一次 SkyLight 读，不做任何事。
            repairAllSpacesMembershipIfNeeded()
        } else {
            lastHideWasForFullscreen = visibilityState.hideReasons.contains(.fullscreen)
            if lastHideWasForFullscreen { closeDrawer() }
            closeFolderPopup()
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            if fullscreenHide {
                cancelDockVisibilityAnimation()
                orderDockSurfaceOut()
                capsulePanel?.orderOut(nil)
            } else {
                animateDockVisibility(show: false)
            }
        }
    }

    var dockVisibilitySurfaceFrames: [(NSPanel, NSRect)] {
        var frames: [(NSPanel, NSRect)] = []
        if let background = dockGlassBackgroundPanel {
            frames.append((background, DockLiquidGlassPanelGeometry.backgroundFrame(
                for: lastDockTargetFrame, shadowPadding: Self.shadowPadding)))
        }
        if let dock = dockPanel { frames.append((dock, lastDockTargetFrame)) }
        if settingsStore.showDrawer, let capsule = capsulePanel { frames.append((capsule, lastCapsuleTargetFrame)) }
        return frames
    }

    /// Full frames remain the layout's source of truth. Only this presentation offset moves.
    func renderDockVisibilityOffset() {
        let pairs = dockVisibilitySurfaceFrames
        let travel = layoutMetrics.panelHeight + layoutMetrics.bottomGap + Self.shadowPadding
        let alpha = min(1, max(0, (travel + dockVisibilityOffset) / 12))
        if let group = dockVisibilityWindowGroup {
            group.apply(frames: pairs, offset: dockVisibilityOffset, alpha: alpha)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                for (panel, frame) in pairs {
                    // Replace stale AppKit width/alpha animations even if their estimated
                    // deadline expired during a busy main loop. Direct writes don't cancel them.
                    panel.animator().setFrame(frame.offsetBy(dx: 0, dy: dockVisibilityOffset), display: false)
                    panel.animator().alphaValue = alpha
                }
            }
        }
    }

    func animateDockVisibility(show: Bool) {
        guard let dock = dockPanel else { return }
        dock.ignoresMouseEvents = !show
        capsulePanel?.ignoresMouseEvents = !show
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cancelDockVisibilityAnimation()
            if show {
                orderDockAndCapsuleFront()
            } else {
                orderDockSurfaceOut()
                capsulePanel?.orderOut(nil)
            }
            return
        }
        let now = CACurrentMediaTime()
        let travel = layoutMetrics.panelHeight + layoutMetrics.bottomGap + Self.shadowPadding
        let start: DockVisibilitySpring.Sample
        if let motion = dockVisibilityMotion {
            // Continue from the state actually submitted to the windows, which may
            // already be predicted for the next display time. Sampling wall time here
            // would jump backwards when a flight is interrupted between callbacks.
            start = .init(position: dockVisibilityOffset,
                velocity: motion.sample(at: dockVisibilityTimeline.elapsedAtLastFrame).velocity)
        } else {
            // Retire any width animation before the presentation clock owns these windows.
            settleRunningFrameAnimation()
            start = .init(position: show ? -travel : 0, velocity: 0)
        }
        dockVisibilityMotion = DockVisibilitySpring(start: start, target: show ? 0 : -travel)
        dockVisibilityOffset = start.position
        renderDockVisibilityOffset()
        if dockVisibilityWindowGroup == nil {
            dockVisibilityWindowGroup = DockVisibilityWindowGroup(
                root: dockGlassBackgroundPanel ?? dock, frames: dockVisibilitySurfaceFrames)
        }
        if show {
            orderDockAndCapsuleFront()
        }
        // Preparation may synchronously lay out / paint / flush several windows. It
        // must not consume animation time before the first display callback even exists.
        let preparedAt = CACurrentMediaTime()
        dockVisibilityTimeline.prepare(at: preparedAt, waitsForFirstFrame: dockVisibilityClock == nil)
        if dockVisibilityClock == nil {
            let clock = DockVisibilityAnimationClock { [weak self] frameTime in
                self?.tickDockVisibility(at: frameTime)
            }
            dockVisibilityClock = clock
            clock.start(on: panelCurrentScreen(panel: dock), preparationMs: (preparedAt - now) * 1000)
        }
    }

    private func tickDockVisibility(at frameTime: CFTimeInterval) {
        guard let motion = dockVisibilityMotion else { return }
        let elapsed = dockVisibilityTimeline.advance(to: frameTime)
        let settled = motion.isSettled(at: elapsed)
        dockVisibilityOffset = settled ? motion.target : motion.sample(at: elapsed).position
        // Submit the exact endpoint once, through the same window group as every
        // other frame. Detaching first would re-submit each surface independently.
        renderDockVisibilityOffset()
        guard settled else { return }
        if !panelsAreVisible {
            dockVisibilityWindowGroup?.orderOutTogether()
        }
        dockVisibilityClock?.invalidate()
        dockVisibilityClock = nil
        dockVisibilityWindowGroup?.detach()
        dockVisibilityWindowGroup = nil
        dockVisibilityMotion = nil
    }

    /// Also used by fullscreen prediction and teardown: no delayed tick may resurrect panels.
    func cancelDockVisibilityAnimation() {
        dockVisibilityClock?.invalidate()
        dockVisibilityClock = nil
        dockVisibilityWindowGroup?.detach()
        dockVisibilityWindowGroup = nil
        guard dockVisibilityMotion != nil || dockVisibilityOffset != 0 else { return }
        dockVisibilityMotion = nil
        dockVisibilityOffset = 0
        renderDockVisibilityOffset()
    }

    /// `DOCK_EDGEHOVER_TRACE=1` 时每次实际 SHOW/HIDE 切换打一行：单调时钟（`CACurrentMediaTime`，
    /// 不受墙钟调整影响，用于量切换间隔）+ 鼠标坐标 + 是否在底边热区 + 是否在任务条/胶囊矩形内 +
    /// 当前唤醒延迟设置——足够从这一行日志本身看出"为什么"切换，而不只是"切换了"。
    private func logEdgeHoverTrace(shouldShow: Bool) {
        let mouse = NSEvent.mouseLocation
        let inHotZone = dockPanel.map { isMouseInBottomHotZone(on: panelCurrentScreen(panel: $0)) } ?? false
        let inPanelRect = (dockPanel?.frame.contains(mouse) ?? false) || (capsulePanel?.frame.contains(mouse) ?? false)
        print(String(
            format: "[edgehover] %@ t=%.4f mouse=(%.1f,%.1f) hotZone=%@ panelRect=%@ delay=%.2f reasons=%@",
            shouldShow ? "SHOW" : "HIDE",
            CACurrentMediaTime(),
            mouse.x, mouse.y,
            inHotZone ? "1" : "0",
            inPanelRect ? "1" : "0",
            settingsStore.edgeAutoHideDelay,
            "\(visibilityState.hideReasons)"
        ))
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    private func isMouseInBottomHotZone(on screen: NSScreen) -> Bool {
        let mouse = NSEvent.mouseLocation
        guard screen.frame.contains(mouse) else { return false }
        return mouse.y - screen.frame.minY <= Self.hoverHotZone
    }

    func isMouseOutsideInteractivePanels() -> Bool {
        let mouse = NSEvent.mouseLocation
        if let dock = dockPanel {
            let interactiveFrame = PanelGeometry.dockInteractiveFrame(
                restingDock: lastDockTargetFrame,
                presentedDock: dock.frame,
                restingCapsule: settingsStore.showDrawer && capsulePanel != nil ? lastCapsuleTargetFrame : nil,
                presentedCapsule: settingsStore.showDrawer ? capsulePanel?.frame : nil,
                shadowPadding: Self.shadowPadding,
                screenBottom: panelCurrentScreen(panel: dock).frame.minY)
            if interactiveFrame.contains(mouse) { return false }
        }
        if drawerWantsOpen, let drawer = drawerPanel,
           PanelGeometry.folderPopupPlateFrame(panelFrame: drawer.frame).contains(mouse) { return false }
        if folderPopupContains(mouse) { return false }
        // 唤醒热区贯穿整条屏幕底边，比居中的任务条/胶囊窄矩形宽得多；停在热区内但任务条范围外
        // 若判"已离开"会立刻武装 idle-hide，与刚触发的唤醒反复打架（唤醒→隐藏→唤醒…闪烁）。
        // 只在有限唤醒延迟下才压住——999/-1 两种模式没有这种打架，不该额外改变行为（见规则注释）。
        if EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: settingsStore.edgeAutoHideDelay),
           let dock = dockPanel, isMouseInBottomHotZone(on: panelCurrentScreen(panel: dock)) {
            return false
        }
        return true
    }
}

/// Display-synchronized on macOS 14+, with a common-run-loop fallback for 12/13.
/// The callback holds the coordinator weakly, so the display link cannot keep it alive.
@MainActor
final class DockVisibilityAnimationClock: NSObject {
    private var displayLink: AnyObject?
    private var timer: Timer?
    private let tick: (CFTimeInterval) -> Void
    private var timing = DockAnimationTiming()
    private var running = false
    private var inTick = false
    private var reported = false
    private var preparationMs: Double = 0
    private var maximumFPS = 0
    private var clockStartedAt: CFTimeInterval = 0
    private var firstCallbackDelayMs: Double = 0
    private let performanceLog = Logger(subsystem: "com.caye.macosdockcc.v2", category: "animation-performance")

    init(tick: @escaping (CFTimeInterval) -> Void) { self.tick = tick }

    func start(on screen: NSScreen, preparationMs: Double) {
        running = true
        clockStartedAt = CACurrentMediaTime()
        self.preparationMs = preparationMs
        maximumFPS = screen.maximumFramesPerSecond
        if #available(macOS 14.0, *) {
            let link = screen.displayLink(target: self, selector: #selector(frameTick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.renderTick(at: CACurrentMediaTime(), expectedInterval: 1.0 / 120)
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @available(macOS 14.0, *)
    @objc private func frameTick(_ link: CADisplayLink) {
        // Use the scheduled presentation time, not the varying moment our callback
        // happens to run. Motion then follows display cadence rather than scheduling jitter.
        renderTick(at: link.targetTimestamp, expectedInterval: link.targetTimestamp - link.timestamp)
    }

    private func renderTick(at frameTime: CFTimeInterval, expectedInterval: TimeInterval) {
        guard running else { return }
        let began = CACurrentMediaTime()
        if timing.frameCount == 0 { firstCallbackDelayMs = (began - clockStartedAt) * 1000 }
        inTick = true
        tick(frameTime)
        timing.record(at: began, expectedInterval: expectedInterval, work: CACurrentMediaTime() - began)
        inTick = false
        if !running { report() }
    }

    func invalidate() {
        running = false
        if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.invalidate() }
        displayLink = nil
        timer?.invalidate()
        timer = nil
        if !inTick { report() }
    }

    private func report() {
        guard !reported else { return }
        reported = true
        // One summary per flight; no file writes or log messages on the per-frame path.
        performanceLog.notice("flight frames=\(self.timing.frameCount) callbackFPS=\(self.timing.callbackFPS) screenMaxFPS=\(self.maximumFPS) maxGapMs=\(self.timing.maximumGap * 1000) maxWorkMs=\(self.timing.maximumWork * 1000) missedCallbacks=\(self.timing.missedCallbacks) prepareMs=\(self.preparationMs) firstCallbackDelayMs=\(self.firstCallbackDelayMs)")
    }
}
