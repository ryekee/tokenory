// [INPUT]: Screen geometry, live Dock/menu bar bounds, pointer coordinates, and drag release state.
// [OUTPUT]: Edge-anchored HUD placement with Dock/menu-bar/notch avoidance, magnetic snap math, and spring physics.
// [POS]: Pure layout and motion math for HUDController; no direct AppKit window mutation.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import CoreGraphics

enum HUDEdge: String, Codable, CaseIterable, Sendable {
    case top, bottom, left, right
}

struct HUDDockAnchor: Equatable, Codable, Sendable {
    var edge: HUDEdge
    /// Normalized 0...1 along the edge: left-to-right for top/bottom, top-to-bottom for left/right.
    var along: Double

    init(edge: HUDEdge, along: Double) {
        self.edge = edge
        self.along = Self.clamp(along)
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    func matchingPreset(tolerance: Double = 0.04) -> HUDPlacement? {
        switch edge {
        case .top:
            if along <= tolerance { return .topLeft }
            if abs(along - 0.5) <= tolerance { return .topCenter }
            if along >= 1 - tolerance { return .topRight }
            return nil
        case .bottom:
            if along <= tolerance { return .bottomLeft }
            if abs(along - 0.5) <= tolerance { return .bottomCenter }
            if along >= 1 - tolerance { return .bottomRight }
            return nil
        case .left, .right:
            return nil
        }
    }
}

struct HUDMotionSpec {
    /// Visible orange enamel case inset from screen edges (window has 5 pt transparent shadow padding).
    static let casePadding: CGFloat = 5
    static let edgeInset: CGFloat = 10
    static let dockClearance: CGFloat = 8
    static let hiddenOffscreenPadding: CGFloat = 14

    // Tuned "磁吸微弹" (Magnetic Tactile) physics parameters.
    static let snapStiffness: Double = 340
    static let snapDamping: Double = 22
    static let distanceBounce: Double = 0.35
    static let releaseProjection: Double = 0.10
    static let retractDuration: Double = 0.125
    static let popStiffness: Double = 420
    static let popDamping: Double = 24
    static let dodgeStiffness: Double = 220
    static let dodgeDamping: Double = 26
    static let popAlphaDuration: Double = 0.085
    static let switchDebounce: Duration = .milliseconds(120)
}

struct HUDDisplayMetrics: Equatable, Sendable {
    let screenFrame: CGRect
    let visibleFrame: CGRect
    /// Visible Dock bounds in AppKit screen coordinates (nil when Dock is hidden or absent on this screen).
    let dockRect: CGRect?
    /// Active menu bar height at the top of `screenFrame` (0 when auto-hidden and collapsed).
    let menuBarHeight: CGFloat
    /// Hardware notch rect in AppKit coordinates when present (e.g. MacBook Pro built-in display).
    let notchRect: CGRect?
    /// Whether the Dock appears to be configured for auto-hide on this screen.
    let dockAutoHidden: Bool
    /// Whether the menu bar appears to be configured for auto-hide on this screen.
    let menuBarAutoHidden: Bool

    init(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        dockRect: CGRect? = nil,
        menuBarHeight: CGFloat? = nil,
        notchRect: CGRect? = nil,
        dockAutoHidden: Bool = false,
        menuBarAutoHidden: Bool = false
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.dockRect = dockRect
        self.menuBarHeight = menuBarHeight ?? max(0, screenFrame.maxY - visibleFrame.maxY)
        self.notchRect = notchRect
        self.dockAutoHidden = dockAutoHidden
        self.menuBarAutoHidden = menuBarAutoHidden
    }

