// [INPUT]: HUD preferences and the shared usage store.
// [OUTPUT]: Compact nonactivating panel that follows the pointer display and stays out of other apps' full-screen Spaces.
// [POS]: App lifecycle owner; a HUD never changes the app's Dock activation policy.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import CoreText
import Observation
import SwiftUI

@MainActor
final class HUDController {
    static let shared = HUDController()
    private(set) var panel: NSPanel?
    private let preferences: HUDPreferences
    private let store: UsageStore
    private var appliedPlacement: HUDPlacement?
    private var observing = false
    private var screenTask: Task<Void, Never>?
    private var activeScreenFrame: CGRect?
    private var screenObserver: NSObjectProtocol?

    init(preferences: HUDPreferences = .shared, store: UsageStore = .shared) {
        self.preferences = preferences; self.store = store
    }

    static let fontRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: "SairaExtraCondensed-SemiBold", withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    func start() {
        guard !observing else { return }
        observing = true
        _ = Self.fontRegistered
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.placeOnScreen() }
        }
        observePreferences()
        screenTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.followActiveScreen()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    private func observePreferences() {
        guard observing else { return }
        withObservationTracking {
            if preferences.enabled {
                if panel?.isVisible != true { show() }
            } else if panel?.isVisible == true { hide() }
            let placement = preferences.placement
            if preferences.enabled, appliedPlacement != placement {
                placeOnScreen()
            }
            HUDSound.shared.update(preferences: preferences)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePreferences() }
        }
    }

    private func show() {
        if panel == nil {
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
            let restored = panel.setFrameUsingName("MechanicalHUD")
            // Restore the position, but replace older saved dimensions with the compact size.
            let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setContentSize(MechanicalHUDView.windowSize)
            panel.setFrameTopLeftPoint(topLeft)
            panel.setFrameAutosaveName("MechanicalHUD")
            if !restored, let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 28,
                                             y: screen.visibleFrame.minY + 28))
            }
            self.panel = panel
        }
        guard let panel else { return }
        if panel.contentView == nil {
            panel.contentView = NSHostingView(rootView: MechanicalHUDView(canPlaySound: { [weak panel] in
                panel?.isOnActiveSpace == true
            })
                .environment(store).environment(preferences).focusEffectDisabled())
        }
        placeOnScreen()
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        // Release the SwiftUI task as well as hiding the window; no hidden rolling or sound.
        panel?.contentView = nil
        HUDSound.shared.stop()
    }

    func stop() {
        observing = false
        screenTask?.cancel(); screenTask = nil
        hide()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    // Mouse location is available without Accessibility or screen-recording permissions.
    static func activeScreenIndex(pointer: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex(where: { $0.contains(pointer) })
    }

    private var activeScreen: NSScreen? {
        let screens = NSScreen.screens
        if let index = Self.activeScreenIndex(pointer: NSEvent.mouseLocation, frames: screens.map(\.frame)) {
            return screens[index]
        }
        return NSScreen.main
    }

    private func followActiveScreen() {
        guard panel?.isVisible == true, let screen = activeScreen,
              screen.frame != activeScreenFrame else { return }
        placeOnScreen()
    }

    private func placeOnScreen() {
        guard let panel, let screen = activeScreen else { return }
        activeScreenFrame = screen.frame
        // visibleFrame excludes the menu bar and the Dock on any edge.
        panel.setFrameOrigin(preferences.placement.origin(in: screen.visibleFrame, screenFrame: screen.frame, size: panel.frame.size))
        appliedPlacement = preferences.placement
    }
}
