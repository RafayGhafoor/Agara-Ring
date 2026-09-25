import XCTest
import UIKit
@testable import PulseLoop

/// Manrope is bundled as data assets and registered at runtime (`AgaraFontRegistry`); every
/// `AgaraFont` style resolves a face by PostScript name, so a face that fails to register would
/// silently fall back to the system font. These fail if an asset is missing or misnamed.
final class AgaraFontTests: XCTestCase {
    private let faces = ["Manrope-Regular", "Manrope-Medium", "Manrope-SemiBold", "Manrope-Bold"]

    func testEveryManropeFaceRegistersFromTheAssetCatalog() {
        for asset in ["manrope-regular", "manrope-medium", "manrope-semibold", "manrope-bold"] {
            XCTAssertNotNil(NSDataAsset(name: asset), "\(asset) is missing from the app's asset catalog")
        }
        AgaraFontRegistry.registerBundledFonts()
        for face in faces {
            let font = UIFont(name: face, size: 12)
            XCTAssertNotNil(font, "\(face) did not register")
            XCTAssertEqual(font?.familyName, "Manrope")
        }
    }

    func testUIKitBarsUseManrope() {
        AgaraFontRegistry.registerBundledFonts()
        AgaraUIKitFonts.apply()
        let title = UINavigationBar.appearance().titleTextAttributes?[.font] as? UIFont
        XCTAssertEqual(title?.fontName, "Manrope-SemiBold")
    }
}
