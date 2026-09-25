import UIKit

/// Manrope for the text UIKit draws on SwiftUI's behalf — navigation-bar titles, tab-bar labels and
/// segmented pickers — which a SwiftUI `.font` never reaches. Call after `AgaraFontRegistry` has registered
/// the faces; a name that doesn't resolve leaves UIKit's default in place.
enum AgaraUIKitFonts {
    static func apply() {
        guard let title = UIFont(name: "Manrope-SemiBold", size: 17),
              let largeTitle = UIFont(name: "Manrope-Bold", size: 34),
              let tab = UIFont(name: "Manrope-Medium", size: 10),
              let segment = UIFont(name: "Manrope-Medium", size: 13) else { return }
        let navigationBar = UINavigationBar.appearance()
        navigationBar.titleTextAttributes = [.font: title]
        navigationBar.largeTitleTextAttributes = [.font: largeTitle]
        UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: segment], for: .normal)
    }
}
