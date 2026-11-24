import SwiftUI
import CoreText
import AppKit

enum MementoFont {
    static func register() {
        for name in [
            "Caprasimo-Regular",
            "Figtree-Regular", "Figtree-Medium", "Figtree-SemiBold",
            "Figtree-Bold", "Figtree-ExtraBold"
        ] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                   ?? Bundle.main.url(forResource: name, withExtension: "otf")
            if let url {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    // Headings — Caprasimo if bundled, else serif fallback
    static func heading(_ size: CGFloat) -> Font {
        if NSFont(name: "Caprasimo", size: size) != nil {
            return .custom("Caprasimo", size: size)
        }
        return .system(size: size, weight: .regular, design: .serif)
    }

    // Body — Figtree if bundled, else system
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "Figtree", size: size) != nil {
            return .custom("Figtree", size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

extension Font {
    static let mLargeTitle  = MementoFont.heading(32)
    static let mTitle       = MementoFont.heading(24)
    static let mHeadline    = MementoFont.heading(18)

    static let mSubhead     = MementoFont.body(15)
    static let mSubheadSemi = MementoFont.body(15, weight: .semibold)
    static let mBody        = MementoFont.body(13)
    static let mBodySemi    = MementoFont.body(13, weight: .semibold)
    static let mLabel       = MementoFont.body(12, weight: .medium)
    static let mLabelBold   = MementoFont.body(12, weight: .bold)
    static let mCaption     = MementoFont.body(11)
    static let mCaptionSemi = MementoFont.body(11, weight: .semibold)
}
