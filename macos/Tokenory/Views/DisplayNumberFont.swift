// [INPUT]: The bundled Maple Mono NF CN SemiBold face and a metric's existing point size.
// [OUTPUT]: The same face for SwiftUI readouts and AppKit rolling digits.
// [POS]: Prominent stats, menu bar summaries and import previews.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import CoreText
import SwiftUI

@MainActor
enum DisplayNumberFont {
    private static let descriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "MapleMono-NF-CN-SemiBold", withExtension: "ttf") else {
            return nil
        }
        // Resolve the bundled face even when a different version is installed under the same name.
        return (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
    }()

    static func native(size: CGFloat) -> NSFont {
        guard let descriptor else { return .monospacedSystemFont(ofSize: size, weight: .semibold) }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    static func font(size: CGFloat) -> Font { Font(native(size: size)) }

    static func font(for style: NSFont.TextStyle) -> Font {
        font(size: NSFont.preferredFont(forTextStyle: style).pointSize)
    }
}