    @MainActor
    static func live(
        for screen: NSScreen,
        pointer: CGPoint,
        allScreens: [NSScreen] = NSScreen.screens,
        dockWasRevealed: Bool = false,
        menuWasRevealed: Bool = false
    ) -> HUDDisplayMetrics {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let primaryMaxY = allScreens.first?.frame.maxY ?? screenFrame.maxY

        let staticMenuHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        let menuBarAutoHidden = staticMenuHeight < 1

        let dockPrefs = DockPreferencesSnapshot.current()
        let staticBottomDock = max(0, visibleFrame.minY - screenFrame.minY)
        let staticLeftDock = max(0, visibleFrame.minX - screenFrame.minX)
        let staticRightDock = max(0, screenFrame.maxX - visibleFrame.maxX)
        let hasStaticDockOnThisScreen = staticBottomDock > 1 || staticLeftDock > 1 || staticRightDock > 1
        let dockAutoHidden = dockPrefs.autohide && !hasStaticDockOnThisScreen

        let notchRect = Self.notchRect(for: screen)
        let probedMenuHeight = menuBarAutoHidden
            ? probeAutoHiddenMenuBarHeight(in: screenFrame, primaryMaxY: primaryMaxY)
            : nil

        var activeMenuHeight = staticMenuHeight
        if menuBarAutoHidden {
            if let revealedHeight = probedMenuHeight, revealedHeight > 1 {
                activeMenuHeight = revealedHeight
            } else if screenFrame.contains(pointer) {
                let fallback = NSApplication.shared.mainMenu?.menuBarHeight ?? 24
                let estimatedMenuH = max(fallback > 0 ? fallback : 24, notchRect?.height ?? 0)
                let triggerDist: CGFloat = menuWasRevealed ? (estimatedMenuH + 14) : 3
                if (screenFrame.maxY - pointer.y) <= triggerDist {
                    activeMenuHeight = estimatedMenuH
                }
            }
        }

        let dockRect = estimateDockRect(
            in: screenFrame,
            visibleFrame: visibleFrame,
            prefs: dockPrefs,
            pointer: pointer,
            dockWasRevealed: dockWasRevealed
        )

        return HUDDisplayMetrics(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            dockRect: dockRect,
            menuBarHeight: activeMenuHeight,
            notchRect: notchRect,
            dockAutoHidden: dockAutoHidden,
            menuBarAutoHidden: menuBarAutoHidden
        )
    }

    @MainActor
    static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    @MainActor
    private static func notchRect(for screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let minX = left.maxX
        let maxX = right.minX
        guard maxX > minX + 1 else { return nil }
        let minY = min(left.minY, right.minY)
        let height = screen.frame.maxY - minY
        guard height > 1 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: height)
    }

    private struct DockPreferencesSnapshot {
        let tileSize: CGFloat
        let autohide: Bool
        let orientation: HUDEdge
        let iconCount: Int

        @MainActor
        static func current() -> DockPreferencesSnapshot {
            let defaults = UserDefaults(suiteName: "com.apple.dock")
            let rawTile = defaults?.double(forKey: "tilesize") ?? 48
            let tileSize = CGFloat(rawTile > 12 ? rawTile : 48)
            let autohide = defaults?.bool(forKey: "autohide") ?? false
            let orientationRaw = defaults?.string(forKey: "orientation") ?? "bottom"
            let orientation: HUDEdge = switch orientationRaw {
            case "left": .left
            case "right": .right
            default: .bottom
            }

            let persistentApps = (defaults?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
            let persistentOthers = (defaults?.array(forKey: "persistent-others") as? [[String: Any]]) ?? []
            let showRecents = defaults?.object(forKey: "show-recents") as? Bool ?? true
            let recentApps = showRecents ? ((defaults?.array(forKey: "recent-apps") as? [[String: Any]]) ?? []) : []

            var knownBundleIDs = Set<String>(["com.apple.finder"])
            for item in persistentApps + recentApps {
                if let tileData = item["tile-data"] as? [String: Any],
                   let bundleID = tileData["bundle-identifier"] as? String {
                    knownBundleIDs.insert(bundleID)
                }
            }
            let extraRunning = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .regular
                    && app.bundleIdentifier.map { !knownBundleIDs.contains($0) } ?? true
            }.count

            // Finder + pinned apps + unpinned running apps + recent apps + others + Trash.
            let totalIcons = 2 + persistentApps.count + extraRunning + recentApps.count + persistentOthers.count
            return DockPreferencesSnapshot(
                tileSize: tileSize,
                autohide: autohide,
                orientation: orientation,
                iconCount: max(4, totalIcons)
            )
        }
    }

