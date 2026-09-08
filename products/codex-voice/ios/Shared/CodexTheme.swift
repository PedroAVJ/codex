import SwiftUI

enum RelayTheme {
    static let paper = Color(red: 0.98, green: 0.976, blue: 0.969)
    static let surface = Color.white
    static let ink = Color(red: 0.078, green: 0.078, blue: 0.074)
    static let secondaryInk = Color(red: 0.42, green: 0.41, blue: 0.39)
    static let separator = Color.black.opacity(0.10)
    static let live = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warning = Color(red: 1.0, green: 0.80, blue: 0.0)
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let info = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let watchBackground = Color.black
    static let watchInk = Color(red: 0.96, green: 0.96, blue: 0.94)
}

struct RelayMark: View {
    var size: CGFloat = 24

    var body: some View {
        Image("RelayIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityLabel("Pedro Voice Agent")
    }
}
