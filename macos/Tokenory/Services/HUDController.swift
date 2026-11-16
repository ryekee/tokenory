// [INPUT]: HUD preferences and the shared usage store.
// [OUTPUT]: Nonactivating floating panel with persisted, screen-clamped position.
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
    private var observing = false
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
            Task { @MainActor in self?.keepOnScreen() }
        }
        observePreferences()
    }

    private func observePreferences() {
        guard observing else { return }
        withObservationTracking {
            if preferences.enabled {
                if panel?.isVisible != true { show() }
            } else if panel?.isVisible == true { hide() }
            HUDSound.shared.update(preferences: preferences)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePreferences() }
        }
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 184),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier("mechanical-hud")
            panel.title = L("hud.title")
            panel.level = .floating; panel.isFloatingPanel = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.becomesKeyOnlyIfNeeded = true
            // NSPanel starts with an empty NSView; replace it with hosted content on first show too.
            panel.contentView = nil
            let restored = panel.setFrameUsingName("MechanicalHUD")
            panel.setFrameAutosaveName("MechanicalHUD")
            if !restored, let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 28,
                                             y: screen.visibleFrame.minY + 28))
            }
            self.panel = panel
        }
        guard let panel else { return }
        if panel.contentView == nil {
            panel.contentView = NSHostingView(rootView: MechanicalHUDView()
                .environment(store).environment(preferences).focusEffectDisabled())
        }
        keepOnScreen()
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
        hide()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func keepOnScreen() {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: max(bounds.minX, min(panel.frame.minX, bounds.maxX - panel.frame.width)),
                                     y: max(bounds.minY, min(panel.frame.minY, bounds.maxY - panel.frame.height))))
    }
}