    /// Computes the centered Dock bar rect on `screenFrame` using `com.apple.dock` item counts and `visibleFrame` thickness.
    private static func estimateDockRect(
        in screenFrame: CGRect,
        visibleFrame: CGRect,
        prefs: DockPreferencesSnapshot,
        pointer: CGPoint,
        dockWasRevealed: Bool
    ) -> CGRect? {
        let staticBottom = max(0, visibleFrame.minY - screenFrame.minY)
        let staticLeft = max(0, visibleFrame.minX - screenFrame.minX)
        let staticRight = max(0, screenFrame.maxX - visibleFrame.maxX)

        // Determine whether the Dock is currently visible on this screen and its thickness.
        let activeEdge: HUDEdge
        let thickness: CGFloat
        if staticBottom > 1 {
            activeEdge = .bottom
            thickness = staticBottom
        } else if staticLeft > 1 {
            activeEdge = .left
            thickness = staticLeft
        } else if staticRight > 1 {
            activeEdge = .right
            thickness = staticRight
        } else if prefs.autohide, screenFrame.contains(pointer) {
            activeEdge = prefs.orientation
            let estThickness = prefs.tileSize + 24
            let triggerDist: CGFloat = dockWasRevealed ? (estThickness + 24) : 3
            let nearEdge: Bool = switch activeEdge {
            case .bottom: (pointer.y - screenFrame.minY) <= triggerDist
            case .left: (pointer.x - screenFrame.minX) <= triggerDist
            case .right: (screenFrame.maxX - pointer.x) <= triggerDist
            case .top: false
            }
            guard nearEdge else { return nil }
            thickness = estThickness
        } else {
            return nil
        }

        // Each icon occupies roughly `tileSize + 4` pt plus dividers & glass padding (~56 pt).
        let estimatedSpan = CGFloat(prefs.iconCount) * (prefs.tileSize + 4) + 56
        switch activeEdge {
        case .bottom:
            let width = min(screenFrame.width, estimatedSpan)
            let minX = screenFrame.midX - width / 2
            return CGRect(x: minX, y: screenFrame.minY, width: width, height: thickness)
        case .left:
            let height = min(screenFrame.height, estimatedSpan)
            let minY = screenFrame.midY - height / 2
            return CGRect(x: screenFrame.minX, y: minY, width: thickness, height: height)
        case .right:
            let height = min(screenFrame.height, estimatedSpan)
            let minY = screenFrame.midY - height / 2
            return CGRect(x: screenFrame.maxX - thickness, y: minY, width: thickness, height: height)
        case .top:
            return nil
        }
    }

    private static func probeAutoHiddenMenuBarHeight(in screenFrame: CGRect, primaryMaxY: CGFloat) -> CGFloat? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var menuHeight: CGFloat?
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 24,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict),
                  cgRect.width > 1, cgRect.height > 1 else { continue }

            let appKitRect = CGRect(
                x: cgRect.minX,
                y: primaryMaxY - cgRect.maxY,
                width: cgRect.width,
                height: cgRect.height
            )
            let clipped = appKitRect.intersection(screenFrame)
            guard !clipped.isNull,
                  abs(clipped.maxY - screenFrame.maxY) <= 2,
                  clipped.width >= screenFrame.width * 0.5,
                  clipped.height <= 64 else { continue }
            menuHeight = max(menuHeight ?? 0, clipped.height)
        }
        return menuHeight
    }
}

