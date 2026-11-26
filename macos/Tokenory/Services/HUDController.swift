// [INPUT]: HUD preferences, shared usage store, live display/Dock metrics, and drag gestures.
// [OUTPUT]: Nonactivating floating panel with free drag, magnetic edge snapping, Dock/menu-bar dodge, and edge retract/pop-out motion.
// [POS]: App lifecycle owner; a HUD never changes the app's Dock activation policy.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import CoreText
import Observation
import SwiftUI

@MainActor
final class HUDController {
    private enum Visibility { case disabled, visible, idle, snoozed }

    private enum MotionMode {
        case idle
        case dragging
        case spring(target: CGPoint, stiffness: Double, damping: Double, fadeIn: Bool)
        case retracting(start: CGPoint, end: CGPoint, startUptime: TimeInterval, onDone: @MainActor () -> Void)
        case hidden
    }

    private struct Activity: Equatable {
        let day: String?
        let zone: String?
        let tokens: TokenBreakdown
        let records: Int64
        let requests: Int64?
    }

    private struct DragSample {
        let point: CGPoint
        let time: TimeInterval
    }

    static let shared = HUDController()
    private(set) var panel: NSPanel?
    private let preferences: HUDPreferences
    private let store: UsageStore
    private let idleTimeout: Duration
    private let openStatistics: (() -> Void)?
    private let reduceMotion: () -> Bool

    private var visibility = Visibility.disabled
    private var autoHideWasEnabled = false
    private var lastActivity: Activity?
    private var visibilityTask: Task<Void, Never>?
    private var appliedAnchor: HUDDockAnchor?
    private var observing = false
    private var monitorTask: Task<Void, Never>?
    private var activeScreenFrame: CGRect?
    private var activeDisplayID: UInt32?
    private var lastRestingOrigin: CGPoint?
    private var screenObserver: NSObjectProtocol?
    private var animator: HUDAnimator?

    private var motionGeneration = 0
    private var motionMode: MotionMode = .hidden
    private var motionPosition: CGPoint = .zero
    private var motionVelocity: CGVector = .zero
    private var motionTimer: Timer?
    private var lastFrameUptime: TimeInterval = 0
    private var isHiding = false
    private var isHoveringHUD = false

    // Drag state
    private var dragOffset: CGPoint = .zero
    private var dragSamples: [DragSample] = []

    // Pointer-follow screen switch debounce
    private var pendingSwitchDisplayID: UInt32?
    private var pendingSwitchTask: Task<Void, Never>?
    private var isSwitchingScreen = false
    private var switchingTargetScreen: NSScreen?
    private var dockWasRevealed = false
    private var menuWasRevealed = false

    init(preferences: HUDPreferences = .shared, store: UsageStore = .shared,
         idleTimeout: Duration = .seconds(30), openStatistics: (() -> Void)? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.preferences = preferences; self.store = store
        self.idleTimeout = idleTimeout
        self.openStatistics = openStatistics
        self.reduceMotion = reduceMotion
    }

