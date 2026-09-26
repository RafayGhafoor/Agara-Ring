import WidgetKit
import SwiftUI

@main
struct AgaraWidgetsBundle: WidgetBundle {
    /// The extension renders with Manrope too; its fonts ship in this target's own asset catalog.
    init() {
        AgaraFontRegistry.registerBundledFonts()
    }

    var body: some Widget {
        AgaraActivityWidget()
        AgaraMetricWidget()
        AgaraDualMetricWidget()
    }
}