enum HUDLayoutSolver {
    static func origin(for anchor: HUDDockAnchor, in metrics: HUDDisplayMetrics, size: CGSize) -> CGPoint {
        let screen = metrics.screenFrame
        let visible = metrics.visibleFrame
        let pad = HUDMotionSpec.casePadding
        let edgeInset = max(0, HUDMotionSpec.edgeInset - pad)
        let clearance = max(0, HUDMotionSpec.dockClearance - pad)

        var minX = screen.minX + edgeInset
        var maxX = screen.maxX - edgeInset - size.width
        let minY = screen.minY + edgeInset
        let maxY: CGFloat = metrics.menuBarHeight > 0
            ? screen.maxY - metrics.menuBarHeight - clearance - size.height
            : screen.maxY - edgeInset - size.height

        // Detect side-mounted Dock (explicit dockRect or fallback to visibleFrame side inset).
        if let dock = metrics.dockRect {
            let isSideDock = dock.height > dock.width
            if isSideDock {
                if abs(dock.minX - screen.minX) <= 12 {
                    minX = max(minX, dock.maxX + clearance)
                } else if abs(screen.maxX - dock.maxX) <= 12 {
                    maxX = min(maxX, dock.minX - clearance - size.width)
                }
            }
        } else {
            if visible.minX - screen.minX > 1 {
                minX = max(minX, visible.minX + clearance)
            }
            if screen.maxX - visible.maxX > 1 {
                maxX = min(maxX, visible.maxX - clearance - size.width)
            }
        }

        maxX = max(minX, maxX)
        let clampedMaxY = max(minY, maxY)

        var x: CGFloat
        var y: CGFloat

        switch anchor.edge {
        case .top, .bottom:
            x = minX + CGFloat(anchor.along) * (maxX - minX)
            y = anchor.edge == .top ? clampedMaxY : minY
        case .left, .right:
            x = anchor.edge == .left ? minX : maxX
            // along = 0 is top, along = 1 is bottom.
            y = clampedMaxY - CGFloat(anchor.along) * (clampedMaxY - minY)
        }

        // Bottom Dock avoidance: only lift when horizontally overlapping the Dock!
        let caseMinX = x + pad
        let caseMaxX = x + size.width - pad
        if let dock = metrics.dockRect {
            let isBottomDock = dock.width >= dock.height && (dock.minY - screen.minY) <= 12
            if isBottomDock {
                let dockLeft = dock.minX - HUDMotionSpec.dockClearance
                let dockRight = dock.maxX + HUDMotionSpec.dockClearance
                if caseMaxX > dockLeft && caseMinX < dockRight {
                    y = max(y, dock.maxY + clearance)
                }
            }
        } else if !metrics.dockAutoHidden, visible.minY - screen.minY > 1 {
            // Fallback when Dock rect wasn't available (e.g. headless tests without Dock window):
            // respect visibleFrame.minY so HUD never overlaps an unprobed Dock.
            y = max(y, visible.minY)
        }

        // Notch avoidance when menu bar is auto-hidden and collapsed.
        if metrics.menuBarHeight < 1, let notch = metrics.notchRect {
            let notchLeft = notch.minX - HUDMotionSpec.dockClearance
            let notchRight = notch.maxX + HUDMotionSpec.dockClearance
            if caseMaxX > notchLeft && caseMinX < notchRight {
                y = min(y, notch.minY - clearance - size.height)
            }
        }

        // Final safety clamp inside screenFrame.
        x = min(max(x, screen.minX), screen.maxX - size.width)
        y = min(max(y, screen.minY), screen.maxY - size.height)
        return CGPoint(x: round(x), y: round(y))
    }