    static let fontRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: "SairaExtraCondensed-SemiBold", withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    func start() {
        guard !observing else { return }
        observing = true
        _ = Self.fontRegistered
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenParametersChanged() }
        }
        observeHUD()
    }

    private func observeHUD() {
        guard observing else { return }
        withObservationTracking {
            let autoHide = preferences.autoHideWhenIdle
            let autoHideChanged = autoHideWasEnabled != autoHide
            autoHideWasEnabled = autoHide
            let hasNewUsage = autoHide && observeNewUsage()
            if !autoHide { lastActivity = nil }

            if !preferences.enabled {
                if visibility != .disabled { setVisibility(.disabled) }
            } else if visibility != .snoozed && (visibility == .disabled || autoHideChanged || hasNewUsage) {
                showHUD()
            }

            let anchor = preferences.anchor
            if visibility == .visible, appliedAnchor != anchor {
                if case .dragging = motionMode {
                    appliedAnchor = anchor
                } else {
                    moveToAnchor(anchor, animated: !reduceMotion())
                }
            }

            let followPointer = preferences.followPointer
            if !followPointer, preferences.pinnedDisplayID == nil, let currentID = activeDisplayID {
                preferences.pinnedDisplayID = currentID
            } else if followPointer, visibility == .visible {
                evaluateEnvironmentTick()
            }

            HUDSound.shared.update(preferences: preferences)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHUD() }
        }
    }

    private func observeNewUsage() -> Bool {
        guard let summary = store.today?.summary else { return false }
        let activity = Activity(day: store.todayDay, zone: store.todayTimeZone, tokens: summary.tokenBreakdown,
                                records: summary.recordCount, requests: summary.requests)
        let previous = lastActivity
        lastActivity = activity
        if let previous, previous.day == activity.day, previous.zone == activity.zone {
            return activity != previous
        }
        return activity.records > 0 && (previous == nil || previous?.zone == activity.zone)
    }

    func dismissFromHUD() {
        let dismissal = preferences.dismissal
        guard visibility == .visible, preferences.enabled, dismissal != .ignore else { return }
        if let duration = dismissal.duration {
            setVisibility(.snoozed, timeout: duration)
        } else {
            preferences.enabled = false
            setVisibility(.disabled)
        }
    }

    private func showHUD() {
        setVisibility(.visible, timeout: preferences.autoHideWhenIdle ? idleTimeout : nil)
    }

    private func scheduleIdleTimeoutIfNeeded() {
        visibilityTask?.cancel()
        visibilityTask = nil
        guard visibility == .visible, preferences.autoHideWhenIdle, !isHoveringHUD else { return }
        if case .dragging = motionMode { return }
        let timeout = idleTimeout
        visibilityTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled, let self, preferences.enabled, preferences.autoHideWhenIdle else { return }
            if case .dragging = motionMode { return }
            if isHoveringHUD { return }
            setVisibility(.idle)
        }
    }

    private func setVisibility(_ next: Visibility, timeout: Duration? = nil) {
        visibilityTask?.cancel()
        visibilityTask = nil
        visibility = next
        if next == .visible {
            if panel?.isVisible != true || isHiding { show() }
        } else {
            hide()
        }
        guard let timeout else { return }
        if next == .visible {
            scheduleIdleTimeoutIfNeeded()
            return
        }
        visibilityTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled, let self, preferences.enabled else { return }
            if next == .snoozed {
                showHUD()
            } else if preferences.autoHideWhenIdle {
                setVisibility(.idle)
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: MechanicalHUDView.windowSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("mechanical-hud")
        panel.title = L("hud.title")
        panel.level = .floating; panel.isFloatingPanel = true
        // Join desktop Spaces without opting into other apps' full-screen Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        // NSPanel starts with an empty NSView; replace it with hosted content on first show too.
        panel.contentView = nil
        panel.setContentSize(MechanicalHUDView.windowSize)
        self.panel = panel
        return panel
    }

    private func show() {
        let panel = ensurePanel()
        motionGeneration += 1
        pendingSwitchTask?.cancel(); pendingSwitchTask = nil; pendingSwitchDisplayID = nil
        isSwitchingScreen = false; switchingTargetScreen = nil

        let wasHidden = !panel.isVisible
        let interruptedHide = isHiding
        isHiding = false

        if panel.contentView == nil {
            let animator = HUDAnimator()
            self.animator = animator
            panel.contentView = NSHostingView(rootView: MechanicalHUDView(
                canPlaySound: { [weak panel] in panel?.isOnActiveSpace == true },
                dismiss: { [weak self] in self?.dismissFromHUD() },
                openStatistics: openStatistics,
                animator: animator,
                onDragChanged: { [weak self] in self?.handleDragChanged() },
                onDragEnded: { [weak self] in self?.handleDragEnded() },
                onHoverChanged: { [weak self] hovering in self?.handleHoverChanged(hovering) }
            ).environment(store).environment(preferences).focusEffectDisabled())
        }

        guard let screen = targetScreenForShow() else { return }
        let metrics = HUDDisplayMetrics.live(for: screen, pointer: NSEvent.mouseLocation)
        let anchor = preferences.anchor
        let restingOrigin = HUDLayoutSolver.origin(for: anchor, in: metrics, size: panel.frame.size)

        activeScreenFrame = screen.frame
        activeDisplayID = HUDDisplayMetrics.displayID(for: screen)
        appliedAnchor = anchor
        lastRestingOrigin = restingOrigin

        if reduceMotion() {
            stopMotionTimer()
            motionMode = .idle
            motionPosition = restingOrigin
            motionVelocity = .zero
            panel.setFrameOrigin(restingOrigin)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else if interruptedHide && !wasHidden {
            // Interrupt an in-progress hide smoothly from current position!
            motionPosition = panel.frame.origin
            motionVelocity = .zero
            panel.orderFrontRegardless()
            startSpring(
                to: restingOrigin,
                stiffness: HUDMotionSpec.popStiffness,
                damping: HUDMotionSpec.popDamping,
                fadeIn: true
            )
        } else {
            // Pop out from the docked edge with a crisp slight bounce.
            let startOrigin = HUDLayoutSolver.hiddenOrigin(
                for: anchor.edge,
                restingOrigin: restingOrigin,
                in: screen.frame,
                size: panel.frame.size
            )
            motionPosition = startOrigin
            motionVelocity = .zero
            panel.setFrameOrigin(startOrigin)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            startSpring(
                to: restingOrigin,
                stiffness: HUDMotionSpec.popStiffness,
                damping: HUDMotionSpec.popDamping,
                fadeIn: true
            )
        }

        startMonitoringEnvironment()
    }

    private func hide() {
        monitorTask?.cancel(); monitorTask = nil
        pendingSwitchTask?.cancel(); pendingSwitchTask = nil; pendingSwitchDisplayID = nil
        isSwitchingScreen = false; switchingTargetScreen = nil
        // Immediately stop rolling animation and sound when hiding begins.
        animator?.settle()
        HUDSound.shared.stop()
        motionGeneration += 1
        let generation = motionGeneration

        guard let panel else {
            stopMotionTimer()
            motionMode = .hidden
            animator = nil
            isHiding = false
            return
        }
        if reduceMotion() || !panel.isVisible {
            finishHide(panel)
            return
        }

        isHiding = true
        let screenFrame = activeScreenFrame ?? panel.screen?.frame ?? NSScreen.main?.frame ?? panel.frame
        let start = panel.frame.origin
        let end = HUDLayoutSolver.hiddenOrigin(
            for: (appliedAnchor ?? preferences.anchor).edge,
            restingOrigin: lastRestingOrigin ?? start,
            in: screenFrame,
            size: panel.frame.size
        )
        startRetract(from: start, to: end) { [weak self] in
            guard let self, self.motionGeneration == generation, let panel = self.panel else { return }
            self.finishHide(panel)
        }
    }

    private func finishHide(_ panel: NSPanel) {
        stopMotionTimer()
        motionMode = .hidden
        isHiding = false
        panel.orderOut(nil)
        panel.alphaValue = 1
        // Release the SwiftUI task as well as hiding the window; no hidden rolling or sound.
        panel.contentView = nil
        animator = nil
    }

    func stop() {
        observing = false
        setVisibility(.disabled)
        lastActivity = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    // MARK: - Drag & Magnetic Snap

    private func handleHoverChanged(_ hovering: Bool) {
        isHoveringHUD = hovering
        if hovering {
            visibilityTask?.cancel()
            visibilityTask = nil
        } else if visibility == .visible {
            scheduleIdleTimeoutIfNeeded()
        }
    }

    private func handleDragChanged() {
        guard let panel, panel.isVisible, !isHiding else { return }
        let pointer = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime

        if case .dragging = motionMode {
            let nextOrigin = CGPoint(x: pointer.x - dragOffset.x, y: pointer.y - dragOffset.y)
            motionPosition = nextOrigin
            panel.setFrameOrigin(nextOrigin)
            dragSamples.append(DragSample(point: pointer, time: now))
            while dragSamples.count > 6, let first = dragSamples.first, now - first.time > 0.09 {
                dragSamples.removeFirst()
            }
        } else {
            // Interrupt any in-progress spring or screen switch cleanly.
            stopMotionTimer()
            pendingSwitchTask?.cancel(); pendingSwitchTask = nil; pendingSwitchDisplayID = nil
            isSwitchingScreen = false; switchingTargetScreen = nil
            visibilityTask?.cancel(); visibilityTask = nil

            motionMode = .dragging
            motionVelocity = .zero
            panel.alphaValue = 1
            let currentOrigin = panel.frame.origin
            motionPosition = currentOrigin
            dragOffset = CGPoint(x: pointer.x - currentOrigin.x, y: pointer.y - currentOrigin.y)
            dragSamples = [DragSample(point: pointer, time: now)]
        }
    }

    private func handleDragEnded() {
        guard case .dragging = motionMode, let panel else { return }
        let velocity = computeDragVelocity()
        dragSamples.removeAll(keepingCapacity: true)

        let currentOrigin = panel.frame.origin
        let projectedCenter = CGPoint(
            x: currentOrigin.x + velocity.dx * HUDMotionSpec.releaseProjection + panel.frame.width / 2,
            y: currentOrigin.y + velocity.dy * HUDMotionSpec.releaseProjection + panel.frame.height / 2
        )
        guard let targetScreen = screenContainingOrNearest(to: projectedCenter) else {
            motionMode = .idle
            scheduleIdleTimeoutIfNeeded()
            return
        }

        let metrics = HUDDisplayMetrics.live(for: targetScreen, pointer: NSEvent.mouseLocation)
        let newAnchor = HUDLayoutSolver.snap(from: currentOrigin, velocity: velocity, in: metrics, size: panel.frame.size)
        let targetOrigin = HUDLayoutSolver.origin(for: newAnchor, in: metrics, size: panel.frame.size)

        activeScreenFrame = targetScreen.frame
        activeDisplayID = HUDDisplayMetrics.displayID(for: targetScreen)
        appliedAnchor = newAnchor
        lastRestingOrigin = targetOrigin
        preferences.anchor = newAnchor
        if let displayID = activeDisplayID {
            preferences.pinnedDisplayID = displayID
        }

        if reduceMotion() {
            motionPosition = targetOrigin
            motionVelocity = .zero
            motionMode = .idle
            panel.setFrameOrigin(targetOrigin)
            panel.alphaValue = 1
        } else {
            let snap = HUDLayoutSolver.magneticSnapParameters(
                from: currentOrigin,
                to: targetOrigin,
                releaseVelocity: velocity
            )
            motionPosition = currentOrigin
            motionVelocity = snap.initialVelocity
            startSpring(to: targetOrigin, stiffness: snap.stiffness, damping: snap.damping, fadeIn: false)
        }
        scheduleIdleTimeoutIfNeeded()
    }

    private func computeDragVelocity() -> CGVector {
        guard dragSamples.count >= 2, let first = dragSamples.first, let last = dragSamples.last else {
            return .zero
        }
        let dt = max(0.016, last.time - first.time)
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }

    // MARK: - Placement, Screen Switching & Dynamic Dodge

    private func moveToAnchor(_ anchor: HUDDockAnchor, animated: Bool, useDodgeCurve: Bool = false) {
        guard let panel, panel.isVisible, !isHiding else { return }
        guard let screen = currentOrTargetScreen() else { return }
        let metrics = HUDDisplayMetrics.live(
            for: screen,
            pointer: NSEvent.mouseLocation,
            dockWasRevealed: dockWasRevealed,
            menuWasRevealed: menuWasRevealed
        )
        let target = HUDLayoutSolver.origin(for: anchor, in: metrics, size: panel.frame.size)

        activeScreenFrame = screen.frame
        activeDisplayID = HUDDisplayMetrics.displayID(for: screen)
        appliedAnchor = anchor
        lastRestingOrigin = target

        if !animated || reduceMotion() {
            stopMotionTimer()
            motionPosition = target
            motionVelocity = .zero
            motionMode = .idle
            panel.setFrameOrigin(target)
            panel.alphaValue = 1
        } else {
            let stiffness = useDodgeCurve ? HUDMotionSpec.dodgeStiffness : HUDMotionSpec.snapStiffness
            let damping = useDodgeCurve ? HUDMotionSpec.dodgeDamping : HUDMotionSpec.snapDamping
            if case .spring(let existingTarget, _, _, false) = motionMode,
               hypot(existingTarget.x - target.x, existingTarget.y - target.y) < 0.5 {
                return
            }
            motionPosition = panel.frame.origin
            startSpring(to: target, stiffness: stiffness, damping: damping, fadeIn: false)
        }
    }

    private func handleScreenParametersChanged() {
        guard visibility == .visible, let panel, panel.isVisible, !isHiding else { return }
        if case .dragging = motionMode { return }
        if isSwitchingScreen { return }
        let sameDisplayFrame = currentOrTargetScreen()?.frame == activeScreenFrame
        moveToAnchor(preferences.anchor, animated: sameDisplayFrame && !reduceMotion(), useDodgeCurve: true)
    }

    private func startMonitoringEnvironment() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let fastPoll = self.evaluateEnvironmentTick()
                let interval: Duration = fastPoll ? .milliseconds(80) : .milliseconds(220)
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// Returns `true` when pointer is near an auto-hidden Dock or menu bar so we can sample more responsively.
    @discardableResult
    private func evaluateEnvironmentTick() -> Bool {
        guard let panel, panel.isVisible, !isHiding else { return false }
        if case .dragging = motionMode { return false }

        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens

        // 1. Pointer-following screen switch (with 120ms hysteresis).
        if preferences.followPointer,
           let pointerIndex = Self.activeScreenIndex(pointer: pointer, frames: screens.map(\.frame)) {
            let pointerScreen = screens[pointerIndex]
            let pointerDisplayID = HUDDisplayMetrics.displayID(for: pointerScreen)

            if pointerScreen.frame != activeScreenFrame {
                if pendingSwitchDisplayID != pointerDisplayID {
                    pendingSwitchTask?.cancel()
                    pendingSwitchDisplayID = pointerDisplayID
                    pendingSwitchTask = Task { [weak self] in
                        do { try await Task.sleep(for: HUDMotionSpec.switchDebounce) } catch { return }
                        guard !Task.isCancelled, let self else { return }
                        self.pendingSwitchDisplayID = nil
                        self.pendingSwitchTask = nil
                        guard self.preferences.followPointer, self.visibility == .visible, !self.isHiding else { return }
                        if case .dragging = self.motionMode { return }
                        let currentScreens = NSScreen.screens
                        guard let idx = Self.activeScreenIndex(pointer: NSEvent.mouseLocation, frames: currentScreens.map(\.frame)) else { return }
                        let confirmedScreen = currentScreens[idx]
                        if confirmedScreen.frame != self.activeScreenFrame {
                            self.switchToScreen(confirmedScreen)
                        }
                    }
                }
                return true
            } else {
                // Pointer returned to the HUD's current screen: cancel pending switch or interrupt retract!
                pendingSwitchTask?.cancel(); pendingSwitchTask = nil; pendingSwitchDisplayID = nil
                if isSwitchingScreen, case .retracting = motionMode {
                    isSwitchingScreen = false
                    switchingTargetScreen = nil
                    if let rest = lastRestingOrigin {
                        motionPosition = panel.frame.origin
                        motionVelocity = .zero
                        startSpring(
                            to: rest,
                            stiffness: HUDMotionSpec.popStiffness,
                            damping: HUDMotionSpec.popDamping,
                            fadeIn: true
                        )
                    }
                }
            }
        } else {
            pendingSwitchTask?.cancel(); pendingSwitchTask = nil; pendingSwitchDisplayID = nil
        }

        // 2. Dynamic Dock / Menu Bar avoidance on the HUD's current screen.
        let canDodge: Bool = switch motionMode {
        case .idle: true
        case .spring(_, _, _, let fadeIn): !fadeIn
        default: false
        }
        guard !isSwitchingScreen, canDodge, let screen = currentOrTargetScreen() else {
            return false
        }
        let metrics = HUDDisplayMetrics.live(
            for: screen,
            pointer: pointer,
            allScreens: screens,
            dockWasRevealed: dockWasRevealed,
            menuWasRevealed: menuWasRevealed
        )
        dockWasRevealed = metrics.dockAutoHidden && metrics.dockRect != nil
        menuWasRevealed = metrics.menuBarAutoHidden && metrics.menuBarHeight > 0
        let desired = HUDLayoutSolver.origin(for: preferences.anchor, in: metrics, size: panel.frame.size)
        let currentTarget: CGPoint = if case .spring(let target, _, _, _) = motionMode {
            target
        } else {
            panel.frame.origin
        }
        if hypot(desired.x - currentTarget.x, desired.y - currentTarget.y) >= 1 {
            lastRestingOrigin = desired
            if reduceMotion() {
                stopMotionTimer()
                motionPosition = desired
                motionVelocity = .zero
                motionMode = .idle
                panel.setFrameOrigin(desired)
            } else {
                motionPosition = panel.frame.origin
                startSpring(
                    to: desired,
                    stiffness: HUDMotionSpec.dodgeStiffness,
                    damping: HUDMotionSpec.dodgeDamping,
                    fadeIn: false
                )
            }
        }

        // Fast-poll only when Dock or menu bar is auto-hidden AND pointer is close to that edge or currently revealed.
        let nearAutoHiddenDock = metrics.dockAutoHidden
            && screen.frame.contains(pointer)
            && (metrics.dockRect != nil
                || (pointer.y - screen.frame.minY) <= 90
                || (pointer.x - screen.frame.minX) <= 90
                || (screen.frame.maxX - pointer.x) <= 90)
        let nearAutoHiddenMenu = metrics.menuBarAutoHidden
            && screen.frame.contains(pointer)
            && (metrics.menuBarHeight > 0 || (screen.frame.maxY - pointer.y) <= 60)
        return nearAutoHiddenDock || nearAutoHiddenMenu
    }

    private func switchToScreen(_ targetScreen: NSScreen) {
        guard let panel, panel.isVisible, !isHiding else { return }
        let anchor = preferences.anchor
        let metrics = HUDDisplayMetrics.live(for: targetScreen, pointer: NSEvent.mouseLocation)
        let targetOrigin = HUDLayoutSolver.origin(for: anchor, in: metrics, size: panel.frame.size)

        if reduceMotion() {
            stopMotionTimer()
            activeScreenFrame = targetScreen.frame
            activeDisplayID = HUDDisplayMetrics.displayID(for: targetScreen)
            appliedAnchor = anchor
            lastRestingOrigin = targetOrigin
            motionPosition = targetOrigin
            motionVelocity = .zero
            motionMode = .idle
            panel.setFrameOrigin(targetOrigin)
            panel.alphaValue = 1
            return
        }

        isSwitchingScreen = true
        switchingTargetScreen = targetScreen
        motionGeneration += 1
        let generation = motionGeneration

        let oldScreenFrame = activeScreenFrame ?? panel.screen?.frame ?? panel.frame
        let start = panel.frame.origin
        let retractEnd = HUDLayoutSolver.hiddenOrigin(
            for: anchor.edge,
            restingOrigin: lastRestingOrigin ?? start,
            in: oldScreenFrame,
            size: panel.frame.size
        )

        startRetract(from: start, to: retractEnd) { [weak self] in
            guard let self, self.motionGeneration == generation, let panel = self.panel, !self.isHiding else { return }
            self.isSwitchingScreen = false
            let destination = self.switchingTargetScreen ?? targetScreen
            self.switchingTargetScreen = nil

            let freshMetrics = HUDDisplayMetrics.live(for: destination, pointer: NSEvent.mouseLocation)
            let destAnchor = self.preferences.anchor
            let destResting = HUDLayoutSolver.origin(for: destAnchor, in: freshMetrics, size: panel.frame.size)
            let destStart = HUDLayoutSolver.hiddenOrigin(
                for: destAnchor.edge,
                restingOrigin: destResting,
                in: destination.frame,
                size: panel.frame.size
            )

            self.activeScreenFrame = destination.frame
            self.activeDisplayID = HUDDisplayMetrics.displayID(for: destination)
            self.appliedAnchor = destAnchor
            self.lastRestingOrigin = destResting
            self.motionPosition = destStart
            self.motionVelocity = .zero
            panel.setFrameOrigin(destStart)
            panel.alphaValue = 0
            self.startSpring(
                to: destResting,
                stiffness: HUDMotionSpec.popStiffness,
                damping: HUDMotionSpec.popDamping,
                fadeIn: true
            )
        }
    }

    // MARK: - Spring & Retract Motion Driver

    private func startSpring(to target: CGPoint, stiffness: Double, damping: Double, fadeIn: Bool) {
        motionMode = .spring(target: target, stiffness: stiffness, damping: damping, fadeIn: fadeIn)
        ensureMotionTimerRunning()
    }

    private func startRetract(from start: CGPoint, to end: CGPoint, onDone: @escaping @MainActor () -> Void) {
        motionPosition = start
        motionVelocity = .zero
        motionMode = .retracting(start: start, end: end, startUptime: ProcessInfo.processInfo.systemUptime, onDone: onDone)
        ensureMotionTimerRunning()
    }

    private func ensureMotionTimerRunning() {
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        guard motionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepMotionFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func stopMotionTimer() {
        motionTimer?.invalidate()
        motionTimer = nil
    }

    private func stepMotionFrame() {
        guard let panel else { stopMotionTimer(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0.001, min(0.032, now - lastFrameUptime))
        lastFrameUptime = now

        switch motionMode {
        case .spring(let target, let stiffness, let damping, let fadeIn):
            let settled = HUDLayoutSolver.stepSpring(
                position: &motionPosition,
                velocity: &motionVelocity,
                target: target,
                stiffness: stiffness,
                damping: damping,
                dt: dt
            )
            panel.setFrameOrigin(motionPosition)
            if fadeIn {
                panel.alphaValue = min(1, panel.alphaValue + dt / HUDMotionSpec.popAlphaDuration)
            } else {
                panel.alphaValue = 1
            }
            if settled && panel.alphaValue >= 0.999 {
                panel.setFrameOrigin(target)
                panel.alphaValue = 1
                motionMode = .idle
                stopMotionTimer()
            }

        case .retracting(let start, let end, let startUptime, let onDone):
            let elapsed = now - startUptime
            let t = min(1.0, max(0.0, elapsed / HUDMotionSpec.retractDuration))
            let ease = t * t * (0.4 + 0.6 * t)
            motionPosition = CGPoint(
                x: start.x + (end.x - start.x) * ease,
                y: start.y + (end.y - start.y) * ease
            )
            panel.setFrameOrigin(motionPosition)
            panel.alphaValue = max(0, 1.0 - pow(t, 1.8))
            if t >= 1.0 {
                panel.alphaValue = 0
                stopMotionTimer()
                motionMode = .idle
                onDone()
            }

        case .idle, .dragging, .hidden:
            stopMotionTimer()
        }
    }

    // MARK: - Display Resolution Helpers

    // Mouse location is available without Accessibility or screen-recording permissions.
    static func activeScreenIndex(pointer: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex(where: { $0.contains(pointer) })
    }

    private func targetScreenForShow() -> NSScreen? {
        let screens = NSScreen.screens
        if !preferences.followPointer, let pinned = preferences.pinnedDisplayID,
           let matched = screens.first(where: { HUDDisplayMetrics.displayID(for: $0) == pinned }) {
            return matched
        }
        if let index = Self.activeScreenIndex(pointer: NSEvent.mouseLocation, frames: screens.map(\.frame)) {
            return screens[index]
        }
        return NSScreen.main ?? screens.first
    }

    private func currentOrTargetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let activeDisplayID,
           let matched = screens.first(where: { HUDDisplayMetrics.displayID(for: $0) == activeDisplayID }) {
            return matched
        }
        return targetScreenForShow()
    }

    private func screenContainingOrNearest(to point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        if let containing = screens.first(where: { $0.frame.contains(point) }) {
            return containing
        }
        return screens.min { a, b in
            let da = hypot(point.x - a.frame.midX, point.y - a.frame.midY)
            let db = hypot(point.x - b.frame.midX, point.y - b.frame.midY)
            return da < db
        } ?? NSScreen.main
    }
}
