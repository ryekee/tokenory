// [INPUT]: A hovered SwiftUI value or selected chart bucket, and its compact readout.
// [OUTPUT]: Immediate hover targets and delayed mouse-transparent readouts in the dashboard foreground.
// [POS]: Dashboard tooltips share one placement rule across scroll views and charts.
import AppKit
import Observation
import SwiftUI

extension View {
    func cursorTooltipSurface() -> some View { modifier(TooltipSurfaceModifier()) }

    /// Attach before any expanding frame so only the visible value participates in hover.
    func cursorTooltip<Readout: View>(enabled: Bool, @ViewBuilder readout: () -> Readout) -> some View {
        modifier(ValueTooltip(enabled: enabled, readout: readout()))
    }

    /// The chart owns selection and supplies the mark to keep clear in local, top-leading coordinates.
    func selectedTooltip<Readout: View>(avoiding mark: CGRect?, pointer: TooltipPointer? = nil, keyboardAnchor: CGPoint? = nil,
                                       @ViewBuilder readout: () -> Readout) -> some View {
        background {
            if let mark {
                CursorTooltipAnchor(mark: mark, pointer: pointer, keyboardAnchor: keyboardAnchor, readout: readout())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

@MainActor
private final class TooltipSurface: ObservableObject {
    lazy var view = MouseTransparentView()
}

private struct TooltipSurfaceModifier: ViewModifier {
    @StateObject private var surface = TooltipSurface()

    func body(content: Content) -> some View {
        content.environmentObject(surface)
            .overlay {
                GeometryReader { geometry in
                    TooltipSurfaceLayer(surface: surface)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct TooltipSurfaceLayer: NSViewRepresentable {
    let surface: TooltipSurface
    func makeNSView(context: Context) -> NSView { surface.view }
    func updateNSView(_ view: NSView, context: Context) {}
}

private final class MouseTransparentView: NSView {
    weak var anchor: TooltipAnchorView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        anchor?.position()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        anchor?.position()
    }
}

/// A chart and its readout use the same local pointer sample. Movement within
/// one bucket only repositions the native host and does not invalidate the chart.
@MainActor
final class TooltipPointer {
    fileprivate weak var anchor: TooltipAnchorView?
    fileprivate(set) var location: CGPoint?

    func move(to point: CGPoint, reposition: Bool = true) {
        location = point
        if reposition { anchor?.position() }
    }
}

/// The target drives immediate focus. The readout waits for the pointer to settle on that target.
@MainActor @Observable
final class HoverDwell<Target: Equatable & Sendable> {
    static var standardDelay: Duration { .milliseconds(150) }
    static var calendarDelay: Duration { .milliseconds(240) }

    private(set) var target: Target?
    private(set) var readoutTarget: Target?
    private let delay: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(delay: Duration = HoverDwell.standardDelay) { self.delay = delay }

    func update(_ next: Target?) {
        guard target != next else { return }
        pending?.cancel()
        pending = nil
        if readoutTarget != nil { readoutTarget = nil }
        target = next
        guard let next else { return }

        let deadline = ContinuousClock.now + delay
        pending = Task { [weak self] in
            do { try await Task.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self else { return }
            readoutTarget = next
            pending = nil
        }
    }
}

private struct ValueTooltip<Readout: View>: ViewModifier {
    let enabled: Bool
    let readout: Readout
    @State private var hover = HoverDwell<Bool>()
    @State private var pointer = TooltipPointer()

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active(let point):
                pointer.move(to: point)
                hover.update(enabled ? true : nil)
            case .ended: hover.update(nil)
            }
        }
            .onChange(of: enabled) { _, _ in hover.update(nil) }
            .onDisappear { hover.update(nil) }
            .background {
                if enabled && hover.readoutTarget != nil {
                    CursorTooltipAnchor(mark: nil, pointer: pointer, keyboardAnchor: nil, readout: readout)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

enum CursorTooltipLayout {
    /// Uses AppKit window coordinates (positive y points up).
    static func frame(size: CGSize, pointer: CGPoint, mark: CGRect, bounds: CGRect) -> CGRect {
        let gap: CGFloat = 9
        let area = bounds.insetBy(dx: 4, dy: 4)
        let w = min(size.width, max(0, area.width)), h = min(size.height, max(0, area.height))
        func clamp(_ n: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(n, low), high) }
        let top = clamp(pointer.y + 5 - h, area.minY, area.maxY - h)
        let right = max(mark.maxX, pointer.x) + gap
        let left = min(mark.minX, pointer.x) - gap - w
        if right + w <= area.maxX { return CGRect(x: right, y: top, width: w, height: h) }
        if left >= area.minX { return CGRect(x: left, y: top, width: w, height: h) }

        let x = clamp(pointer.x - w / 2, area.minX, area.maxX - w)
        let below = min(mark.minY, pointer.y) - gap - h
        if below >= area.minY { return CGRect(x: x, y: below, width: w, height: h) }
        let above = max(mark.maxY, pointer.y) + gap
        if above + h <= area.maxY { return CGRect(x: x, y: above, width: w, height: h) }

        // A very wide mark in a small window can occupy every candidate. Protect the cursor first.
        let edges = [CGRect(x: area.maxX - w, y: top, width: w, height: h),
                     CGRect(x: area.minX, y: top, width: w, height: h),
                     CGRect(x: x, y: area.maxY - h, width: w, height: h),
                     CGRect(x: x, y: area.minY, width: w, height: h)]
        return edges.max { a, b in
            func clearance(_ rect: CGRect) -> CGFloat {
                max(rect.minX - pointer.x, pointer.x - rect.maxX, rect.minY - pointer.y, pointer.y - rect.maxY)
            }
            return clearance(a) < clearance(b)
        } ?? .zero
    }

    static func textWidth(_ string: String) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        ]).width)
    }

    static func summaryWidth(names: [String], tokens: Int64, cost: Double?, partial: Bool) -> CGFloat {
        let tokensWidth = max(textWidth("Tokens"), textWidth(tokens.formatted(.number.locale(Localization.locale))))
        let costWidth = max(textWidth("USD"), textWidth((partial ? "≈ " : "") + usd(cost)))
        if names.isEmpty {
            let label = max(textWidth(L("cost.estimate")), textWidth(L("cost.known")))
            return max(146, label + max(tokensWidth, costWidth) + 10)
        }
        let name = min(160, names.map(textWidth).max() ?? 0)
        return max(160, name + tokensWidth + costWidth + 34)
    }
}

private struct CursorTooltipAnchor<Readout: View>: NSViewRepresentable {
    @EnvironmentObject private var surface: TooltipSurface
    let mark: CGRect?
    let pointer: TooltipPointer?
    let keyboardAnchor: CGPoint?
    let readout: Readout

    func makeNSView(context: Context) -> TooltipAnchorView { TooltipAnchorView() }

    func updateNSView(_ view: TooltipAnchorView, context: Context) {
        guard context.environment.isEnabled else { view.dismiss(); return }
        let panel = readout.frame(maxWidth: 420).padding(.horizontal, 10).padding(.vertical, 8)
            .background(WorkspaceStyle.surface(context.environment.colorScheme), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.16), lineWidth: 0.75) }
            .fixedSize()
            .environment(\.locale, context.environment.locale)
            .environment(\.colorScheme, context.environment.colorScheme)
        view.update(AnyView(panel), surface: surface.view, mark: mark, pointer: pointer, keyboardAnchor: keyboardAnchor)
    }

    static func dismantleNSView(_ view: TooltipAnchorView, coordinator: ()) { view.dismiss() }
}

private final class TooltipHost: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

private final class TooltipAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var host: TooltipHost?
    private weak var surface: MouseTransparentView?
    private var mark: CGRect?
    private weak var pointer: TooltipPointer?
    private var keyboardAnchor: CGPoint?
    private var size: CGSize = .zero

    func update(_ readout: AnyView, surface: MouseTransparentView, mark: CGRect?, pointer: TooltipPointer?, keyboardAnchor: CGPoint?) {
        self.surface = surface
        self.pointer = pointer
        self.mark = mark
        self.keyboardAnchor = keyboardAnchor
        if let host { host.rootView = readout }
        else {
            let content = TooltipHost(rootView: readout)
            content.sizingOptions = [.intrinsicContentSize]
            content.identifier = NSUserInterfaceItemIdentifier("Tokenory.cursorTooltip")
            content.setAccessibilityElement(false)
            host = content
        }
        if let host { size = host.intrinsicContentSize }
        attach()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attach() } else { detach() }
    }

    override func layout() {
        super.layout()
        position()
    }

    private func attach() {
        guard window != nil, let host, let parent = surface else { return }
        pointer?.anchor = self
        if parent.anchor !== self {
            parent.anchor?.detach()
            parent.anchor = self
        }
        if host.superview !== parent { parent.addSubview(host, positioned: .above, relativeTo: nil) }
        position()
    }

    func position() {
        guard let host, let window, let parent = surface, parent.window === window, size.width > 0 else { return }
        let pointer = (keyboardAnchor ?? pointer?.location).map { convert($0, to: nil) } ?? window.mouseLocationOutsideOfEventStream
        let exclusion = convert(mark ?? bounds, to: nil)
        let bounds = parent.convert(parent.bounds, to: nil).intersection(window.contentLayoutRect)
        guard !bounds.isEmpty else { return }
        let frame = CursorTooltipLayout.frame(size: size, pointer: pointer, mark: exclusion, bounds: bounds)
        host.frame = parent.convert(frame, from: nil)
    }

    private func detach() {
        if pointer?.anchor === self { pointer?.anchor = nil }
        if surface?.anchor === self { surface?.anchor = nil }
        host?.removeFromSuperview()
    }

    func dismiss() { detach(); host = nil }
}
