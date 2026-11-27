import AppKit
import CoreText

enum EditorTypography {
    static let strokeWidths: [CGFloat] = [2, 4, 8]
    static let fontSizes: [CGFloat] = [16, 24, 36]
    static var menuFont: NSFont { .menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize + 2) }

    private static let annotationFontName = registerFont("Geologica-Medium", postScriptName: "KadrText-Medium")

    private static func registerFont(_ filename: String, postScriptName: String) -> String? {
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        guard let url = resources.url(forResource: filename, withExtension: "ttf",
                                      subdirectory: "Fonts") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return postScriptName
    }

    static func font(ofSize size: CGFloat) -> NSFont {
        annotationFontName.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: .medium)
    }

    static func letterSpacing(forFontSize size: CGFloat, pixelWidth: CGFloat) -> CGFloat? {
        switch size {
        case 24: return pixelWidth
        case 36: return 2 * pixelWidth
        default: return nil
        }
    }

    static func nearestStroke(to width: CGFloat) -> CGFloat {
        strokeWidths.min(by: { abs($0 - width) < abs($1 - width) }) ?? 4
    }

    static func fontSize(forStroke width: CGFloat) -> CGFloat {
        let normalized = nearestStroke(to: width)
        return fontSizes[strokeWidths.firstIndex(of: normalized) ?? 1]
    }
}