    static func snap(
        from origin: CGPoint,
        velocity: CGVector,
        in metrics: HUDDisplayMetrics,
        size: CGSize
    ) -> HUDDockAnchor {
        let projX = origin.x + velocity.dx * HUDMotionSpec.releaseProjection
        let projY = origin.y + velocity.dy * HUDMotionSpec.releaseProjection
        let screen = metrics.screenFrame
        let cx = projX + size.width / 2
        let cy = projY + size.height / 2

        let dLeft = abs(cx - screen.minX)
        let dRight = abs(screen.maxX - cx)
        let dTop = abs(screen.maxY - cy)
        let dBottom = abs(cy - screen.minY)
        let minD = min(dLeft, dRight, dTop, dBottom)

        let chosenEdge: HUDEdge
        if minD == dTop { chosenEdge = .top }
        else if minD == dBottom { chosenEdge = .bottom }
        else if minD == dLeft { chosenEdge = .left }
        else { chosenEdge = .right }

        let pad = HUDMotionSpec.casePadding
        let edgeInset = max(0, HUDMotionSpec.edgeInset - pad)
        let clearance = max(0, HUDMotionSpec.dockClearance - pad)

        let along: Double
        switch chosenEdge {
        case .top, .bottom:
            let minX = screen.minX + edgeInset
            let maxX = screen.maxX - edgeInset - size.width
            along = maxX > minX ? Double((projX - minX) / (maxX - minX)) : 0.5
        case .left, .right:
            let minY = screen.minY + edgeInset
            let maxY = metrics.menuBarHeight > 0
                ? screen.maxY - metrics.menuBarHeight - clearance - size.height
                : screen.maxY - edgeInset - size.height
            along = maxY > minY ? Double((maxY - projY) / (maxY - minY)) : 0.5
        }
        return HUDDockAnchor(edge: chosenEdge, along: along)
    }

    static func hiddenOrigin(for edge: HUDEdge, restingOrigin: CGPoint, in screenFrame: CGRect, size: CGSize) -> CGPoint {
        let pad = HUDMotionSpec.hiddenOffscreenPadding
        switch edge {
        case .left:
            return CGPoint(x: screenFrame.minX - size.width - pad, y: restingOrigin.y)
        case .right:
            return CGPoint(x: screenFrame.maxX + pad, y: restingOrigin.y)
        case .top:
            return CGPoint(x: restingOrigin.x, y: screenFrame.maxY + pad)
        case .bottom:
            return CGPoint(x: restingOrigin.x, y: screenFrame.minY - size.height - pad)
        }
    }

    /// Computes distance-scaled magnetic snap parameters so farther releases bounce slightly more.
    static func magneticSnapParameters(
        from start: CGPoint,
        to target: CGPoint,
        releaseVelocity: CGVector
    ) -> (stiffness: Double, damping: Double, initialVelocity: CGVector) {
        let dx = target.x - start.x
        let dy = target.y - start.y
        let dist = hypot(dx, dy)
        let distFactor = min(1.0, dist / 240.0)
        let damping = max(8.0, HUDMotionSpec.snapDamping * (1.0 - HUDMotionSpec.distanceBounce * 0.42 * distFactor))
        let kick = HUDMotionSpec.distanceBounce * dist * 2.2
        let nx = dist > 1 ? dx / dist : 0
        let ny = dist > 1 ? dy / dist : 0
        let velocity = CGVector(
            dx: releaseVelocity.dx * 0.35 + nx * kick,
            dy: releaseVelocity.dy * 0.35 + ny * kick
        )
        return (HUDMotionSpec.snapStiffness, damping, velocity)
    }

    /// Advances a 2D spring by `dt` seconds using 4 sub-steps for stability at high stiffness.
    static func stepSpring(
        position: inout CGPoint,
        velocity: inout CGVector,
        target: CGPoint,
        stiffness: Double,
        damping: Double,
        dt: Double
    ) -> Bool {
        let clampedDt = min(0.032, max(0.001, dt))
        let steps = 4
        let sdt = clampedDt / Double(steps)
        for _ in 0..<steps {
            let ax = -stiffness * (position.x - target.x) - damping * velocity.dx
            let ay = -stiffness * (position.y - target.y) - damping * velocity.dy
            velocity.dx += ax * sdt
            velocity.dy += ay * sdt
            position.x += velocity.dx * sdt
            position.y += velocity.dy * sdt
        }
        let dist = hypot(position.x - target.x, position.y - target.y)
        let speed = hypot(velocity.dx, velocity.dy)
        if dist < 0.25 && speed < 1.5 {
            position = target
            velocity = .zero
            return true
        }
        return false
    }
}
