import SwiftUI

extension Color {
    static let mGround         = Color(hex: "f5ead8")
    static let mSurface        = Color(hex: "ebddc5")
    static let mText           = Color(hex: "201e1d")
    static let mTerracotta     = Color(hex: "c67139")
    static let mSage           = Color(hex: "7a8a5e")
    static let mTerracottaTint = Color(hex: "fff2eb")
    static let mSageTint       = Color(hex: "f0fae1")
    static let mTerracottaDeep = Color(hex: "8c491a")
    static let mSageDeep       = Color(hex: "56633f")
    static let mBorder         = Color(hex: "201e1d").opacity(0.1)

    init(hex: String) {
        let stripped = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: stripped).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }
}
